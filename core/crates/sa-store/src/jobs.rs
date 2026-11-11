//! The persistent job queue (plan §6.6). Policy lives in `sa-jobs`; this module is the SQL.
//!
//! Contract: a job is identified by `(kind, asset_id, variant)`. Enqueueing the same job twice never creates two
//! rows (idempotent). A leased job whose worker dies simply expires and is leased again.

use crate::error::DbResultExt;
use crate::util::ids_json;
use rusqlite::{Connection, Transaction, params};
use sa_core::{AssetId, ErrorClass, FolderId, JobId, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued = 0,
    Leased = 1,
    Done = 2,
    Failed = 3,
    Cancelled = 4,
}

/// Priority lanes (plan §6.6). Lower is more urgent.
pub mod lane {
    pub const VISIBLE: u8 = 1;
    pub const NEW: u8 = 2;
    pub const USER: u8 = 3;
    pub const BACKLOG: u8 = 4;
    pub const MAINTENANCE: u8 = 5;
}

/// Queues a job. Existing queued jobs only get promoted to a more urgent lane; a job that is running is left
/// alone; finished, failed or cancelled jobs are re-queued only when `force` is set (the file changed).
pub fn enqueue(
    tx: &Transaction<'_>,
    kind: &str,
    asset: AssetId,
    variant: &str,
    lane: u8,
    force: bool,
    now: i64,
) -> Result<()> {
    let n = tx
        .execute(
            "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)
             ON CONFLICT(kind, asset_id, variant) DO NOTHING",
            params![kind, asset.0, variant, lane, now],
        )
        .db()?;
    if n > 0 {
        return Ok(());
    }
    if force {
        tx.execute(
            "UPDATE jobs SET state = 0, attempts = 0, not_before = 0, lane = MIN(lane, ?4),
                    error_class = NULL, error_message = NULL, lease_token = NULL, updated_at = ?5
             WHERE kind = ?1 AND asset_id = ?2 AND variant = ?3 AND state IN (2, 3, 4)",
            params![kind, asset.0, variant, lane, now],
        )
        .db()?;
    }
    tx.execute(
        "UPDATE jobs SET lane = ?4, updated_at = ?5
         WHERE kind = ?1 AND asset_id = ?2 AND variant = ?3 AND state = 0 AND lane > ?4",
        params![kind, asset.0, variant, lane, now],
    )
    .db()?;
    Ok(())
}

/// A job handed to a worker, with what it needs to find the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeasedJob {
    pub job_id: JobId,
    pub asset_id: AssetId,
    pub variant: String,
    pub lane: u8,
    pub attempt: u32,
    pub folder_id: FolderId,
    pub folder_rel: String,
    pub mount_path: String,
    pub rel_path: String,
    pub size: i64,
    pub mtime: i64,
    pub thumb_rev: i64,
}

