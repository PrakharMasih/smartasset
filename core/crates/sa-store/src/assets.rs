//! Asset rows: what the scanner writes, what the grid and inspector read (plan L2, L3, V1, V5, H2).

use crate::error::DbResultExt;
use crate::jobs;
use crate::model::{
    AssetDetail, AssetFileRow, AssetStatus, AssetSummary, ProbeResult, ProbeState, RelinkCandidate,
    ScannedFile, ThumbKey,
};
use crate::util::{below, ids_json};
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use sa_core::media::classify;
use sa_core::{AspectClass, AssetId, ColorLabel, Error, Flag, FolderId, MediaKind, Result, paths};
use std::path::PathBuf;

/// Job kind for "read metadata and make a thumbnail" (the browse pass, plan §6.6).
pub const MEDIA_JOB: &str = "media";

fn hash16(blob: Option<Vec<u8>>) -> [u8; 16] {
    let mut out = [0u8; 16];
    if let Some(b) = blob.filter(|b| b.len() == 16) {
        out.copy_from_slice(&b);
    }
    out
}

fn file_row(r: &Row<'_>) -> rusqlite::Result<AssetFileRow> {
    Ok(AssetFileRow {
        id: AssetId(r.get(0)?),
        rel_path: r.get(1)?,
        size: r.get(2)?,
        mtime: r.get(3)?,
        quick_hash: hash16(r.get(4)?),
        status: AssetStatus::from_db(r.get(5)?),
    })
}

const FILE_COLS: &str = "id, rel_path, size, mtime, quick_hash, status";

