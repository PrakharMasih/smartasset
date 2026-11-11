//! Embeddings storage (Phase 4): the model configurations, the vectors, and the jobs that make them.
//!
//! The vectors are derived data. The Swift worker computes them from each file's thumbnail; Rust only stores them
//! (f16, normalised, see `sa-vector`) and reads them back to build the search index. Nothing here touches a file.

use crate::error::DbResultExt;
use crate::jobs::{self, lane};
use rusqlite::{Connection, Transaction, params};
use sa_core::{AssetId, Result};

/// Job kind for "make the vector of this picture or video". The job's variant is the model configuration id, so a
/// different model or setting gets its own jobs and its own vectors, and the old ones stay valid until removed.
pub const EMBED_JOB: &str = "embed";

/// Everything that decides what a vector means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelConfig {
    /// Names the other fields, e.g. `embeddinggemma2-mlx-q8-768-thumb512-v1`.
    pub id: String,
    pub model: String,
    pub version: String,
    pub modality: String,
    pub dims: u32,
    pub preprocessing: String,
}

/// Records a configuration (once; later calls with the same id change nothing).
pub fn register_config(tx: &Transaction<'_>, config: &ModelConfig, now: i64) -> Result<()> {
    tx.execute(
        "INSERT OR IGNORE INTO model_configs(id, model, version, modality, dims, preprocessing, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![config.id, config.model, config.version, config.modality, config.dims, config.preprocessing, now],
    )
    .db()?;
    Ok(())
}

/// The recorded configuration with this id.
pub fn config(conn: &Connection, id: &str) -> Result<Option<ModelConfig>> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT id, model, version, modality, dims, preprocessing FROM model_configs WHERE id = ?1",
        [id],
        |r| {
            Ok(ModelConfig {
                id: r.get(0)?,
                model: r.get(1)?,
                version: r.get(2)?,
                modality: r.get(3)?,
                dims: r.get(4)?,
                preprocessing: r.get(5)?,
            })
        },
    )
    .optional()
    .db()
}

/// The most recent other configuration whose vectors a question made for `config` can still be compared with: the same
/// model, weights, modality and size, differing only in how pictures were prepared (e.g. a larger picture budget). Only
/// one that still has vectors counts. While `config` is being made for the library, these answer for the files it has
/// not reached yet.
pub fn compatible_previous(conn: &Connection, config: &ModelConfig) -> Result<Option<String>> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT m.id FROM model_configs m
         WHERE m.id <> ?1 AND m.model = ?2 AND m.version = ?3 AND m.modality = ?4 AND m.dims = ?5
           AND EXISTS (SELECT 1 FROM embeddings e WHERE e.config = m.id)
         ORDER BY m.created_at DESC, m.id DESC LIMIT 1",
        params![config.id, config.model, config.version, config.modality, config.dims],
        |r| r.get(0),
    )
    .optional()
    .db()
}

/// A file has its vectors for `config`: drops its vectors of every other configuration of the same model (see
/// [`compatible_previous`]), which only stood in until now. Storage never holds two descriptions of one file, and files
/// that are never described again (missing, failing) keep their old vectors and stay searchable.
pub fn drop_superseded(tx: &Transaction<'_>, id: AssetId, config: &ModelConfig) -> Result<()> {
    tx.execute(
        "DELETE FROM embeddings WHERE asset_id = ?1 AND config IN (
             SELECT id FROM model_configs
             WHERE id <> ?2 AND model = ?3 AND version = ?4 AND modality = ?5 AND dims = ?6)",
        params![id.0, config.id, config.model, config.version, config.modality, config.dims],
    )
    .db()?;
    Ok(())
}

/// Queues a job for every present picture or video that has a thumbnail and no vector (or job) for `config` yet.
/// Returns how many were queued. A cancelled job (the file went missing and came back) is revived.
pub fn enqueue_backlog(tx: &Transaction<'_>, config: &str, limit: i64, now: i64) -> Result<usize> {
    tx.execute(
        "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
         SELECT ?1, a.id, ?2, ?3, 0, ?4, ?4 FROM assets a
         WHERE a.status = 0 AND a.probe_state = 1 AND a.kind IN (0, 1) AND a.thumb_rev > 0
           AND NOT EXISTS (SELECT 1 FROM jobs j
                           WHERE j.kind = ?1 AND j.asset_id = a.id AND j.variant = ?2 AND j.state <> 4)
         LIMIT ?5
         ON CONFLICT(kind, asset_id, variant) DO UPDATE
            SET state = 0, attempts = 0, not_before = 0, lane = excluded.lane, updated_at = excluded.updated_at
            WHERE jobs.state = 4",
        params![EMBED_JOB, config, lane::MAINTENANCE, now, limit],
    )
    .db()
}

/// Queues the vector of one asset whose thumbnail was just made.
pub fn enqueue(tx: &Transaction<'_>, asset: AssetId, config: &str, now: i64) -> Result<()> {
    jobs::enqueue(tx, EMBED_JOB, asset, config, lane::BACKLOG, false, now)
}

