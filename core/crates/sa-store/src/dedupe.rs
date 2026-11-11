//! Duplicate detection storage (plan A1, A2): the hash jobs, the hashes themselves, and the queries that read them.
//!
//! Detection is read-only with respect to the user's files: it reads bytes and writes rows in this database.
//! Two kinds of work exist:
//! * `hash`: the full-content BLAKE3 of a file, done in Rust. Only files that share a size and quick hash with
//!   another file are queued, because only those can be copies. A big library therefore never gets read in full.
//! * `phash`: a perceptual hash of a picture or a few video keyframes, done by the Swift media worker.

use crate::error::DbResultExt;
use crate::jobs::{self, lane};
use crate::util::ids_json;
use rusqlite::{Connection, Transaction, params};
use sa_core::{AssetId, MediaKind, Result};

/// Job kind for the full-content hash.
pub const HASH_JOB: &str = "hash";
/// Job kind for the perceptual hash.
pub const PHASH_JOB: &str = "phash";
/// Bump when the perceptual hash changes meaning: every file then gets a fresh job.
pub const PHASH_VARIANT: &str = "v1";

/// Perceptual hashes of one sampled picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PerceptualHash {
    pub dhash: u64,
    pub phash: u64,
}

/// SQLite integers are signed; keep the bit pattern.
#[must_use]
pub const fn to_db(v: u64) -> i64 {
    i64::from_ne_bytes(v.to_ne_bytes())
}

#[must_use]
pub const fn from_db(v: i64) -> u64 {
    u64::from_ne_bytes(v.to_ne_bytes())
}

/// Queues a full hash for every present file that has the same size and quick hash as another present file and has
/// no hash yet. Returns how many jobs were queued. A cancelled job (the file went missing and came back) is revived.
pub fn enqueue_hash_candidates(tx: &Transaction<'_>, limit: i64, now: i64) -> Result<usize> {
    tx.execute(
        "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
         SELECT ?1, a.id, '', ?2, 0, ?3, ?3 FROM assets a
         WHERE a.status = 0 AND a.content_hash IS NULL AND a.size > 0
           AND EXISTS (SELECT 1 FROM assets b
                       WHERE b.size = a.size AND b.quick_hash = a.quick_hash AND b.id <> a.id AND b.status = 0)
           AND NOT EXISTS (SELECT 1 FROM jobs j
                           WHERE j.kind = ?1 AND j.asset_id = a.id AND j.variant = '' AND j.state <> 4)
         LIMIT ?4
         ON CONFLICT(kind, asset_id, variant) DO UPDATE
            SET state = 0, attempts = 0, not_before = 0, lane = excluded.lane, updated_at = excluded.updated_at
            WHERE jobs.state = 4",
        params![HASH_JOB, lane::MAINTENANCE, now, limit],
    )
    .db()
}

/// Queues a perceptual hash for every present picture or video that has been probed and has none.
pub fn enqueue_perceptual_backlog(tx: &Transaction<'_>, limit: i64, now: i64) -> Result<usize> {
    tx.execute(
        "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
         SELECT ?1, a.id, ?2, ?3, 0, ?4, ?4 FROM assets a
         WHERE a.status = 0 AND a.probe_state = 1 AND a.kind IN (0, 1)
           AND NOT EXISTS (SELECT 1 FROM jobs j
                           WHERE j.kind = ?1 AND j.asset_id = a.id AND j.variant = ?2 AND j.state <> 4)
         LIMIT ?5
         ON CONFLICT(kind, asset_id, variant) DO UPDATE
            SET state = 0, attempts = 0, not_before = 0, lane = excluded.lane, updated_at = excluded.updated_at
            WHERE jobs.state = 4",
        params![PHASH_JOB, PHASH_VARIANT, lane::MAINTENANCE, now, limit],
    )
    .db()
}

/// Queues the perceptual hash of one asset whose picture was just read (it is fresh, so it goes first in the
/// maintenance lane's queue behind nothing else of higher priority).
pub fn enqueue_perceptual(tx: &Transaction<'_>, asset: AssetId, now: i64) -> Result<()> {
    jobs::enqueue(tx, PHASH_JOB, asset, PHASH_VARIANT, lane::BACKLOG, false, now)
}

/// The file changed: whatever was derived from its old content is stale. Hashes, perceptual rows and finished or
/// failed jobs for them are dropped so they are made again for the new content. A job that is running is left alone;
/// its result is discarded because the size or time no longer matches.
pub fn clear_derived(tx: &Transaction<'_>, id: AssetId) -> Result<()> {
    tx.execute("DELETE FROM perceptual WHERE asset_id = ?1", [id.0]).db()?;
    tx.execute(
        "DELETE FROM jobs WHERE asset_id = ?1 AND kind IN (?2, ?3) AND state <> 1",
        params![id.0, HASH_JOB, PHASH_JOB],
    )
    .db()?;
    Ok(())
}

