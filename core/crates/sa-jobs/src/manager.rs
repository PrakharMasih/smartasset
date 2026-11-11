//! Batch leasing for pull-based workers (plan §6.3).

use crate::policy::{Conditions, Gate, PauseReason, Settings, Throttle, gate};
use parking_lot::Mutex;
use sa_core::time::now_ms;
use sa_core::{AssetId, FolderId, Result};
use sa_store::jobs::{self, LeasedJob};
use sa_store::Db;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// A lease long enough for a slow video probe, short enough that a dead worker's jobs come back quickly.
const BASE_LEASE_MS: i64 = 90_000;
const PER_ITEM_LEASE_MS: i64 = 8_000;

/// A batch of leased jobs handed to one worker.
#[derive(Debug)]
pub struct BatchInfo {
    pub id: u64,
    pub kind: String,
    /// Proves ownership when results come back.
    pub token: String,
    pub items: Vec<LeasedJob>,
    pub throttle: Throttle,
    /// Set when Rust revokes the batch (cancel, quit). Workers check between items.
    cancel: AtomicBool,
}

impl BatchInfo {
    #[must_use]
    pub fn is_revoked(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
}

#[derive(Debug)]
pub enum LeaseOutcome {
    Batch(Arc<BatchInfo>),
    /// Work exists but must not run now.
    Held(PauseReason),
    /// Nothing is runnable.
    Empty,
}

struct State {
    user_paused: bool,
    settings: Settings,
    conditions: Conditions,
    batches: HashMap<u64, Arc<BatchInfo>>,
}

pub struct Manager {
    db: Db,
    state: Mutex<State>,
    next_id: AtomicU64,
}

impl std::fmt::Debug for Manager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Manager").finish_non_exhaustive()
    }
}

impl Manager {
    /// Creates the manager and recovers from an earlier crash: no worker survives a restart, so every lease the
    /// previous session held goes back to the queue (plan: resumable after quit or crash).
    pub fn new(db: Db, settings: Settings) -> Result<Self> {
        let recovered = db.write(|tx| jobs::reset_all_leases(tx, now_ms()))?;
        if recovered > 0 {
            tracing::info!(recovered, "returned orphaned job leases to the queue");
        }
        Ok(Self {
            db,
            state: Mutex::new(State {
                user_paused: false,
                settings,
                conditions: Conditions::default(),
                batches: HashMap::new(),
            }),
            next_id: AtomicU64::new(1),
        })
    }