/// Every asset below `dir` in a folder, at any depth (`""` = the whole folder).
pub fn assets_below_dir(conn: &Connection, folder: FolderId, dir: &str) -> Result<Vec<AssetFileRow>> {
    let (lo, hi) = below(dir);
    let mut stmt = conn
        .prepare_cached(&format!(
            "SELECT {FILE_COLS} FROM assets WHERE folder_id = ?1 AND rel_path >= ?2 AND rel_path < ?3"
        ))
        .db()?;
    let rows = stmt.query_map(params![folder.0, lo, hi], file_row).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Assets directly inside `dir` (not in its subfolders).
pub fn assets_in_dir(conn: &Connection, folder: FolderId, dir: &str) -> Result<Vec<AssetFileRow>> {
    let mut all = assets_below_dir(conn, folder, dir)?;
    all.retain(|a| paths::rel_parent(&a.rel_path) == dir);
    Ok(all)
}

/// Inserts newly found files. Re-inserting a path that already exists is a no-op, so a scan raced by the file
/// watcher never creates duplicate records (plan §6.6: idempotent).
pub fn insert_assets(
    tx: &Transaction<'_>,
    folder: FolderId,
    files: &[ScannedFile],
    lane: u8,
    now: i64,
) -> Result<Vec<AssetId>> {
    let mut inserted = Vec::with_capacity(files.len());
    let mut insert = tx
        .prepare_cached(
            "INSERT INTO assets(folder_id, rel_path, name, ext, kind, size, mtime, quick_hash, added_at, sort_date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?7)
             ON CONFLICT(folder_id, rel_path) DO NOTHING",
        )
        .db()?;
    let mut fts = tx
        .prepare_cached("INSERT INTO asset_fts(rowid, name, path, tags, notes) VALUES (?1, ?2, ?3, '', '')")
        .db()?;
    for f in files {
        let name = paths::rel_name(&f.rel_path);
        let ext = name.rsplit_once('.').map_or("", |(_, e)| e).to_ascii_lowercase();
        let n = insert
            .execute(params![
                folder.0,
                f.rel_path,
                name,
                ext,
                f.kind.to_db(),
                f.size,
                f.mtime,
                &f.quick_hash[..],
                now
            ])
            .db()?;
        if n == 0 {
            continue;
        }
        let id = tx.last_insert_rowid();
        fts.execute(params![id, name, f.rel_path]).db()?;
        jobs::enqueue(tx, MEDIA_JOB, AssetId(id), "", lane, false, now)?;
        inserted.push(AssetId(id));
    }
    Ok(inserted)
}

/// The file at an existing path changed on disk: refresh its facts and queue it for a new thumbnail and probe.
pub fn update_changed(
    tx: &Transaction<'_>,
    id: AssetId,
    size: i64,
    mtime: i64,
    quick_hash: [u8; 16],
    now: i64,
) -> Result<()> {
    tx.execute(
        "UPDATE assets SET size = ?2, mtime = ?3, quick_hash = ?4, content_hash = NULL,
                probe_state = 0, status = 0, missing_since = NULL,
                sort_date = COALESCE(capture_at, ?3)
         WHERE id = ?1",
        params![id.0, size, mtime, &quick_hash[..]],
    )
    .db()?;
    // Hashes of the old content mean nothing now.
    crate::dedupe::clear_derived(tx, id)?;
    crate::embeddings::clear_derived(tx, id)?;
    crate::text::clear_derived(tx, id)?;
    jobs::enqueue(tx, MEDIA_JOB, id, "", 2, true, now)
}

/// Marks assets whose file has gone as missing. Their tags and ratings are kept (plan L3, H2).
pub fn mark_missing(tx: &Transaction<'_>, ids: &[AssetId], now: i64) -> Result<usize> {
    if ids.is_empty() {
        return Ok(0);
    }
    let raw: Vec<i64> = ids.iter().map(|i| i.0).collect();
    let n = tx
        .execute(
            "UPDATE assets SET status = 1, missing_since = COALESCE(missing_since, ?2)
             WHERE status = 0 AND id IN (SELECT value FROM json_each(?1))",
            params![ids_json(&raw), now],
        )
        .db()?;
    // Missing files must not be probed: cancel their pending jobs.
    tx.execute(
        "UPDATE jobs SET state = 4, lease_token = NULL, updated_at = ?2
         WHERE state IN (0, 1) AND asset_id IN (SELECT value FROM json_each(?1))",
        params![ids_json(&raw), now],
    )
    .db()?;
    Ok(n)
}

/// The file is back at its old path, unchanged.
pub fn mark_present(tx: &Transaction<'_>, id: AssetId) -> Result<()> {
    tx.execute("UPDATE assets SET status = 0, missing_since = NULL WHERE id = ?1", [id.0])
        .db()?;
    Ok(())
}

/// Missing assets with this size and quick hash: the candidates for "this new file is that file, moved" (plan L3).
pub fn relink_candidates(conn: &Connection, size: i64, quick_hash: [u8; 16]) -> Result<Vec<RelinkCandidate>> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT id, folder_id, rel_path, mtime, content_hash FROM assets
             WHERE size = ?1 AND quick_hash = ?2 AND status = 1",
        )
        .db()?;
    let rows = stmt
        .query_map(params![size, &quick_hash[..]], |r| {
            Ok(RelinkCandidate {
                id: AssetId(r.get(0)?),
                folder_id: FolderId(r.get(1)?),
                rel_path: r.get(2)?,
                mtime: r.get(3)?,
                content_hash: r.get(4)?,
            })
        })
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// The full-content hash of an asset, when one has been computed.
pub fn content_hash_of(conn: &Connection, id: AssetId) -> Result<Option<Vec<u8>>> {
    conn.query_row("SELECT content_hash FROM assets WHERE id = ?1", [id.0], |r| r.get::<_, Option<Vec<u8>>>(0))
        .optional()
        .map(Option::flatten)
        .db()
}