/// Leases up to `limit` runnable jobs of `kind`, most urgent lane first. Only jobs whose file can actually be
/// read now are leased: the drive is online, the folder is enabled and the file is not missing.
pub fn lease(
    tx: &Transaction<'_>,
    kind: &str,
    limit: u32,
    token: &str,
    lease_ms: i64,
    now: i64,
) -> Result<Vec<LeasedJob>> {
    let ids: Vec<i64> = {
        let mut stmt = tx
            .prepare_cached(
                "SELECT j.id FROM jobs j
                   JOIN assets a  ON a.id = j.asset_id AND a.status = 0
                   JOIN folders f ON f.id = a.folder_id AND f.enabled = 1
                   JOIN volumes v ON v.id = f.volume_id AND v.is_online = 1
                 WHERE j.kind = ?1 AND j.state = 0 AND j.not_before <= ?2
                 ORDER BY j.lane, j.id
                 LIMIT ?3",
            )
            .db()?;
        let rows = stmt.query_map(params![kind, now, limit], |r| r.get::<_, i64>(0)).db()?;
        rows.collect::<std::result::Result<_, _>>().db()?
    };
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let json = ids_json(&ids);
    tx.execute(
        "UPDATE jobs SET state = 1, lease_token = ?2, lease_expires = ?3, attempts = attempts + 1, updated_at = ?4
         WHERE id IN (SELECT value FROM json_each(?1))",
        params![json, token, now + lease_ms, now],
    )
    .db()?;
    let mut stmt = tx
        .prepare_cached(
            "SELECT j.id, j.asset_id, j.variant, j.lane, j.attempts, a.folder_id, f.rel_path, v.mount_path,
                    a.rel_path, a.size, a.mtime, a.thumb_rev
             FROM json_each(?1) k JOIN jobs j ON j.id = k.value
               JOIN assets a ON a.id = j.asset_id JOIN folders f ON f.id = a.folder_id
               JOIN volumes v ON v.id = f.volume_id
             ORDER BY k.key",
        )
        .db()?;
    let rows = stmt
        .query_map([json], |r| {
            Ok(LeasedJob {
                job_id: JobId(r.get(0)?),
                asset_id: AssetId(r.get(1)?),
                variant: r.get(2)?,
                lane: u8::try_from(r.get::<_, i64>(3)?).unwrap_or(4),
                attempt: u32::try_from(r.get::<_, i64>(4)?).unwrap_or(1),
                folder_id: FolderId(r.get(5)?),
                folder_rel: r.get(6)?,
                mount_path: r.get::<_, Option<String>>(7)?.unwrap_or_default(),
                rel_path: r.get(8)?,
                size: r.get(9)?,
                mtime: r.get(10)?,
                thumb_rev: r.get(11)?,
            })
        })
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Marks a leased job done. Returns `false` if the job is no longer leased with this token (it was revoked,
/// expired and re-leased, or its asset was removed), in which case the result must be discarded.
pub fn complete(tx: &Transaction<'_>, job: JobId, token: &str, now: i64) -> Result<bool> {
    let n = tx
        .execute(
            "UPDATE jobs SET state = 2, lease_token = NULL, lease_expires = NULL, checkpoint = NULL,
                    error_class = NULL, error_message = NULL, updated_at = ?3
             WHERE id = ?1 AND state = 1 AND lease_token = ?2",
            params![job.0, token, now],
        )
        .db()?;
    Ok(n > 0)
}

/// Records a failure. Retryable errors go back to the queue with a backoff until attempts run out; everything
/// else fails the job alone and never stalls the pipeline (plan §6.6).
pub fn fail(
    tx: &Transaction<'_>,
    job: JobId,
    token: &str,
    class: ErrorClass,
    message: &str,
    retry_at: i64,
    now: i64,
) -> Result<bool> {
    let n = tx
        .execute(
            "UPDATE jobs SET
                 state = CASE WHEN ?4 AND attempts < max_attempts THEN 0 ELSE 3 END,
                 not_before = CASE WHEN ?4 AND attempts < max_attempts THEN ?7 ELSE not_before END,
                 lease_token = NULL, lease_expires = NULL,
                 error_class = ?5, error_message = ?6, updated_at = ?8
             WHERE id = ?1 AND state = 1 AND lease_token = ?2",
            params![job.0, token, 0, class.is_retryable(), class.as_str(), message, retry_at, now],
        )
        .db()?;
    Ok(n > 0)
}

/// Puts a leased job back without counting an attempt (a batch was revoked, the app is pausing).
pub fn release(tx: &Transaction<'_>, job: JobId, token: &str, now: i64) -> Result<bool> {
    let n = tx
        .execute(
            "UPDATE jobs SET state = 0, lease_token = NULL, lease_expires = NULL,
                    attempts = MAX(attempts - 1, 0), updated_at = ?3
             WHERE id = ?1 AND state = 1 AND lease_token = ?2",
            params![job.0, token, now],
        )
        .db()?;
    Ok(n > 0)
}

/// Returns jobs whose lease ran out (worker died or hung) to the queue.
pub fn expire_leases(tx: &Transaction<'_>, now: i64) -> Result<usize> {
    tx.execute(
        "UPDATE jobs SET state = 0, lease_token = NULL, lease_expires = NULL, updated_at = ?1
         WHERE state = 1 AND lease_expires < ?1",
        [now],
    )
    .db()
}

/// After a restart no worker holds anything: every leased job goes back to the queue (plan: resumable after crash).
pub fn reset_all_leases(tx: &Transaction<'_>, now: i64) -> Result<usize> {
    tx.execute(
        "UPDATE jobs SET state = 0, lease_token = NULL, lease_expires = NULL, updated_at = ?1 WHERE state = 1",
        [now],
    )
    .db()
}

/// Moves queued jobs for these assets to a more urgent lane (the assets on screen, plan lane 1).
pub fn promote(tx: &Transaction<'_>, kind: &str, assets: &[AssetId], lane: u8, now: i64) -> Result<usize> {
    if assets.is_empty() {
        return Ok(0);
    }
    let json = ids_json(&assets.iter().map(|a| a.0).collect::<Vec<_>>());
    tx.execute(
        "UPDATE jobs SET lane = ?3, updated_at = ?4
         WHERE kind = ?2 AND state = 0 AND lane > ?3 AND asset_id IN (SELECT value FROM json_each(?1))",
        params![json, kind, lane, now],
    )
    .db()
}

/// Cancels every queued and leased job of a kind (plan L5: cancel indexing). Optionally limited to one folder.
pub fn cancel(tx: &Transaction<'_>, kind: &str, folder: Option<FolderId>, now: i64) -> Result<usize> {
    tx.execute(
        "UPDATE jobs SET state = 4, lease_token = NULL, lease_expires = NULL, updated_at = ?3
         WHERE kind = ?1 AND state IN (0, 1)
           AND (?2 IS NULL OR asset_id IN (SELECT id FROM assets WHERE folder_id = ?2))",
        params![kind, folder.map(|f| f.0), now],
    )
    .db()
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct JobCounts {
    pub queued: i64,
    pub leased: i64,
    pub done: i64,
    pub failed: i64,
    pub cancelled: i64,
}

impl JobCounts {
    /// Work that is not finished: waiting or running.
    #[must_use]
    pub const fn remaining(&self) -> i64 {
        self.queued + self.leased
    }

    #[must_use]
    pub const fn total(&self) -> i64 {
        self.queued + self.leased + self.done + self.failed + self.cancelled
    }
}

pub fn counts(conn: &Connection, kind: &str) -> Result<JobCounts> {
    let mut stmt = conn.prepare_cached("SELECT state, COUNT(*) FROM jobs WHERE kind = ?1 GROUP BY state").db()?;
    let rows = stmt
        .query_map([kind], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
        .db()?;
    let mut c = JobCounts::default();
    for row in rows {
        let (state, n) = row.db()?;
        match state {
            0 => c.queued = n,
            1 => c.leased = n,
            2 => c.done = n,
            3 => c.failed = n,
            4 => c.cancelled = n,
            _ => {}
        }
    }
    Ok(c)
}

/// Earliest time a backed-off queued job becomes runnable again, if any (so the manager can wake up then).
pub fn next_retry_at(conn: &Connection, kind: &str, now: i64) -> Result<Option<i64>> {
    conn.query_row(
        "SELECT MIN(not_before) FROM jobs WHERE kind = ?1 AND state = 0 AND not_before > ?2",
        params![kind, now],
        |r| r.get::<_, Option<i64>>(0),
    )
    .db()
}

/// Pushes the lease expiry of every job held under `token` to `expires` (a worker's heartbeat).
pub fn extend_lease(tx: &Transaction<'_>, token: &str, expires: i64) -> Result<usize> {
    tx.execute(
        "UPDATE jobs SET lease_expires = ?2 WHERE state = 1 AND lease_token = ?1",
        params![token, expires],
    )
    .db()
}
