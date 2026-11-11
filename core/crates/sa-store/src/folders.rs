//! Volumes and the folders the user added (plan L1, L1a, L4, L5, H2).

use crate::error::DbResultExt;
use crate::model::{FolderInfo, FolderRow, ScanState, ThumbKey, VolumeRow};
use crate::util::{below, is_excluded, is_within, strip_parent};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use sa_core::{Error, FolderId, Result, VolumeId, paths};

fn volume_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<VolumeRow> {
    Ok(VolumeRow {
        id: VolumeId(r.get("id")?),
        uuid: r.get("uuid")?,
        name: r.get("name")?,
        mount_path: r.get("mount_path")?,
        is_internal: r.get::<_, i64>("is_internal")? != 0,
        is_online: r.get::<_, i64>("is_online")? != 0,
        last_seen_at: r.get("last_seen_at")?,
    })
}

fn folder_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<FolderRow> {
    Ok(FolderRow {
        id: FolderId(r.get("id")?),
        volume_id: VolumeId(r.get("volume_id")?),
        rel_path: r.get("rel_path")?,
        display_name: r.get("display_name")?,
        bookmark: r.get("bookmark")?,
        enabled: r.get::<_, i64>("enabled")? != 0,
        added_at: r.get("added_at")?,
        last_scan_at: r.get("last_scan_at")?,
        scan_state: ScanState::from_db(r.get("scan_state")?),
        last_error: r.get("last_error")?,
    })
}

/// Records a volume the app has seen, marking it online at `mount_path`.
pub fn upsert_volume(
    tx: &Transaction<'_>,
    uuid: &str,
    name: &str,
    mount_path: &str,
    is_internal: bool,
    now: i64,
) -> Result<VolumeId> {
    if uuid.is_empty() {
        return Err(Error::Invalid("volume uuid is empty".into()));
    }
    tx.execute(
        "INSERT INTO volumes(uuid, name, mount_path, is_internal, is_online, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, 1, ?5)
         ON CONFLICT(uuid) DO UPDATE SET
             name = excluded.name, mount_path = excluded.mount_path,
             is_internal = excluded.is_internal, is_online = 1, last_seen_at = excluded.last_seen_at",
        params![uuid, name, mount_path, is_internal, now],
    )
    .db()?;
    let id: i64 = tx
        .query_row("SELECT id FROM volumes WHERE uuid = ?1", [uuid], |r| r.get(0))
        .db()?;
    Ok(VolumeId(id))
}

/// A drive was plugged in (`Some(mount_path)`) or removed (`None`). Unknown volumes are ignored.
/// Returns the volume id when the volume is known.
pub fn set_volume_online(
    tx: &Transaction<'_>,
    uuid: &str,
    mount_path: Option<&str>,
    now: i64,
) -> Result<Option<VolumeId>> {
    let changed = match mount_path {
        Some(path) => tx.execute(
            "UPDATE volumes SET is_online = 1, mount_path = ?2, last_seen_at = ?3 WHERE uuid = ?1",
            params![uuid, path, now],
        ),
        None => tx.execute(
            "UPDATE volumes SET is_online = 0, mount_path = NULL WHERE uuid = ?1",
            params![uuid],
        ),
    }
    .db()?;
    if changed == 0 {
        return Ok(None);
    }
    let id: i64 = tx
        .query_row("SELECT id FROM volumes WHERE uuid = ?1", [uuid], |r| r.get(0))
        .db()?;
    Ok(Some(VolumeId(id)))
}

pub fn list_volumes(conn: &Connection) -> Result<Vec<VolumeRow>> {
    let mut stmt = conn.prepare("SELECT * FROM volumes ORDER BY is_internal DESC, name").db()?;
    let rows = stmt.query_map([], volume_from_row).db()?;
    rows.collect::<std::result::Result<Vec<_>, _>>().db()
}

pub fn volume(conn: &Connection, id: VolumeId) -> Result<VolumeRow> {
    conn.query_row("SELECT * FROM volumes WHERE id = ?1", [id.0], volume_from_row)
        .optional()
        .db()?
        .ok_or_else(|| Error::NotFound(format!("volume {id}")))
}

pub fn volume_by_uuid(conn: &Connection, uuid: &str) -> Result<Option<VolumeRow>> {
    conn.query_row("SELECT * FROM volumes WHERE uuid = ?1", [uuid], volume_from_row)
        .optional()
        .db()
}