/// Gives a missing asset its new location. Everything the user attached to it comes along.
pub fn relink(
    tx: &Transaction<'_>,
    id: AssetId,
    folder: FolderId,
    rel_path: &str,
    mtime: i64,
) -> Result<()> {
    let name = paths::rel_name(rel_path);
    let ext = name.rsplit_once('.').map_or("", |(_, e)| e).to_ascii_lowercase();
    tx.execute(
        "UPDATE assets SET folder_id = ?2, rel_path = ?3, name = ?4, ext = ?5, mtime = ?6,
                status = 0, missing_since = NULL, sort_date = COALESCE(capture_at, ?6)
         WHERE id = ?1",
        params![id.0, folder.0, rel_path, name, ext, mtime],
    )
    .db()?;
    tx.execute(
        "UPDATE asset_fts SET name = ?2, path = ?3 WHERE rowid = ?1",
        params![id.0, name, rel_path],
    )
    .db()?;
    Ok(())
}

/// Removes assets from the index (never from disk). Returns their thumbnails for cleanup.
pub fn delete_assets(tx: &Transaction<'_>, ids: &[AssetId]) -> Result<Vec<ThumbKey>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let json = ids_json(&ids.iter().map(|i| i.0).collect::<Vec<_>>());
    let thumbs: Vec<ThumbKey> = {
        let mut stmt = tx
            .prepare(
                "SELECT id, thumb_rev FROM assets
                 WHERE thumb_rev > 0 AND id IN (SELECT value FROM json_each(?1))",
            )
            .db()?;
        let rows = stmt
            .query_map([&json], |r| Ok(ThumbKey { asset_id: r.get(0)?, rev: r.get(1)? }))
            .db()?;
        rows.collect::<std::result::Result<_, _>>().db()?
    };
    tx.execute("DELETE FROM asset_fts WHERE rowid IN (SELECT value FROM json_each(?1))", [&json]).db()?;
    tx.execute("DELETE FROM assets WHERE id IN (SELECT value FROM json_each(?1))", [&json]).db()?;
    Ok(thumbs)
}

/// Stores what the media worker found (plan §6.3 `submit_results`). Returns `false` if the asset no longer exists.
pub fn apply_probe(
    tx: &Transaction<'_>,
    id: AssetId,
    probe: &ProbeResult,
    thumb_rev: Option<i64>,
) -> Result<bool> {
    let (orientation, aspect) = match (probe.width, probe.height) {
        (Some(w), Some(h)) if w > 0 && h > 0 => {
            let (o, a) = classify(w, h);
            (Some(o.to_db()), Some(a.to_db()))
        }
        _ => (None, None),
    };
    let n = tx
        .execute(
            "UPDATE assets SET probe_state = 1, width = ?2, height = ?3, orientation = ?4, aspect_class = ?5,
                    duration_ms = ?6, codec = ?7, fps = ?8, sample_rate = ?9, channels = ?10, bitrate = ?11,
                    capture_at = ?12, sort_date = COALESCE(?12, mtime),
                    camera_make = ?13, camera_model = ?14, lens = ?15, gps_lat = ?16, gps_lon = ?17,
                    exif_json = ?18, thumb_rev = MAX(thumb_rev, COALESCE(?19, 0))
             WHERE id = ?1",
            params![
                id.0,
                probe.width,
                probe.height,
                orientation,
                aspect,
                probe.duration_ms,
                probe.codec,
                probe.fps,
                probe.sample_rate,
                probe.channels,
                probe.bitrate,
                probe.capture_at,
                probe.camera_make,
                probe.camera_model,
                probe.lens,
                probe.gps_lat,
                probe.gps_lon,
                probe.exif_json,
                thumb_rev
            ],
        )
        .db()?;
    Ok(n > 0)
}

/// The worker could not read this file. It stays browsable by name; the job is not retried for corrupt files.
pub fn mark_probe_failed(tx: &Transaction<'_>, id: AssetId) -> Result<()> {
    tx.execute("UPDATE assets SET probe_state = 2 WHERE id = ?1", [id.0]).db()?;
    Ok(())
}

