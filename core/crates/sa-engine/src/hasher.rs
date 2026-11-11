//! The full-content hash runner (plan A1): reads suspect files in full and records their BLAKE3.
//!
//! It is a background job like the others (plan §6.6): leased through the manager, held while indexing is paused or
//! the Mac is busy, never reading a file it was not given, and committing each batch in one transaction. A half-read
//! file is simply read again after a pause or a restart; nothing partial is ever stored.

use crate::engine::{Inner, HASH};
use parking_lot::{Condvar, Mutex};
use sa_core::time::{now_ms, system_time_to_ms};
use sa_core::{ErrorClass, Result};
use sa_index::{HashStop, content_hash};
use sa_jobs::{LeaseOutcome, backoff_ms};
use sa_store::{dedupe, jobs};
use std::fs::File;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

/// Files taken from the queue at once. Small: a batch is leased until it is finished.
const BATCH: u32 = 4;
/// Files read at the same time at most. Hashing is limited by the disk, not the CPU.
const MAX_READERS: u32 = 2;
/// How often a long batch tells the manager it is alive.
const HEARTBEAT: Duration = Duration::from_secs(20);

struct Shared {
    stop: AtomicBool,
    wake: Mutex<bool>,
    cv: Condvar,
}

pub(crate) struct Hasher {
    shared: Arc<Shared>,
}

impl Hasher {
    pub(crate) fn new() -> Self {
        Self { shared: Arc::new(Shared { stop: AtomicBool::new(false), wake: Mutex::new(false), cv: Condvar::new() }) }
    }

    pub(crate) fn start(inner: &Arc<Inner>) {
        let shared = Arc::clone(&inner.hasher.shared);
        let weak = Arc::downgrade(inner);
        let spawned = std::thread::Builder::new().name("sa-hasher".into()).spawn(move || run(&shared, &weak));
        if let Err(e) = spawned {
            tracing::error!(error = %e, "cannot start hash thread");
        }
    }

    /// New work may exist, or a pause was lifted.
    pub(crate) fn wake(&self) {
        *self.shared.wake.lock() = true;
        self.shared.cv.notify_all();
    }

    pub(crate) fn stop(&self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.wake();
    }
}

impl Shared {
    /// Sleeps up to `max`, or until woken. Returns `false` when the runner should exit.
    fn nap(&self, max: Duration) -> bool {
        let mut woken = self.wake.lock();
        if !*woken && !self.stop.load(Ordering::Relaxed) {
            let _ = self.cv.wait_for(&mut woken, max);
        }
        *woken = false;
        !self.stop.load(Ordering::Relaxed)
    }
}

fn run(shared: &Shared, weak: &Weak<Inner>) {
    loop {
        if shared.stop.load(Ordering::Relaxed) {
            return;
        }
        let pause = {
            let Some(inner) = weak.upgrade() else { return };
            inner.hash_step()
        };
        if !shared.nap(pause) {
            return;
        }
    }
}

enum Outcome {
    Hashed([u8; 32]),
    /// Paused, cancelled or shutting down while reading.
    Interrupted,
    /// The file is not the one that was queued (changed, replaced).
    Stale,
    Failed(ErrorClass, String),
}

/// A file that vanished or is being written is worth another try later; only a refused read is final.
fn classify(e: &std::io::Error) -> ErrorClass {
    if e.kind() == std::io::ErrorKind::PermissionDenied { ErrorClass::Permission } else { ErrorClass::Transient }
}

impl Inner {
    /// Lets the hasher run only when it will not get in the way: no scan running, no thumbnails waiting.
    fn hash_may_run(&self) -> bool {
        self.scans_running.load(Ordering::Relaxed) == 0
            && !self.scanner.has_pending()
            && self.manager.counts(crate::engine::MEDIA).is_ok_and(|c| c.remaining() == 0)
    }

    /// One turn of the runner. Returns how long to sleep before the next.
    fn hash_step(&self) -> Duration {
        if !self.hash_may_run() {
            return Duration::from_millis(750);
        }
        if self.queue_dirty.swap(false, Ordering::Relaxed) {
            self.refresh_dedupe_queue();
        }
        match self.manager.lease_batch(HASH, BATCH) {
            Ok(LeaseOutcome::Batch(batch)) => {
                self.notifier.work_started();
                if let Err(e) = self.hash_batch(&batch) {
                    tracing::warn!(error = %e, "hash batch failed");
                    return Duration::from_secs(5);
                }
                Duration::ZERO
            }
            Ok(LeaseOutcome::Held(_)) => Duration::from_secs(2),
            Ok(LeaseOutcome::Empty) => Duration::from_secs(30),
            Err(e) => {
                tracing::warn!(error = %e, "cannot lease hash work");
                Duration::from_secs(5)
            }
        }
    }

