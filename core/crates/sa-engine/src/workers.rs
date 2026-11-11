//! The pull-based worker API (plan §6.3): `next_batch` out, `submit_results` back.
//!
//! Two calls per batch. Tasks carry paths and parameters only; the worker reads the files and writes thumbnails
//! itself. Results commit in one transaction.

use crate::engine::{Engine, MEDIA};
use sa_core::time::now_ms;
use sa_core::{AssetId, Result};
use sa_jobs::{LeaseOutcome, PauseReason, backoff_ms};
use sa_providers::media::THUMB_MAX_EDGE;
use sa_providers::{MediaOutcome, MediaTask};
use sa_store::{assets, jobs};
use std::collections::HashMap;

/// Attempts after which a transient failure is final. Matches the job table default.
const MAX_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone)]
pub struct MediaBatch {
    pub batch_id: u64,
    pub tasks: Vec<MediaTask>,
    /// Items the worker should process at the same time right now.
    pub parallelism: u32,
}

#[derive(Debug, Clone)]
pub enum BatchTasks {
    Batch(MediaBatch),
    /// Work exists but is held (paused, on battery, hot, low memory).
    Held(PauseReason),
    Empty,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SubmitReport {
    pub committed: u32,
    /// Results thrown away because the file changed, the asset is gone, or the batch was revoked.
    pub discarded: u32,
    /// Jobs that failed for good (corrupt, unsupported, permission, or out of attempts).
    pub failed: u32,
    /// Jobs queued again with a delay.
    pub retried: u32,
    /// Jobs the worker did not report; they return to the queue untouched.
    pub released: u32,
}

impl Engine {
    /// Leases the next batch of media work for a worker.
    pub fn next_media_batch(&self, max_items: u32) -> Result<BatchTasks> {
        let inner = &self.inner;
        let batch = match inner.manager.lease_batch(MEDIA, max_items)? {
            LeaseOutcome::Held(r) => return Ok(BatchTasks::Held(r)),
            LeaseOutcome::Empty => return Ok(BatchTasks::Empty),
            LeaseOutcome::Batch(b) => b,
        };
        let mut tasks = Vec::with_capacity(batch.items.len());
        for job in &batch.items {
            let mut path = std::path::PathBuf::from(&job.mount_path);
            if !job.folder_rel.is_empty() {
                path.push(&job.folder_rel);
            }
            path.push(&job.rel_path);
            let ext = job.rel_path.rsplit_once('.').map_or("", |(_, e)| e).to_ascii_lowercase();
            let kind = sa_core::MediaKind::from_extension(&ext).unwrap_or(sa_core::MediaKind::Image);
            let rev = job.thumb_rev + 1;
            let thumb = inner.dirs.thumb_path(job.asset_id.0, rev);
            let shard = job.asset_id.0.rem_euclid(256);
            if let Some(parent) = thumb.parent().filter(|_| inner.shards.lock().insert(shard)) {
                let _ = std::fs::create_dir_all(parent);
            }
            tasks.push(MediaTask {
                job_id: job.job_id.0,
                asset_id: job.asset_id.0,
                path: path.to_string_lossy().into_owned(),
                kind,
                ext,
                thumb_path: thumb.to_string_lossy().into_owned(),
                thumb_rev: rev,
                max_edge: THUMB_MAX_EDGE,
                attempt: job.attempt,
                size: job.size,
                mtime: job.mtime,
            });
        }
        inner.notifier.work_started();
        Ok(BatchTasks::Batch(MediaBatch { batch_id: batch.id, tasks, parallelism: batch.throttle.parallelism }))
    }

    /// Whether Rust revoked this batch (cancel, quit). Workers check between items and stop early.
    #[must_use]
    pub fn is_batch_revoked(&self, batch_id: u64) -> bool {
        self.inner.manager.is_revoked(batch_id)
    }

    /// Tells Rust a long-running batch is still being worked on, so its leases do not expire.
    pub fn heartbeat(&self, batch_id: u64) -> Result<bool> {
        self.inner.manager.heartbeat(batch_id)
    }

    /// The worker gives a batch back without results (it is quitting).
    pub fn release_batch(&self, batch_id: u64) -> Result<()> {
        let Some(batch) = self.inner.manager.finish(batch_id) else { return Ok(()) };
        self.inner.db.write(move |tx| {
            let now = now_ms();
            for item in &batch.items {
                jobs::release(tx, item.job_id, &batch.token, now)?;
            }
            Ok(())
        })
    }