const SUMMARY_SELECT: &str = "SELECT a.id, a.folder_id, a.name, a.ext, a.kind, a.size, a.mtime, a.added_at, a.sort_date,
        a.width, a.height, a.aspect_class, a.duration_ms, a.thumb_rev, a.rating, a.flag, a.color_label,
        a.status, a.probe_state, v.is_online, v.name
     FROM assets a JOIN folders f ON f.id = a.folder_id JOIN volumes v ON v.id = f.volume_id";

fn summary(r: &Row<'_>) -> rusqlite::Result<AssetSummary> {
    let bad = |what: &str, v: i64| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Integer,
            format!("unknown {what} code {v}").into(),
        )
    };
    let kind_code: i64 = r.get(4)?;
    let flag_code: i64 = r.get(15)?;
    let label_code: i64 = r.get(16)?;
    Ok(AssetSummary {
        id: AssetId(r.get(0)?),
        folder_id: FolderId(r.get(1)?),
        name: r.get(2)?,
        ext: r.get(3)?,
        kind: MediaKind::from_db(kind_code).ok_or_else(|| bad("kind", kind_code))?,
        size: r.get(5)?,
        mtime: r.get(6)?,
        added_at: r.get(7)?,
        sort_date: r.get(8)?,
        width: r.get::<_, Option<i64>>(9)?.and_then(|v| u32::try_from(v).ok()),
        height: r.get::<_, Option<i64>>(10)?.and_then(|v| u32::try_from(v).ok()),
        aspect_class: r.get::<_, Option<i64>>(11)?.and_then(AspectClass::from_db),
        duration_ms: r.get(12)?,
        thumb_rev: r.get(13)?,
        rating: u8::try_from(r.get::<_, i64>(14)?.clamp(0, 5)).unwrap_or(0),
        flag: Flag::from_db(flag_code).ok_or_else(|| bad("flag", flag_code))?,
        color_label: ColorLabel::from_db(label_code).ok_or_else(|| bad("colour label", label_code))?,
        status: AssetStatus::from_db(r.get(17)?),
        probe_state: ProbeState::from_db(r.get(18)?),
        volume_online: r.get::<_, i64>(19)? != 0,
        volume_name: r.get(20)?,
    })
}

/// Summaries for a page of ids, in the order given. Ids that no longer exist are skipped.
pub fn summaries(conn: &Connection, ids: &[i64]) -> Result<Vec<AssetSummary>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut stmt = conn
        .prepare_cached(&format!(
            "{SUMMARY_SELECT} JOIN json_each(?1) j ON j.value = a.id ORDER BY j.key"
        ))
        .db()?;
    let rows = stmt.query_map([ids_json(ids)], summary).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Everything the inspector shows for one asset (plan V5).
pub fn detail(conn: &Connection, id: AssetId) -> Result<AssetDetail> {
    let summary = summaries(conn, &[id.0])?
        .into_iter()
        .next()
        .ok_or_else(|| Error::NotFound(format!("asset {id}")))?;
    let (rel_path, folder_name, mount, folder_rel, online): (String, String, Option<String>, String, bool) = conn
        .query_row(
            "SELECT a.rel_path, f.display_name, v.mount_path, f.rel_path, v.is_online
             FROM assets a JOIN folders f ON f.id = a.folder_id JOIN volumes v ON v.id = f.volume_id
             WHERE a.id = ?1",
            [id.0],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get::<_, i64>(4)? != 0)),
        )
        .db()?;
    let path = if online { mount.map(|m| join_all(&m, &folder_rel, &rel_path)) } else { None };

    let mut d = conn
        .query_row(
            "SELECT codec, fps, sample_rate, channels, bitrate, capture_at, camera_make, camera_model, lens,
                    gps_lat, gps_lon, exif_json, notes, content_hash
             FROM assets WHERE id = ?1",
            [id.0],
            |r| {
                Ok(AssetDetail {
                    summary: summary.clone(),
                    rel_path: rel_path.clone(),
                    folder_name: folder_name.clone(),
                    path: path.clone(),
                    codec: r.get(0)?,
                    fps: r.get(1)?,
                    sample_rate: r.get(2)?,
                    channels: r.get(3)?,
                    bitrate: r.get(4)?,
                    capture_at: r.get(5)?,
                    camera_make: r.get(6)?,
                    camera_model: r.get(7)?,
                    lens: r.get(8)?,
                    gps_lat: r.get(9)?,
                    gps_lon: r.get(10)?,
                    exif_json: r.get(11)?,
                    notes: r.get(12)?,
                    tags: Vec::new(),
                    content_hash_hex: r.get::<_, Option<Vec<u8>>>(13)?.map(|h| hex(&h)),
                })
            },
        )
        .db()?;
    let mut stmt = conn
        .prepare_cached(
            "SELECT t.name FROM asset_tags at JOIN tags t ON t.id = at.tag_id
             WHERE at.asset_id = ?1 ORDER BY t.name COLLATE NOCASE",
        )
        .db()?;
    d.tags = stmt
        .query_map([id.0], |r| r.get::<_, String>(0))
        .db()?
        .collect::<std::result::Result<_, _>>()
        .db()?;
    Ok(d)
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