/// Result of asking to add a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddFolderOutcome {
    /// The folder was added. `absorbed` are previously added folders inside it, merged in with their data kept.
    Added { id: FolderId, absorbed: Vec<FolderId> },
    /// That exact folder is already in the library.
    AlreadyAdded(FolderId),
    /// The folder is inside one already added. `excluded` means that folder skips it on purpose.
    InsideExisting { folder: FolderId, folder_name: String, excluded: bool },
}

/// Adds a folder the user picked. Nothing is indexed until the scanner runs.
pub fn add_folder(
    tx: &Transaction<'_>,
    volume_id: VolumeId,
    rel_path: &str,
    display_name: &str,
    bookmark: Option<&[u8]>,
    now: i64,
) -> Result<AddFolderOutcome> {
    let rel = paths::normalize_rel(rel_path)?;

    let existing: Vec<FolderRow> = {
        let mut stmt = tx.prepare("SELECT * FROM folders WHERE volume_id = ?1").db()?;
        let rows = stmt.query_map([volume_id.0], folder_from_row).db()?;
        rows.collect::<std::result::Result<_, _>>().db()?
    };

    for e in &existing {
        if e.rel_path == rel {
            return Ok(AddFolderOutcome::AlreadyAdded(e.id));
        }
        if is_within(&rel, &e.rel_path) {
            let sub = strip_parent(&rel, &e.rel_path);
            let excluded = excludes_of(tx, e.id)?.iter().any(|x| is_excluded(sub, x));
            return Ok(AddFolderOutcome::InsideExisting {
                folder: e.id,
                folder_name: e.display_name.clone(),
                excluded,
            });
        }
    }

    tx.execute(
        "INSERT INTO folders(volume_id, rel_path, display_name, bookmark, added_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![volume_id.0, rel, display_name, bookmark, now],
    )
    .db()?;
    let new_id = FolderId(tx.last_insert_rowid());

    // Folders already added inside the new one are merged in: assets keep their ids, so tags, ratings and
    // collection membership survive.
    let mut absorbed = Vec::new();
    for child in existing.iter().filter(|c| is_within(&c.rel_path, &rel)) {
        let prefix = strip_parent(&child.rel_path, &rel).to_string();
        tx.execute(
            "UPDATE asset_fts SET path = ?1 || '/' || path
             WHERE rowid IN (SELECT id FROM assets WHERE folder_id = ?2)",
            params![prefix, child.id.0],
        )
        .db()?;
        tx.execute(
            "UPDATE assets SET folder_id = ?1, rel_path = ?3 || '/' || rel_path WHERE folder_id = ?2",
            params![new_id.0, child.id.0, prefix],
        )
        .db()?;
        tx.execute(
            "INSERT INTO folder_excludes(folder_id, rel_path)
             SELECT ?1, ?3 || '/' || rel_path FROM folder_excludes WHERE folder_id = ?2",
            params![new_id.0, child.id.0, prefix],
        )
        .db()?;
        tx.execute("DELETE FROM folders WHERE id = ?1", [child.id.0]).db()?;
        absorbed.push(child.id);
    }
    Ok(AddFolderOutcome::Added { id: new_id, absorbed })
}