/// The file changed: its vectors describe old content. They and the finished or failed jobs for them are dropped so
/// they are made again. A running job is left alone; its result is discarded because the size or time no longer
/// matches.
pub fn clear_derived(tx: &Transaction<'_>, id: AssetId) -> Result<()> {
    tx.execute("DELETE FROM embeddings WHERE asset_id = ?1", [id.0]).db()?;
    tx.execute("DELETE FROM jobs WHERE asset_id = ?1 AND kind = ?2 AND state <> 1", params![id.0, EMBED_JOB])
        .db()?;
    Ok(())
}

/// Stores the vectors of a file for `config`, replacing earlier ones, if the file is still the one that was read.
/// `times_ms` says where in a video each vector is (same order); it is empty for a picture or when unknown.
/// Returns `false` (and stores nothing) when the record changed in the meantime or a vector has the wrong length.
#[allow(clippy::too_many_arguments)]
pub fn set_vectors(
    tx: &Transaction<'_>,
    id: AssetId,
    size: i64,
    mtime: i64,
    config: &str,
    dims: u32,
    vectors: &[Vec<u8>],
    times_ms: &[i64],
) -> Result<bool> {
    let current: Option<(i64, i64)> = tx
        .query_row("SELECT size, mtime FROM assets WHERE id = ?1", [id.0], |r| Ok((r.get(0)?, r.get(1)?)))
        .ok();
    if current != Some((size, mtime)) {
        return Ok(false);
    }
    let want = usize::try_from(dims).unwrap_or(0) * 2;
    if vectors.iter().any(|v| v.len() != want) {
        return Ok(false);
    }
    tx.execute("DELETE FROM embeddings WHERE asset_id = ?1 AND config = ?2", params![id.0, config]).db()?;
    let mut stmt = tx
        .prepare_cached("INSERT INTO embeddings(asset_id, config, slot, vec, t_ms) VALUES (?1, ?2, ?3, ?4, ?5)")
        .db()?;
    for (slot, v) in vectors.iter().enumerate() {
        let at: Option<i64> = if times_ms.len() == vectors.len() { times_ms.get(slot).copied() } else { None };
        stmt.execute(params![id.0, config, i64::try_from(slot).unwrap_or(0), v, at]).db()?;
    }
    Ok(true)
}

/// One stored vector of a file and where it is in the video.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredFrame {
    pub slot: i64,
    pub t_ms: Option<i64>,
    pub vec: Vec<u8>,
}

/// The vectors of a file, in time order, for `config`; when it has none there (it is still being described again),
/// for the configuration it replaces ([`compatible_previous`]). Empty if the file has not been described at all.
pub fn frames_of(conn: &Connection, id: AssetId, config: &ModelConfig) -> Result<Vec<StoredFrame>> {
    let read = |conn: &Connection, cfg: &str| -> Result<Vec<StoredFrame>> {
        let mut stmt =
            conn.prepare_cached("SELECT slot, t_ms, vec FROM embeddings WHERE asset_id = ?1 AND config = ?2 ORDER BY slot").db()?;
        let rows = stmt
            .query_map(params![id.0, cfg], |r| Ok(StoredFrame { slot: r.get(0)?, t_ms: r.get(1)?, vec: r.get(2)? }))
            .db()?;
        rows.collect::<std::result::Result<_, _>>().db()
    };
    let own = read(conn, &config.id)?;
    if !own.is_empty() {
        return Ok(own);
    }
    match compatible_previous(conn, config)? {
        Some(old) => read(conn, &old),
        None => Ok(Vec::new()),
    }
}

/// Calls `each(asset_id, vector)` for every stored vector of `config`, ordered by asset then slot (so rows of one
/// asset are adjacent, which the index relies on).
pub fn for_each_vector(conn: &Connection, config: &str, mut each: impl FnMut(i64, &[u8])) -> Result<()> {
    let mut stmt = conn.prepare("SELECT asset_id, vec FROM embeddings WHERE config = ?1 ORDER BY asset_id, slot").db()?;
    let mut rows = stmt.query([config]).db()?;
    while let Some(row) = rows.next().db()? {
        let id: i64 = row.get(0).db()?;
        let blob: Vec<u8> = row.get(1).db()?;
        each(id, &blob);
    }
    Ok(())
}

/// How many assets have a vector for `config`.
pub fn assets_with_vectors(conn: &Connection, config: &str) -> Result<i64> {
    conn.query_row("SELECT COUNT(DISTINCT asset_id) FROM embeddings WHERE config = ?1", [config], |r| r.get(0)).db()
}

/// Removes every vector and job of `config` (a model was removed or replaced).
pub fn remove_config(tx: &Transaction<'_>, config: &str) -> Result<()> {
    tx.execute("DELETE FROM jobs WHERE kind = ?1 AND variant = ?2 AND state <> 1", params![EMBED_JOB, config]).db()?;
    tx.execute("DELETE FROM model_configs WHERE id = ?1", [config]).db()?;
    Ok(())
}