/// Stores the full hash of a file, but only if the file is still the one that was hashed (same size and time).
/// Returns `false` when the record changed in the meantime and the result must be thrown away.
pub fn set_content_hash(tx: &Transaction<'_>, id: AssetId, size: i64, mtime: i64, hash: &[u8; 32]) -> Result<bool> {
    let n = tx
        .execute(
            "UPDATE assets SET content_hash = ?4 WHERE id = ?1 AND size = ?2 AND mtime = ?3",
            params![id.0, size, mtime, &hash[..]],
        )
        .db()?;
    Ok(n > 0)
}

/// Stores the perceptual hashes of a file, replacing earlier ones, if the file is still the one that was read.
pub fn set_perceptual(
    tx: &Transaction<'_>,
    id: AssetId,
    size: i64,
    mtime: i64,
    hashes: &[PerceptualHash],
) -> Result<bool> {
    let current: Option<(i64, i64)> = tx
        .query_row("SELECT size, mtime FROM assets WHERE id = ?1", [id.0], |r| Ok((r.get(0)?, r.get(1)?)))
        .ok();
    if current != Some((size, mtime)) {
        return Ok(false);
    }
    tx.execute("DELETE FROM perceptual WHERE asset_id = ?1", [id.0]).db()?;
    let mut stmt = tx
        .prepare_cached("INSERT INTO perceptual(asset_id, slot, dhash, phash) VALUES (?1, ?2, ?3, ?4)")
        .db()?;
    for (slot, h) in hashes.iter().enumerate() {
        stmt.execute(params![id.0, i64::try_from(slot).unwrap_or(0), to_db(h.dhash), to_db(h.phash)])
            .db()?;
    }
    Ok(true)
}

/// Files with the same content: same size, same full hash, all present. Offline-drive files count (their records
/// stay), missing files do not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExactGroup {
    pub size: i64,
    pub hash: Vec<u8>,
    /// Ascending asset ids.
    pub ids: Vec<i64>,
}

impl ExactGroup {
    /// Bytes that deleting every copy but one would free.
    #[must_use]
    pub fn wasted(&self) -> i64 {
        self.size * i64::try_from(self.ids.len().saturating_sub(1)).unwrap_or(0)
    }
}

/// Every group of two or more identical files, most wasteful first.
pub fn exact_groups(conn: &Connection) -> Result<Vec<ExactGroup>> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.size, a.content_hash, group_concat(a.id) FROM assets a
             WHERE a.content_hash IS NOT NULL AND a.status = 0 AND a.size > 0
             GROUP BY a.content_hash, a.size HAVING COUNT(*) > 1",
        )
        .db()?;
    let rows = stmt
        .query_map([], |r| {
            let ids: String = r.get(2)?;
            let mut ids: Vec<i64> = ids.split(',').filter_map(|s| s.parse().ok()).collect();
            ids.sort_unstable();
            Ok(ExactGroup { size: r.get(0)?, hash: r.get(1)?, ids })
        })
        .db()?;
    let mut groups: Vec<ExactGroup> = rows.collect::<std::result::Result<_, _>>().db()?;
    groups.sort_by_key(|g| (std::cmp::Reverse(g.wasted()), g.ids.first().copied()));
    Ok(groups)
}

/// What the near-duplicate matcher needs to know about one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PerceptualRow {
    pub id: i64,
    pub kind: MediaKind,
    pub duration_ms: Option<i64>,
    pub content_hash: Option<Vec<u8>>,
    pub slots: Vec<PerceptualHash>,
}

/// Every present picture and video that has perceptual hashes, in id order. A file whose full hash is still being
/// computed is left out until it is known: it might turn out to be a byte-for-byte copy, which belongs in the exact
/// groups and must not flash up as a look-alike first.
pub fn perceptual_rows(conn: &Connection) -> Result<Vec<PerceptualRow>> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.id, a.kind, a.duration_ms, a.content_hash, p.dhash, p.phash
             FROM perceptual p JOIN assets a ON a.id = p.asset_id
             WHERE a.status = 0
               AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.kind = 'hash' AND j.asset_id = a.id AND j.state IN (0, 1))
             ORDER BY a.id, p.slot",
        )
        .db()?;
    let mut rows = stmt.query([]).db()?;
    let mut out: Vec<PerceptualRow> = Vec::new();
    while let Some(r) = rows.next().db()? {
        let id: i64 = r.get(0).db()?;
        let hash = PerceptualHash { dhash: from_db(r.get(4).db()?), phash: from_db(r.get(5).db()?) };
        if let Some(last) = out.last_mut().filter(|l| l.id == id) {
            last.slots.push(hash);
            continue;
        }
        let kind_code: i64 = r.get(1).db()?;
        let Some(kind) = MediaKind::from_db(kind_code) else { continue };
        out.push(PerceptualRow {
            id,
            kind,
            duration_ms: r.get(2).db()?,
            content_hash: r.get(3).db()?,
            slots: vec![hash],
        });
    }
    Ok(out)
}