    pub fn set_paused(&self, paused: bool) {
        self.state.lock().user_paused = paused;
    }

    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.state.lock().user_paused
    }

    pub fn set_conditions(&self, c: Conditions) {
        self.state.lock().conditions = c;
    }

    pub fn set_settings(&self, s: Settings) {
        self.state.lock().settings = s;
    }

    #[must_use]
    pub fn settings(&self) -> Settings {
        self.state.lock().settings
    }

    /// Why background work is held right now, if it is.
    #[must_use]
    pub fn hold_reason(&self) -> Option<PauseReason> {
        let s = self.state.lock();
        match gate(s.user_paused, s.settings, s.conditions) {
            Gate::Hold(r) => Some(r),
            Gate::Run(_) => None,
        }
    }

    /// Leases the next batch of `kind` for a worker (`next_batch`, plan §6.3).
    pub fn lease_batch(&self, kind: &str, max_items: u32) -> Result<LeaseOutcome> {
        let throttle = {
            let s = self.state.lock();
            match gate(s.user_paused, s.settings, s.conditions) {
                Gate::Hold(r) => return Ok(LeaseOutcome::Held(r)),
                Gate::Run(t) => t,
            }
        };
        let take = max_items.min(throttle.max_batch).max(1);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let token = format!("b{id}-{}", now_ms());
        let lease_ms = BASE_LEASE_MS + PER_ITEM_LEASE_MS * i64::from(take);
        let kind_owned = kind.to_string();
        let tok = token.clone();
        let items = self.db.write(move |tx| {
            let now = now_ms();
            jobs::expire_leases(tx, now)?;
            jobs::lease(tx, &kind_owned, take, &tok, lease_ms, now)
        })?;
        if items.is_empty() {
            return Ok(LeaseOutcome::Empty);
        }
        let batch = Arc::new(BatchInfo {
            id,
            kind: kind.to_string(),
            token,
            items,
            throttle,
            cancel: AtomicBool::new(false),
        });
        self.state.lock().batches.insert(id, Arc::clone(&batch));
        Ok(LeaseOutcome::Batch(batch))
    }

    /// Looks up an outstanding batch without removing it.
    #[must_use]
    pub fn batch(&self, id: u64) -> Option<Arc<BatchInfo>> {
        self.state.lock().batches.get(&id).cloned()
    }

    /// Removes a batch from the table once its results are committed (or it is abandoned).
    pub fn finish(&self, id: u64) -> Option<Arc<BatchInfo>> {
        self.state.lock().batches.remove(&id)
    }

    #[must_use]
    pub fn is_revoked(&self, id: u64) -> bool {
        self.state.lock().batches.get(&id).is_none_or(|b| b.is_revoked())
    }

    /// Revokes every outstanding batch of `kind`: workers see it between items, and the jobs go back to the queue
    /// (without costing an attempt) unless the caller cancels them separately.
    pub fn revoke_all(&self, kind: &str) -> Result<usize> {
        let doomed: Vec<Arc<BatchInfo>> = {
            let mut s = self.state.lock();
            let ids: Vec<u64> = s.batches.iter().filter(|(_, b)| b.kind == kind).map(|(id, _)| *id).collect();
            ids.into_iter().filter_map(|id| s.batches.remove(&id)).collect()
        };
        let mut released = 0;
        for b in doomed {
            b.cancel.store(true, Ordering::Relaxed);
            let b2 = Arc::clone(&b);
            released += self.db.write(move |tx| {
                let now = now_ms();
                let mut n = 0;
                for item in &b2.items {
                    if jobs::release(tx, item.job_id, &b2.token, now)? {
                        n += 1;
                    }
                }
                Ok(n)
            })?;
        }
        Ok(released)
    }

    /// Extends the lease of every job in a batch while the worker is still busy (`heartbeat`).
    pub fn heartbeat(&self, id: u64) -> Result<bool> {
        let Some(b) = self.batch(id) else { return Ok(false) };
        if b.is_revoked() {
            return Ok(false);
        }
        let extend = BASE_LEASE_MS + PER_ITEM_LEASE_MS * i64::try_from(b.items.len()).unwrap_or(1);
        self.db.write(move |tx| {
            jobs::extend_lease(tx, &b.token, now_ms() + extend)?;
            Ok(true)
        })
    }

    /// Queued jobs for assets on screen jump to the most urgent lane (plan §6.6 lane 1).
    pub fn prioritize(&self, kind: &str, assets: Vec<AssetId>) -> Result<usize> {
        let kind = kind.to_string();
        self.db.write(move |tx| jobs::promote(tx, &kind, &assets, jobs::lane::VISIBLE, now_ms()))
    }

    /// Cancels all pending work of a kind, or only a folder's (plan L5).
    pub fn cancel(&self, kind: &str, folder: Option<FolderId>) -> Result<usize> {
        self.revoke_all(kind)?;
        let kind = kind.to_string();
        self.db.write(move |tx| jobs::cancel(tx, &kind, folder, now_ms()))
    }

    pub fn counts(&self, kind: &str) -> Result<jobs::JobCounts> {
        self.db.read(|c| jobs::counts(c, kind))
    }

    /// Outstanding batches, for diagnostics.
    #[must_use]
    pub fn outstanding(&self) -> usize {
        self.state.lock().batches.len()
    }
}
