//! Text in pictures (Phase 4, S4): the pull-based API, the same shape as the other workers.
//!
//! `next_text_batch` out, `submit_text_results` back. Nothing starts until the Swift side announces a reader
//! (`set_text_reader`): with no reader, no job exists and search is unchanged. The text joins the keyword search
//! (`sa-search` matches `asset_text_fts` next to names, paths, tags and notes), so the blend with search by meaning
//! needs nothing new.

use crate::engine::{Engine, MEDIA, TEXT};
use sa_core::time::now_ms;
use sa_core::{AssetId, MediaKind, Result};
use sa_jobs::{LeaseOutcome, PauseReason, backoff_ms};
use sa_providers::{TextOutcome, TextTask};
use sa_store::{assets, jobs, text};
use std::collections::HashMap;
use std::sync::atomic::Ordering;

const MAX_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone)]
pub struct TextBatch {
    pub batch_id: u64,
    pub tasks: Vec<TextTask>,
    pub parallelism: u32,
}

#[derive(Debug, Clone)]
pub enum TextTasks {
    Batch(TextBatch),
    Held(PauseReason),
    Empty,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TextReport {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

/// Where reading text stands, for the app to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextStatus {
    /// The announced reader, if one is ready.
    pub reader: Option<String>,
    /// Pictures and videos read by it (with or without text).
    pub read: i64,
    /// Pictures and videos still waiting.
    pub remaining: i64,
}

impl Engine {
    /// Announces the text reader that is ready. From now on pictures and videos are read with it. Calling it again
    /// with the same reader changes nothing; with another one, files are read again and their text replaced.
    pub fn set_text_reader(&self, reader: &str) {
        let inner = &self.inner;
        *inner.text_reader.lock() = Some(reader.to_string());
        inner.text_dirty.store(true, Ordering::Relaxed);
        inner.notifier.work_started();
    }

    /// The reader went away: no more text is read. Text already read stays searchable.
    pub fn clear_text_reader(&self) {
        *self.inner.text_reader.lock() = None;
        let _ = self.inner.manager.revoke_all(TEXT);
    }

    pub fn text_status(&self) -> Result<TextStatus> {
        let inner = &self.inner;
        let Some(reader) = inner.text_reader.lock().clone() else {
            return Ok(TextStatus { reader: None, read: 0, remaining: 0 });
        };
        let read = inner.db.read(|c| text::assets_read(c, &reader))?;
        Ok(TextStatus { reader: Some(reader), read, remaining: inner.manager.counts(TEXT)?.remaining() })
    }

    /// The text read in a file (for the Inspector and for "why this matched"); `None` if it has not been read.
    pub fn text_of(&self, id: AssetId) -> Result<Option<String>> {
        self.inner.db.read(|c| text::text_of(c, id))
    }

    /// Leases the next batch of pictures and videos to read. Returns nothing while thumbnails are still being made
    /// (the browse pass comes first) or while no reader is ready.
    pub fn next_text_batch(&self, max_items: u32) -> Result<TextTasks> {
        let inner = &self.inner;
        let Some(reader) = inner.text_reader.lock().clone() else { return Ok(TextTasks::Empty) };
        if inner.manager.counts(MEDIA)?.remaining() > 0 || inner.scans_running.load(Ordering::Relaxed) > 0 {
            return Ok(TextTasks::Empty);
        }
        if inner.text_dirty.swap(false, Ordering::Relaxed) {
            loop {
                let r = reader.clone();
                match inner.db.write(move |tx| text::enqueue_backlog(tx, &r, 5_000, now_ms())) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        }
        let batch = match inner.manager.lease_batch(TEXT, max_items)? {
            LeaseOutcome::Held(r) => return Ok(TextTasks::Held(r)),
            LeaseOutcome::Empty => return Ok(TextTasks::Empty),
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
                TextTask {
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
        Ok(TextTasks::Batch(TextBatch { batch_id: batch.id, tasks, parallelism: batch.throttle.parallelism }))
    }

    /// Commits a batch of text in one transaction. Results about a file that changed are thrown away.
    pub fn submit_text_results(&self, batch_id: u64, results: Vec<(i64, TextOutcome)>) -> Result<TextReport> {
        let inner = &self.inner;
        let Some(batch) = inner.manager.finish(batch_id) else {
            let discarded = u32::try_from(results.len()).unwrap_or(u32::MAX);
            return Ok(TextReport { discarded, ..TextReport::default() });
        };
        let reader = inner.text_reader.lock().clone();
        let revoked = batch.is_revoked() || reader.is_none();
        let reader = reader.unwrap_or_default();
        let mut by_job: HashMap<i64, TextOutcome> = results.into_iter().collect();
        let b = batch.clone();
        let report = inner.db.write(move |tx| {
            let now = now_ms();
            let mut report = TextReport::default();
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
                    TextOutcome::Done(words) => {
                        if text::set_text(tx, item.asset_id, item.size, item.mtime, &reader, &words)?
                            && jobs::complete(tx, item.job_id, &b.token, now)?
                        {
                            report.committed += 1;
                        } else {
                            report.discarded += 1;
                        }
                    }
                    TextOutcome::Failed { class, message } => {
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
        inner.notifier.work_started();
        Ok(report)
    }
}