/// Moves what the user attached to removed copies onto the copy that stays, so cleaning up never loses a tag, a
/// collection or a rating (plan A3). The kept copy's own values win where it has them.
pub fn merge_user_data(tx: &Transaction<'_>, keeper: AssetId, removed: &[AssetId]) -> Result<()> {
    if removed.is_empty() {
        return Ok(());
    }
    let json = ids_json(&removed.iter().map(|a| a.0).collect::<Vec<_>>());
    tx.execute(
        "INSERT OR IGNORE INTO asset_tags(asset_id, tag_id)
         SELECT ?2, tag_id FROM asset_tags WHERE asset_id IN (SELECT value FROM json_each(?1))",
        params![json, keeper.0],
    )
    .db()?;
    tx.execute(
        "INSERT OR IGNORE INTO collection_items(collection_id, asset_id, position, added_at)
         SELECT collection_id, ?2, position, added_at FROM collection_items
         WHERE asset_id IN (SELECT value FROM json_each(?1))",
        params![json, keeper.0],
    )
    .db()?;
    tx.execute(
        "UPDATE assets SET
             rating      = CASE WHEN rating = 0 THEN COALESCE((SELECT MAX(rating) FROM assets
                                  WHERE id IN (SELECT value FROM json_each(?1))), 0) ELSE rating END,
             flag        = CASE WHEN flag = 0 THEN COALESCE((SELECT flag FROM assets
                                  WHERE id IN (SELECT value FROM json_each(?1)) AND flag <> 0 LIMIT 1), 0) ELSE flag END,
             color_label = CASE WHEN color_label = 0 THEN COALESCE((SELECT color_label FROM assets
                                  WHERE id IN (SELECT value FROM json_each(?1)) AND color_label <> 0 LIMIT 1), 0)
                                ELSE color_label END,
             notes       = CASE WHEN notes = '' THEN COALESCE((SELECT notes FROM assets
                                  WHERE id IN (SELECT value FROM json_each(?1)) AND notes <> '' LIMIT 1), '')
                                ELSE notes END
         WHERE id = ?2",
        params![json, keeper.0],
    )
    .db()?;
    // Search must find the kept copy by the tags and notes it just received.
    tx.execute(
        "UPDATE asset_fts SET notes = (SELECT notes FROM assets WHERE id = ?1) WHERE rowid = ?1",
        [keeper.0],
    )
    .db()?;
    crate::organize::refresh_fts_tags(tx, &ids_json(&[keeper.0]))?;
    Ok(())
}

/// Which of these assets carry something the user did: a rating, flag, label, note, tag or collection. Used to
/// suggest which copy to keep and to be careful with the others.
pub fn assets_with_user_data(conn: &Connection, ids: &[i64]) -> Result<std::collections::HashSet<i64>> {
    if ids.is_empty() {
        return Ok(std::collections::HashSet::new());
    }
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.id FROM json_each(?1) j JOIN assets a ON a.id = j.value
             WHERE a.rating > 0 OR a.flag <> 0 OR a.color_label <> 0 OR a.notes <> ''
                OR EXISTS (SELECT 1 FROM asset_tags t WHERE t.asset_id = a.id)
                OR EXISTS (SELECT 1 FROM collection_items c WHERE c.asset_id = a.id)",
        )
        .db()?;
    let rows = stmt.query_map([ids_json(ids)], |r| r.get::<_, i64>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// What the library knows about a file's identity: used to check, just before a cleanup, that the file on disk is
/// still the file the user reviewed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileIdentity {
    pub size: i64,
    pub mtime: i64,
    pub quick_hash: [u8; 16],
    pub present: bool,
}

pub fn file_identity(conn: &Connection, id: AssetId) -> Result<Option<FileIdentity>> {
    use rusqlite::OptionalExtension;
    conn.query_row("SELECT size, mtime, quick_hash, status FROM assets WHERE id = ?1", [id.0], |r| {
        let blob: Vec<u8> = r.get(2)?;
        let mut quick_hash = [0u8; 16];
        if blob.len() == 16 {
            quick_hash.copy_from_slice(&blob);
        }
        Ok(FileIdentity { size: r.get(0)?, mtime: r.get(1)?, quick_hash, present: r.get::<_, i64>(3)? == 0 })
    })
    .optional()
    .db()
}

/// Counts for the Duplicates page: files still being compared.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DedupeProgress {
    /// Files waiting for, or in the middle of, a full hash.
    pub hash_remaining: i64,
    /// Pictures and videos waiting for a perceptual hash.
    pub perceptual_remaining: i64,
}

pub fn progress(conn: &Connection) -> Result<DedupeProgress> {
    Ok(DedupeProgress {
        hash_remaining: jobs::counts(conn, HASH_JOB)?.remaining(),
        perceptual_remaining: jobs::counts(conn, PHASH_JOB)?.remaining(),
    })
}