fn join_all(mount: &str, folder_rel: &str, asset_rel: &str) -> PathBuf {
    let mut p = PathBuf::from(mount);
    if !folder_rel.is_empty() {
        p.push(folder_rel);
    }
    p.push(asset_rel);
    p
}

/// Absolute paths for assets whose drive is online. Used for opening, dragging and preview.
pub fn resolve_paths(conn: &Connection, ids: &[i64]) -> Result<Vec<(AssetId, Option<PathBuf>)>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.id, v.mount_path, f.rel_path, a.rel_path, v.is_online
             FROM json_each(?1) j JOIN assets a ON a.id = j.value
               JOIN folders f ON f.id = a.folder_id JOIN volumes v ON v.id = f.volume_id
             ORDER BY j.key",
        )
        .db()?;
    let rows = stmt
        .query_map([ids_json(ids)], |r| {
            let online = r.get::<_, i64>(4)? != 0;
            let mount: Option<String> = r.get(1)?;
            let path = if online {
                mount.map(|m| {
                    join_all(&m, &r.get::<_, String>(2).unwrap_or_default(), &r.get::<_, String>(3).unwrap_or_default())
                })
            } else {
                None
            };
            Ok((AssetId(r.get(0)?), path))
        })
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Total number of assets, including missing ones.
pub fn count(conn: &Connection) -> Result<i64> {
    conn.query_row("SELECT COUNT(*) FROM assets", [], |r| r.get(0)).db()
}

/// Assets still waiting for metadata and a thumbnail that have no queued job (after a cancel).
pub fn unprobed_without_job(conn: &Connection, limit: i64) -> Result<Vec<AssetId>> {
    let mut stmt = conn
        .prepare(
            "SELECT a.id FROM assets a
             WHERE a.probe_state = 0 AND a.status = 0
               AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.asset_id = a.id AND j.kind = 'media' AND j.state IN (0, 1))
             LIMIT ?1",
        )
        .db()?;
    let rows = stmt.query_map([limit], |r| Ok(AssetId(r.get(0)?))).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Current facts for one asset, used to verify a job result is still about the same file.
pub fn file_fingerprint(conn: &Connection, id: AssetId) -> Result<Option<(i64, i64)>> {
    conn.query_row("SELECT size, mtime FROM assets WHERE id = ?1", [id.0], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .db()
}

/// Whether any asset is currently missing (so scans know whether looking for moved files can find anything).
pub fn has_missing(conn: &Connection) -> Result<bool> {
    conn.query_row("SELECT EXISTS(SELECT 1 FROM assets WHERE status = 1)", [], |r| r.get(0)).db()
}

/// A freshly added asset that is probably the moved copy of a file that just went missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Twin {
    pub id: AssetId,
    pub folder_id: FolderId,
    pub rel_path: String,
    pub mtime: i64,
    /// Where the file is right now, or `None` while its drive is unplugged.
    pub abs_path: Option<PathBuf>,
}

