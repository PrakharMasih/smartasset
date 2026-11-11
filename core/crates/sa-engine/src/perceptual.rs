//! The pull-based API for perceptual hashes (plan A2), the same shape as the media API in `workers.rs`:
//! `next_perceptual_batch` out, `submit_perceptual_results` back.

use crate::engine::{Engine, MEDIA, PHASH};
use sa_core::time::now_ms;
use sa_core::{MediaKind, Result};
use sa_jobs::{LeaseOutcome, PauseReason, backoff_ms};
use sa_providers::{PerceptualOutcome, PerceptualTask};
use sa_store::{assets, dedupe, jobs};
use std::collections::HashMap;

const MAX_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone)]
pub struct PerceptualBatch {
    pub batch_id: u64,
    pub tasks: Vec<PerceptualTask>,
    pub parallelism: u32,
}

#[derive(Debug, Clone)]
pub enum PerceptualTasks {
    Batch(PerceptualBatch),
    Held(PauseReason),
    Empty,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PerceptualReport {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

impl Engine {
    /// Leases the next batch of pictures and videos to hash. Returns nothing while thumbnails are still being made:
    /// the browse pass comes first.
    pub fn next_perceptual_batch(&self, max_items: u32) -> Result<PerceptualTasks> {
        let inner = &self.inner;
        if inner.manager.counts(MEDIA)?.remaining() > 0 || inner.scans_running.load(std::sync::atomic::Ordering::Relaxed) > 0 {
            return Ok(PerceptualTasks::Empty);
        }
        if inner.queue_dirty.swap(false, std::sync::atomic::Ordering::Relaxed) {
            inner.refresh_dedupe_queue();
        }
        let batch = match inner.manager.lease_batch(PHASH, max_items)? {
            LeaseOutcome::Held(r) => return Ok(PerceptualTasks::Held(r)),
            LeaseOutcome::Empty => return Ok(PerceptualTasks::Empty),
            LeaseOutcome::Batch(b) => b,
        };
        let tasks = batch
            .items
            .iter()
            .map(|job| {
                let mut path = std::path::PathBuf::from(&job.mount_path);
                if !job.folder_rel.is_empty() {
                    path.push(&job.folder_rel);
                }
                path.push(&job.rel_path);
                let ext = job.rel_path.rsplit_once('.').map_or("", |(_, e)| e).to_ascii_lowercase();
                let kind = MediaKind::from_extension(&ext).unwrap_or(MediaKind::Image);
                let thumb = (job.thumb_rev > 0)
                    .then(|| inner.dirs.thumb_path(job.asset_id.0, job.thumb_rev))
                    .filter(|p| p.is_file())
                    .map(|p| p.to_string_lossy().into_owned());
                PerceptualTask {
                    job_id: job.job_id.0,
                    asset_id: job.asset_id.0,
                    path: path.to_string_lossy().into_owned(),
                    kind,
                    ext,
                    thumb_path: thumb,
                    attempt: job.attempt,
                    size: job.size,
                    mtime: job.mtime,
                }
            })
            .collect();
        inner.notifier.work_started();
        Ok(PerceptualTasks::Batch(PerceptualBatch { batch_id: batch.id, tasks, parallelism: batch.throttle.parallelism }))
    }

    /// Commits a batch of perceptual hashes in one transaction. Results about a file that changed are thrown away.
    pub fn submit_perceptual_results(
        &self,
        batch_id: u64,
        results: Vec<(i64, PerceptualOutcome)>,
    ) -> Result<PerceptualReport> {
        let inner = &self.inner;
        let Some(batch) = inner.manager.finish(batch_id) else {
            let discarded = u32::try_from(results.len()).unwrap_or(u32::MAX);
            return Ok(PerceptualReport { discarded, ..PerceptualReport::default() });
        };
        let revoked = batch.is_revoked();
        let mut by_job: HashMap<i64, PerceptualOutcome> = results.into_iter().collect();
        let b = batch.clone();
        let report = inner.db.write(move |tx| {
            let now = now_ms();
            let mut report = PerceptualReport::default();
            for item in &b.items {
                let Some(outcome) = by_job.remove(&item.job_id.0) else {
                    if jobs::release(tx, item.job_id, &b.token, now)? {
                        report.released += 1;
                    }
                    continue;
                };
                let unchanged = assets::file_fingerprint(tx, item.asset_id)?
                    .is_some_and(|(size, mtime)| size == item.size && mtime == item.mtime);
                if revoked || !unchanged {
                    jobs::release(tx, item.job_id, &b.token, now)?;
                    report.discarded += 1;
                    continue;
                }
                match outcome {
                    PerceptualOutcome::Done(hashes) => {
                        if dedupe::set_perceptual(tx, item.asset_id, item.size, item.mtime, &hashes)?
                            && jobs::complete(tx, item.job_id, &b.token, now)?
                        {
                            report.committed += 1;
                        } else {
                            report.discarded += 1;
                        }
                    }
                    PerceptualOutcome::Failed { class, message } => {
                        jobs::fail(tx, item.job_id, &b.token, class, &message, now + backoff_ms(item.attempt), now)?;
                        if class.is_retryable() && item.attempt < MAX_ATTEMPTS {
                            report.retried += 1;
                        } else {
                            report.failed += 1;
                        }
                    }
                }
            }
            Ok(report)
        })?;
        if report.committed > 0 {
            inner.touch_duplicates();
        }
        inner.notifier.work_started();
        Ok(report)
    }
}