fn excludes_of(tx: &Connection, id: FolderId) -> Result<Vec<String>> {
    let mut stmt = tx
        .prepare("SELECT rel_path FROM folder_excludes WHERE folder_id = ?1 ORDER BY rel_path")
        .db()?;
    let rows = stmt.query_map([id.0], |r| r.get::<_, String>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// What was removed from the index when a folder or exclusion was removed. Only index data is deleted.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RemovedAssets {
    pub asset_count: i64,
    pub thumbs: Vec<ThumbKey>,
}

fn thumbs_where(tx: &Transaction<'_>, sql: &str, args: &[&dyn rusqlite::ToSql]) -> Result<Vec<ThumbKey>> {
    let mut stmt = tx.prepare(sql).db()?;
    let rows = stmt
        .query_map(args, |r| {
            Ok(ThumbKey { asset_id: r.get(0)?, rev: r.get(1)? })
        })
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Removes a folder from the index. The files on disk are never touched.
pub fn remove_folder(tx: &Transaction<'_>, id: FolderId) -> Result<RemovedAssets> {
    let exists: bool = tx
        .query_row("SELECT 1 FROM folders WHERE id = ?1", [id.0], |_| Ok(true))
        .optional()
        .db()?
        .unwrap_or(false);
    if !exists {
        return Err(Error::NotFound(format!("folder {id}")));
    }
    let thumbs = thumbs_where(
        tx,
        "SELECT id, thumb_rev FROM assets WHERE folder_id = ?1 AND thumb_rev > 0",
        &[&id.0],
    )?;
    let asset_count: i64 = tx
        .query_row("SELECT COUNT(*) FROM assets WHERE folder_id = ?1", [id.0], |r| r.get(0))
        .db()?;
    tx.execute(
        "DELETE FROM asset_fts WHERE rowid IN (SELECT id FROM assets WHERE folder_id = ?1)",
        [id.0],
    )
    .db()?;
    tx.execute("DELETE FROM folders WHERE id = ?1", [id.0]).db()?; // cascades to assets, jobs, tags, collection items
    Ok(RemovedAssets { asset_count, thumbs })
}

/// Turns a whole folder on or off (plan L5). Off folders keep their data but vanish from results and jobs.
pub fn set_folder_enabled(tx: &Transaction<'_>, id: FolderId, enabled: bool) -> Result<()> {
    let n = tx
        .execute("UPDATE folders SET enabled = ?2 WHERE id = ?1", params![id.0, enabled])
        .db()?;
    if n == 0 {
        return Err(Error::NotFound(format!("folder {id}")));
    }
    Ok(())
}

pub fn set_folder_bookmark(tx: &Transaction<'_>, id: FolderId, bookmark: &[u8]) -> Result<()> {
    tx.execute("UPDATE folders SET bookmark = ?2 WHERE id = ?1", params![id.0, bookmark])
        .db()?;
    Ok(())
}

/// Points a folder at its new location after the user moved it (plan H2). Assets keep their relative paths.
pub fn relocate_folder(
    tx: &Transaction<'_>,
    id: FolderId,
    volume_id: VolumeId,
    rel_path: &str,
    display_name: &str,
) -> Result<()> {
    let rel = paths::normalize_rel(rel_path)?;
    let clash: Option<i64> = tx
        .query_row(
            "SELECT id FROM folders WHERE volume_id = ?1 AND rel_path = ?2 AND id <> ?3",
            params![volume_id.0, rel, id.0],
            |r| r.get(0),
        )
        .optional()
        .db()?;
    if clash.is_some() {
        return Err(Error::Invalid("another added folder already uses that location".into()));
    }
    let n = tx
        .execute(
            "UPDATE folders SET volume_id = ?2, rel_path = ?3, display_name = ?4, scan_state = 0 WHERE id = ?1",
            params![id.0, volume_id.0, rel, display_name],
        )
        .db()?;
    if n == 0 {
        return Err(Error::NotFound(format!("folder {id}")));
    }
    Ok(())
}

/// Replaces the set of excluded subfolders (plan L1a) and removes anything already indexed below them.
pub fn set_excludes(
    tx: &Transaction<'_>,
    id: FolderId,
    excludes: &[String],
) -> Result<RemovedAssets> {
    let mut norm: Vec<String> = Vec::with_capacity(excludes.len());
    for e in excludes {
        let n = paths::normalize_rel(e)?;
        if n.is_empty() {
            return Err(Error::Invalid("cannot exclude the folder itself; remove it instead".into()));
        }
        if !norm.contains(&n) {
            norm.push(n);
        }
    }
    tx.execute("DELETE FROM folder_excludes WHERE folder_id = ?1", [id.0]).db()?;
    for n in &norm {
        tx.execute(
            "INSERT INTO folder_excludes(folder_id, rel_path) VALUES (?1, ?2)",
            params![id.0, n],
        )
        .db()?;
    }

    let mut removed = RemovedAssets::default();
    for n in &norm {
        let (lo, hi) = below(n);
        let mut thumbs = thumbs_where(
            tx,
            "SELECT id, thumb_rev FROM assets
             WHERE folder_id = ?1 AND rel_path >= ?2 AND rel_path < ?3 AND thumb_rev > 0",
            &[&id.0, &lo, &hi],
        )?;
        tx.execute(
            "DELETE FROM asset_fts WHERE rowid IN
               (SELECT id FROM assets WHERE folder_id = ?1 AND rel_path >= ?2 AND rel_path < ?3)",
            params![id.0, lo, hi],
        )
        .db()?;
        let n_deleted = tx
            .execute(
                "DELETE FROM assets WHERE folder_id = ?1 AND rel_path >= ?2 AND rel_path < ?3",
                params![id.0, lo, hi],
            )
            .db()?;
        removed.asset_count += i64::try_from(n_deleted).unwrap_or(i64::MAX);
        removed.thumbs.append(&mut thumbs);
    }
    Ok(removed)
}

pub fn excludes(conn: &Connection, id: FolderId) -> Result<Vec<String>> {
    excludes_of(conn, id)
}

pub fn folder(conn: &Connection, id: FolderId) -> Result<FolderRow> {
    conn.query_row("SELECT * FROM folders WHERE id = ?1", [id.0], folder_from_row)
        .optional()
        .db()?
        .ok_or_else(|| Error::NotFound(format!("folder {id}")))
}

pub fn set_scan_state(
    tx: &Transaction<'_>,
    id: FolderId,
    state: ScanState,
    error: Option<&str>,
    now: i64,
) -> Result<()> {
    let finished = matches!(state, ScanState::Idle);
    tx.execute(
        "UPDATE folders SET scan_state = ?2, last_error = ?3,
                last_scan_at = CASE WHEN ?4 THEN ?5 ELSE last_scan_at END
         WHERE id = ?1",
        params![id.0, state as i64, error, finished, now],
    )
    .db()?;
    Ok(())
}

/// After a restart nothing is scanning any more: interrupted scans start over (scans are idempotent).
pub fn reset_scan_states(tx: &Transaction<'_>) -> Result<()> {
    tx.execute("UPDATE folders SET scan_state = 0 WHERE scan_state = 1", []).db()?;
    Ok(())
}

/// Every folder with the figures the folder list shows.
pub fn list_folders(conn: &Connection) -> Result<Vec<FolderInfo>> {
    struct Counts {
        assets: i64,
        missing: i64,
        size: i64,
        pending: i64,
    }
    let mut counts = std::collections::HashMap::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT folder_id, COUNT(*), COALESCE(SUM(status = 1), 0), COALESCE(SUM(size), 0),
                        COALESCE(SUM(probe_state = 0 AND status = 0), 0)
                 FROM assets GROUP BY folder_id",
            )
            .db()?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    Counts { assets: r.get(1)?, missing: r.get(2)?, size: r.get(3)?, pending: r.get(4)? },
                ))
            })
            .db()?;
        for row in rows {
            let (id, c) = row.db()?;
            counts.insert(id, c);
        }
    }
    let volumes: std::collections::HashMap<i64, VolumeRow> =
        list_volumes(conn)?.into_iter().map(|v| (v.id.0, v)).collect();

    let mut stmt = conn
        .prepare("SELECT * FROM folders ORDER BY display_name COLLATE NOCASE, id")
        .db()?;
    let folders: Vec<FolderRow> = stmt
        .query_map([], folder_from_row)
        .db()?
        .collect::<std::result::Result<_, _>>()
        .db()?;

    let mut out = Vec::with_capacity(folders.len());
    for f in folders {
        let Some(volume) = volumes.get(&f.volume_id.0).cloned() else { continue };
        let c = counts.get(&f.id.0);
        out.push(FolderInfo {
            asset_count: c.map_or(0, |c| c.assets),
            missing_count: c.map_or(0, |c| c.missing),
            total_size: c.map_or(0, |c| c.size),
            pending_count: c.map_or(0, |c| c.pending),
            excludes: excludes_of(conn, f.id)?,
            folder: f,
            volume,
        });
    }
    Ok(out)
}

/// Ids of folders whose assets must not appear in results (plan L5).
pub fn disabled_folder_ids(conn: &Connection) -> Result<Vec<i64>> {
    let mut stmt = conn.prepare("SELECT id FROM folders WHERE enabled = 0").db()?;
    let rows = stmt.query_map([], |r| r.get::<_, i64>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Asset ids (any state) in a folder, for bulk operations such as "re-index this folder".
pub fn asset_ids_in_folder(conn: &Connection, id: FolderId) -> Result<Vec<i64>> {
    let mut stmt = conn.prepare("SELECT id FROM assets WHERE folder_id = ?1").db()?;
    let rows = stmt.query_map([id.0], |r| r.get::<_, i64>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}