/// Present assets with the same size and quick hash that were added at or after `since` and carry no user data
/// (no rating, flag, label, notes, tag or collection). Only such an asset may be merged into a missing one
/// without losing anything the user did.
pub fn recent_untouched_twins(
    conn: &Connection,
    size: i64,
    quick_hash: [u8; 16],
    exclude: AssetId,
    since: i64,
) -> Result<Vec<Twin>> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.id, a.folder_id, a.rel_path, a.mtime, v.mount_path, f.rel_path, v.is_online
             FROM assets a JOIN folders f ON f.id = a.folder_id JOIN volumes v ON v.id = f.volume_id
             WHERE a.size = ?1 AND a.quick_hash = ?2 AND a.status = 0 AND a.id <> ?3 AND a.added_at >= ?4
               AND a.rating = 0 AND a.flag = 0 AND a.color_label = 0 AND a.notes = ''
               AND NOT EXISTS (SELECT 1 FROM asset_tags t WHERE t.asset_id = a.id)
               AND NOT EXISTS (SELECT 1 FROM collection_items c WHERE c.asset_id = a.id)",
        )
        .db()?;
    let rows = stmt
        .query_map(params![size, &quick_hash[..], exclude.0, since], |r| {
            let rel_path: String = r.get(2)?;
            let mount: Option<String> = r.get(4)?;
            let online = r.get::<_, i64>(6)? != 0;
            let abs_path = mount.filter(|_| online).map(|m| join_all(&m, &r.get::<_, String>(5).unwrap_or_default(), &rel_path));
            Ok(Twin { id: AssetId(r.get(0)?), folder_id: FolderId(r.get(1)?), rel_path, mtime: r.get(3)?, abs_path })
        })
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Keeps `keep` (which owns the user's data) and gives it the location of `twin`, a duplicate record created for the
/// same moved file. The twin record is deleted. Returns the twin's thumbnail for cleanup.
pub fn absorb_twin(tx: &Transaction<'_>, keep: AssetId, twin: &Twin, now: i64) -> Result<Vec<ThumbKey>> {
    let thumbs = delete_assets(tx, &[twin.id])?;
    relink(tx, keep, twin.folder_id, &twin.rel_path, twin.mtime)?;
    let pending: bool = tx
        .query_row("SELECT probe_state = 0 FROM assets WHERE id = ?1", [keep.0], |r| r.get(0))
        .db()?;
    if pending {
        jobs::enqueue(tx, MEDIA_JOB, keep, "", 2, true, now)?;
    }
    Ok(thumbs)
}

/// Removes assets from the index **only if they are marked missing** (plan H2: "Remove from Library"). Present files are never
/// touched, whatever ids are passed. `None` means every missing asset. Returns how many were removed and their thumbnails.
pub fn delete_missing(tx: &Transaction<'_>, ids: Option<&[AssetId]>) -> Result<(usize, Vec<ThumbKey>)> {
    let (sql, json) = match ids {
        Some(list) => (
            "SELECT id FROM assets WHERE status = 1 AND id IN (SELECT value FROM json_each(?1))",
            ids_json(&list.iter().map(|i| i.0).collect::<Vec<_>>()),
        ),
        None => ("SELECT id FROM assets WHERE status = 1 AND ?1 = ?1", String::new()),
    };
    let selected: Vec<AssetId> = {
        let mut stmt = tx.prepare(sql).db()?;
        let rows = stmt.query_map([json], |r| Ok(AssetId(r.get(0)?))).db()?;
        rows.collect::<std::result::Result<_, _>>().db()?
    };
    let thumbs = delete_assets(tx, &selected)?;
    Ok((selected.len(), thumbs))
}