    /// Commits a batch of results in one transaction.
    #[allow(clippy::too_many_lines)]
    pub fn submit_media_results(&self, batch_id: u64, results: Vec<(i64, MediaOutcome)>) -> Result<SubmitReport> {
        let inner = &self.inner;
        // An unknown batch was revoked or already submitted: its jobs are back in the queue, drop the results.
        let Some(batch) = inner.manager.finish(batch_id) else {
            let discarded = u32::try_from(results.len()).unwrap_or(u32::MAX);
            return Ok(SubmitReport { discarded, ..SubmitReport::default() });
        };
        let revoked = batch.is_revoked();
        let mut by_job: HashMap<i64, MediaOutcome> = results.into_iter().collect();
        let dirs = inner.dirs.clone();
        let b = batch.clone();
        let (report, ready, stale_thumbs, old_thumbs) = inner.db.write(move |tx| {
            let now = now_ms();
            let mut report = SubmitReport::default();
            let mut ready: Vec<i64> = Vec::new();
            let mut stale: Vec<std::path::PathBuf> = Vec::new();
            let mut old: Vec<std::path::PathBuf> = Vec::new();
            for item in &b.items {
                let Some(outcome) = by_job.remove(&item.job_id.0) else {
                    if jobs::release(tx, item.job_id, &b.token, now)? {
                        report.released += 1;
                    }
                    continue;
                };
                let new_rev = item.thumb_rev + 1;
                let new_thumb = dirs.thumb_path(item.asset_id.0, new_rev);
                let unchanged = assets::file_fingerprint(tx, item.asset_id)?.is_some_and(|(size, mtime)| size == item.size && mtime == item.mtime);
                if revoked || !unchanged {
                    // The file changed under the worker (or the asset is gone): the result describes old content.
                    jobs::release(tx, item.job_id, &b.token, now)?;
                    stale.push(new_thumb);
                    report.discarded += 1;
                    continue;
                }
                match outcome {
                    MediaOutcome::Done(done) => {
                        let wrote = done.thumb_written && new_thumb.is_file();
                        if !jobs::complete(tx, item.job_id, &b.token, now)? {
                            stale.push(new_thumb);
                            report.discarded += 1;
                            continue;
                        }
                        assets::apply_probe(tx, item.asset_id, &done.probe, wrote.then_some(new_rev))?;
                        let ext = item.rel_path.rsplit_once('.').map_or("", |(_, e)| e);
                        if matches!(sa_core::MediaKind::from_extension(ext), Some(sa_core::MediaKind::Image | sa_core::MediaKind::Video)) {
                            sa_store::dedupe::enqueue_perceptual(tx, item.asset_id, now)?;
                        }
                        if wrote {
                            ready.push(item.asset_id.0);
                            if item.thumb_rev > 0 {
                                old.push(dirs.thumb_path(item.asset_id.0, item.thumb_rev));
                            }
                        }
                        report.committed += 1;
                    }
                    MediaOutcome::Failed { class, message } => {
                        stale.push(new_thumb);
                        let attempt = item.attempt;
                        jobs::fail(tx, item.job_id, &b.token, class, &message, now + backoff_ms(attempt), now)?;
                        if class.is_retryable() && attempt < MAX_ATTEMPTS {
                            report.retried += 1;
                        } else {
                            // Final: the file stays browsable by name with a generic icon.
                            assets::mark_probe_failed(tx, item.asset_id)?;
                            report.failed += 1;
                        }
                    }
                }
            }
            Ok((report, ready, stale, old))
        })?;
        for p in stale_thumbs.iter().chain(old_thumbs.iter()) {
            let _ = std::fs::remove_file(p);
        }
        if !ready.is_empty() {
            inner.notifier.thumbs(ready);
            inner.notifier.library_changed(false);
        }
        inner.notifier.work_started();
        Ok(report)
    }

    /// Asks for a fresh look at specific assets (for example after the user replaced the file in an editor).
    pub fn requeue_media(&self, ids: &[AssetId]) -> Result<()> {
        let ids = ids.to_vec();
        self.inner.db.write(move |tx| {
            let now = now_ms();
            for id in ids {
                jobs::enqueue(tx, MEDIA, id, "", jobs::lane::USER, true, now)?;
            }
            Ok(())
        })?;
        self.inner.notifier.work_started();
        Ok(())
    }
}