    fn hash_batch(&self, batch: &Arc<sa_jobs::BatchInfo>) -> Result<()> {
        let items = &batch.items;
        let readers = batch.throttle.parallelism.clamp(1, MAX_READERS) as usize;
        let next = AtomicUsize::new(0);
        let results: Mutex<Vec<(usize, Outcome)>> = Mutex::new(Vec::with_capacity(items.len()));
        let last_beat = Mutex::new(Instant::now());
        let throttle = self.config.hash_throttle;
        let keep_going = || {
            if !throttle.is_zero() {
                std::thread::sleep(throttle);
            }
            if batch.is_revoked() || self.hasher_stopped() || self.manager.hold_reason().is_some() {
                return false;
            }
            let mut beat = last_beat.lock();
            if beat.elapsed() > HEARTBEAT {
                *beat = Instant::now();
                let _ = self.manager.heartbeat(batch.id);
            }
            true
        };
        std::thread::scope(|scope| {
            for _ in 0..readers.min(items.len()) {
                scope.spawn(|| loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(i) else { break };
                    let outcome = if keep_going() { hash_one(item, &keep_going) } else { Outcome::Interrupted };
                    results.lock().push((i, outcome));
                });
            }
        });
        let results = results.into_inner();
        let b = Arc::clone(batch);
        let committed = self.db.write(move |tx| {
            let now = now_ms();
            let mut stored = 0usize;
            let mut by_item: Vec<Option<Outcome>> = (0..b.items.len()).map(|_| None).collect();
            for (i, o) in results {
                by_item[i] = Some(o);
            }
            for (item, outcome) in b.items.iter().zip(by_item) {
                match outcome {
                    Some(Outcome::Hashed(h)) => {
                        if dedupe::set_content_hash(tx, item.asset_id, item.size, item.mtime, &h)? {
                            jobs::complete(tx, item.job_id, &b.token, now)?;
                            stored += 1;
                        } else {
                            jobs::release(tx, item.job_id, &b.token, now)?;
                        }
                    }
                    Some(Outcome::Failed(class, message)) => {
                        jobs::fail(tx, item.job_id, &b.token, class, &message, now + backoff_ms(item.attempt), now)?;
                    }
                    Some(Outcome::Stale | Outcome::Interrupted) | None => {
                        jobs::release(tx, item.job_id, &b.token, now)?;
                    }
                }
            }
            Ok(stored)
        });
        self.manager.finish(batch.id);
        let stored = committed?;
        if stored > 0 {
            self.touch_duplicates();
        }
        self.notifier.work_started();
        Ok(())
    }

    fn hasher_stopped(&self) -> bool {
        self.hasher.shared.stop.load(Ordering::Relaxed)
    }
}

fn abs_path(item: &jobs::LeasedJob) -> PathBuf {
    let mut p = PathBuf::from(&item.mount_path);
    if !item.folder_rel.is_empty() {
        p.push(&item.folder_rel);
    }
    p.push(&item.rel_path);
    p
}

fn hash_one(item: &jobs::LeasedJob, keep_going: &dyn Fn() -> bool) -> Outcome {
    let path = abs_path(item);
    let file = match File::open(&path) {
        Ok(f) => f,
        Err(e) => return Outcome::Failed(classify(&e), format!("cannot open {}: {e}", path.display())),
    };
    let Ok(meta) = file.metadata() else { return Outcome::Stale };
    let on_disk_mtime = meta.modified().map_or(0, system_time_to_ms);
    if i64::try_from(meta.len()).ok() != Some(item.size) || on_disk_mtime != item.mtime {
        return Outcome::Stale;
    }
    match content_hash(&file, meta.len(), keep_going) {
        Ok(h) => {
            // The file may have been rewritten while it was read; a hash of a moving target is not recorded.
            let unchanged = file.metadata().is_ok_and(|m| {
                i64::try_from(m.len()).ok() == Some(item.size) && m.modified().map_or(0, system_time_to_ms) == item.mtime
            });
            if unchanged { Outcome::Hashed(h) } else { Outcome::Stale }
        }
        Err(HashStop::Interrupted) => Outcome::Interrupted,
        Err(HashStop::Io(e)) => Outcome::Failed(classify(&e), format!("cannot read {}: {e}", path.display())),
    }
}
