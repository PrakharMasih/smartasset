//! Folder scanning: discover → fingerprint → diff against the database → apply (plan §6.6 browse pass).
//!
//! # Safety rules this module enforces
//! * It only ever *reads* the folders it scans.
//! * A file is marked missing only when a scan **completed** and could see the directory it lives in. A cancelled
//!   scan, an unreadable subfolder, an unreachable folder root or an unplugged drive never produce "missing".
//! * Hidden items, symlinks, opaque bundles (`.photoslibrary`, `.fcpbundle`, …) and excluded subfolders are skipped.
//! * Files that live only in iCloud (placeholders) are skipped, so a scan can never trigger a download.
//! * Re-running a scan is always safe: inserts are idempotent and unchanged files are not touched.

use crate::fingerprint::{content_hash, is_dataless_flags, quick_hash};
use rayon::prelude::*;
use sa_core::time::{now_ms, system_time_to_ms};
use sa_core::{AssetId, Error, FolderId, MediaKind, Result, paths};
use sa_store::model::{AssetFileRow, AssetStatus, RelinkCandidate, ScannedFile};
use sa_store::{Db, assets, util};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use walkdir::{DirEntry, WalkDir};

/// Files hashed and written per step. Bounds memory and keeps each write transaction short.
const CHUNK: usize = 1024;
/// A whole-folder scan that finds nothing while the database holds at least this many assets is treated as
/// "the drive or share went away", not "the user deleted everything".
const VANISH_GUARD_MIN_ASSETS: usize = 20;
/// An asset added this recently, with no user data, may be merged into a file that just went missing.
const TWIN_WINDOW_MS: i64 = 10 * 60 * 1000;

/// A moved file is confirmed by its full hash only up to this size, and only up to `CONFIRM_BUDGET` bytes per scan, so
/// a big move can never turn into a huge read. Beyond that the quick hash decides, as it always did.
const CONFIRM_MAX_FILE: u64 = 512 * 1024 * 1024;
const CONFIRM_BUDGET: u64 = 4 * 1024 * 1024 * 1024;

/// A dedicated, bounded pool for hashing, so scanning never competes with the rest of the app for every core.
#[derive(Debug)]
pub struct ScannerPool {
    pool: rayon::ThreadPool,
}

impl ScannerPool {
    pub fn new(threads: usize) -> Result<Self> {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads.max(1))
            .thread_name(|i| format!("sa-scan-{i}"))
            .build()
            .map_err(|e| Error::Invalid(format!("cannot start scanner threads: {e}")))?;
        Ok(Self { pool })
    }
}

#[derive(Debug, Clone)]
pub struct ScanTarget {
    pub folder: FolderId,
    /// Absolute path of the folder root.
    pub root: PathBuf,
    /// Directory to scan, relative to `root`; `""` scans the whole folder.
    pub dir: String,
    /// Excluded subfolders, relative to `root`.
    pub excludes: Vec<String>,
    /// Priority lane for newly found assets (plan §6.6).
    pub lane: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ScanProgress {
    pub files_seen: u64,
    pub new_files: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanOutcome {
    Completed,
    /// Stopped early on request. Nothing was marked missing.
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanReport {
    pub outcome: ScanOutcome,
    pub files_seen: u64,
    pub new_files: u64,
    pub changed: u64,
    pub relinked: u64,
    pub restored: u64,
    pub marked_missing: u64,
    pub merged_twins: u64,
    /// iCloud placeholders left alone.
    pub skipped_cloud_only: u64,
    /// Files that could not be read this time (being written, permission). They are retried on the next scan.
    pub skipped_unreadable: u64,
    pub skipped_non_utf8: u64,
    /// Folders that could not be listed. Assets below them are left exactly as they were.
    pub unreadable_dirs: Vec<String>,
    /// Everything in the folder seemed to vanish at once, so nothing was marked missing.
    pub held_back_missing: bool,
    /// Thumbnails that belonged to records deleted by merges; the caller removes the files.
    pub orphaned_thumbs: Vec<sa_store::model::ThumbKey>,
    /// Bytes read to confirm moved files by their full hash.
    pub relink_checked_bytes: u64,
    /// Times a file that looked like a moved file by size and samples turned out to differ in full, and was kept apart.
    pub relink_rejected: u64,
}

impl ScanReport {
    fn new() -> Self {
        Self {
            outcome: ScanOutcome::Completed,
            files_seen: 0,
            new_files: 0,
            changed: 0,
            relinked: 0,
            restored: 0,
            marked_missing: 0,
            merged_twins: 0,
            skipped_cloud_only: 0,
            skipped_unreadable: 0,
            skipped_non_utf8: 0,
            unreadable_dirs: Vec::new(),
            held_back_missing: false,
            orphaned_thumbs: Vec::new(),
            relink_checked_bytes: 0,
            relink_rejected: 0,
        }
    }
}

struct Existing {
    row: AssetFileRow,
    seen: bool,
}

struct Candidate {
    rel_path: String,
    abs: PathBuf,
    kind: MediaKind,
    size: i64,
    mtime: i64,
    existing: Option<AssetId>,
}

struct Hashed {
    cand: Candidate,
    hash: [u8; 16],
}

#[cfg(target_os = "macos")]
fn is_dataless(meta: &std::fs::Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    is_dataless_flags(meta.st_flags())
}

#[cfg(not(target_os = "macos"))]
fn is_dataless(_meta: &std::fs::Metadata) -> bool {
    false
}

fn rel_of(target: &ScanTarget, entry: &DirEntry) -> Option<String> {
    let rel = entry.path().strip_prefix(&target.root).ok()?.to_str()?;
    paths::normalize_rel(rel).ok()
}

fn should_enter(target: &ScanTarget, entry: &DirEntry) -> bool {
    if entry.depth() == 0 || !entry.file_type().is_dir() {
        return true;
    }
    let Some(name) = entry.file_name().to_str() else {
        return false;
    };
    if paths::is_hidden_name(name) || paths::is_opaque_bundle_dir(name) {
        return false;
    }
    match rel_of(target, entry) {
        Some(rel) => !target.excludes.iter().any(|x| util::is_excluded(&rel, x)),
        None => false,
    }
}

/// Scans one directory tree and brings the database in line with it.
///
/// # Errors
/// Fails (changing nothing it should not) if the folder root cannot be opened or the database fails.
#[allow(clippy::too_many_lines)]
pub fn scan(
    db: &Db,
    pool: &ScannerPool,
    target: &ScanTarget,
    cancel: &AtomicBool,
    progress: &(dyn Fn(ScanProgress) + Sync),
) -> Result<ScanReport> {
    // The folder root must be reachable. If it is not (drive unplugged, access revoked) nothing is touched,
    // above all nothing is marked missing.
    std::fs::read_dir(&target.root).map_err(|e| Error::io("open folder", &target.root, &e))?;

    let scan_root = paths::join_under(&target.root, &target.dir)?;
    let folder = target.folder;
    let dir = target.dir.clone();
    let existing_rows = db.read(|c| assets::assets_below_dir(c, folder, &dir))?;
    let mut existing: HashMap<String, Existing> = existing_rows
        .into_iter()
        .map(|row| (row.rel_path.clone(), Existing { row, seen: false }))
        .collect();
    let existing_total = existing.len();
    let missing_elsewhere = db.read(assets::has_missing)?;
    // First scan of a folder: show files as they are found. Rescans wait until the walk is done so a moved file
    // is never briefly shown as a new one.
    let streaming = existing.is_empty();

    let mut report = ScanReport::new();
    let mut pending_new: Vec<Hashed> = Vec::new();
    let mut chunk: Vec<Candidate> = Vec::with_capacity(CHUNK);
    let mut restored: Vec<AssetId> = Vec::new();
    let mut unreadable: Vec<String> = Vec::new();
    let mut cancelled = false;

    let walk_ok = scan_root.is_dir();
    if walk_ok {
        let walker = WalkDir::new(&scan_root)
            .follow_links(false)
            .into_iter()
            .filter_entry(|e| should_enter(target, e));
        for entry in walker {
            if cancel.load(Ordering::Relaxed) {
                cancelled = true;
                break;
            }
            let entry = match entry {
                Ok(e) => e,
                Err(err) => {
                    let rel = err
                        .path()
                        .and_then(|p| p.strip_prefix(&target.root).ok())
                        .and_then(|p| p.to_str())
                        .and_then(|s| paths::normalize_rel(s).ok());
                    if let Some(rel) = rel {
                        unreadable.push(rel);
                    }
                    continue;
                }
            };
            if !entry.file_type().is_file() {
                continue;
            }
            let Some(name) = entry.file_name().to_str() else {
                report.skipped_non_utf8 += 1;
                continue;
            };
            if paths::is_hidden_name(name) {
                continue;
            }
            let Some(kind) = name.rsplit_once('.').and_then(|(_, e)| MediaKind::from_extension(e)) else {
                continue;
            };
            let Some(rel) = rel_of(target, &entry) else {
                report.skipped_non_utf8 += 1;
                continue;
            };
            let Ok(meta) = entry.metadata() else {
                // Seen but unreadable right now: leave any existing record exactly as it is.
                if let Some(e) = existing.get_mut(&rel) {
                    e.seen = true;
                }
                report.skipped_unreadable += 1;
                continue;
            };
            if let Some(e) = existing.get_mut(&rel) {
                e.seen = true;
            }
            if is_dataless(&meta) {
                report.skipped_cloud_only += 1;
                continue;
            }
            report.files_seen += 1;
            let size = i64::try_from(meta.len()).unwrap_or(i64::MAX);
            let mtime = meta.modified().map_or(0, system_time_to_ms);

            let existing_id = match existing.get(&rel) {
                Some(e) if e.row.size == size && e.row.mtime == mtime => {
                    if e.row.status == AssetStatus::Missing {
                        restored.push(e.row.id);
                    }
                    continue;
                }
                Some(e) => Some(e.row.id),
                None => None,
            };
            chunk.push(Candidate { rel_path: rel, abs: entry.into_path(), kind, size, mtime, existing: existing_id });
            if chunk.len() >= CHUNK {
                flush(db, pool, target, &mut chunk, streaming, missing_elsewhere, &mut pending_new, &mut report)?;
                progress(ScanProgress { files_seen: report.files_seen, new_files: report.new_files });
            }
        }
        if !cancelled {
            flush(db, pool, target, &mut chunk, streaming, missing_elsewhere, &mut pending_new, &mut report)?;
        }
    }
    progress(ScanProgress { files_seen: report.files_seen, new_files: report.new_files });

    if cancelled {
        report.outcome = ScanOutcome::Cancelled;
        return Ok(report);
    }

    // Files that were missing and are back, unchanged.
    if !restored.is_empty() {
        report.restored = restored.len() as u64;
        db.write(move |tx| {
            for id in restored {
                assets::mark_present(tx, id)?;
            }
            Ok(())
        })?;
    }

    // Everything the walk could not see into stays exactly as it was.
    let unreadable_dirs = collapse_dirs(unreadable);
    let is_unknown = |rel: &str| unreadable_dirs.iter().any(|d| util::is_within(rel, d));

    // Vanish guard: a whole-folder scan that sees nothing while the database holds plenty is most likely a
    // network share or drive that dropped, not a deliberate deletion.
    if target.dir.is_empty()
        && report.files_seen == 0
        && report.skipped_cloud_only == 0
        && existing_total >= VANISH_GUARD_MIN_ASSETS
    {
        report.held_back_missing = true;
        report.unreadable_dirs = unreadable_dirs;
        return Ok(report);
    }

    let unseen: Vec<&Existing> = existing.values().filter(|e| !e.seen && !is_unknown(&e.row.rel_path)).collect();

    // Moves and renames: pair each new file with a vanished one that has the same content.
    let mut claimed: HashSet<AssetId> = HashSet::new();
    let mut relinks: Vec<(AssetId, FolderId, String, i64)> = Vec::new();
    let mut inserts: Vec<ScannedFile> = Vec::new();
    if !pending_new.is_empty() {
        let mut in_scan: HashMap<(i64, [u8; 16]), Vec<&Existing>> = HashMap::new();
        for e in &unseen {
            in_scan.entry((e.row.size, e.row.quick_hash)).or_default().push(e);
        }
        for h in pending_new {
            let c = &h.cand;
            let name = paths::rel_name(&c.rel_path);
            let local = in_scan
                .get(&(c.size, h.hash))
                .map(|v| {
                    v.iter()
                        .filter(|e| !claimed.contains(&e.row.id))
                        .map(|e| (e.row.id, paths::rel_name(&e.row.rel_path).to_string(), e.row.mtime))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let chosen = pick_match(local, name, c.mtime, |id| {
                confirms_same_content(db, id, &c.abs, c.size, &mut report)
            })
            .or_else(|| {
                if !missing_elsewhere {
                    return None;
                }
                let (size, hash) = (c.size, h.hash);
                let cands: Vec<RelinkCandidate> = db.read(|conn| assets::relink_candidates(conn, size, hash)).ok()?;
                let list = cands
                    .into_iter()
                    .filter(|r| !claimed.contains(&r.id))
                    .map(|r| (r.id, paths::rel_name(&r.rel_path).to_string(), r.mtime))
                    .collect();
                pick_match(list, name, c.mtime, |id| confirms_same_content(db, id, &c.abs, c.size, &mut report))
            });
            if let Some(id) = chosen {
                claimed.insert(id);
                relinks.push((id, target.folder, c.rel_path.clone(), c.mtime));
            } else {
                inserts.push(ScannedFile {
                    rel_path: c.rel_path.clone(),
                    kind: c.kind,
                    size: c.size,
                    mtime: c.mtime,
                    quick_hash: h.hash,
                });
            }
        }
    }
    report.relinked = relinks.len() as u64;
    report.new_files += inserts.len() as u64;
    for batch in relinks.chunks(CHUNK) {
        let batch = batch.to_vec();
        db.write(move |tx| {
            for (id, folder, rel, mtime) in &batch {
                assets::relink(tx, *id, *folder, rel, *mtime)?;
            }
            Ok(())
        })?;
    }
    let lane = target.lane;
    for batch in inserts.chunks(CHUNK) {
        let batch = batch.to_vec();
        let folder = target.folder;
        db.write(move |tx| assets::insert_assets(tx, folder, &batch, lane, now_ms()).map(|_| ()))?;
    }

    // What is still unseen is gone.
    let gone: Vec<&Existing> = unseen.into_iter().filter(|e| !claimed.contains(&e.row.id)).collect();
    report.marked_missing = gone.len() as u64;
    let gone_ids: Vec<AssetId> = gone.iter().map(|e| e.row.id).collect();
    for batch in gone_ids.chunks(CHUNK) {
        let batch = batch.to_vec();
        db.write(move |tx| assets::mark_missing(tx, &batch, now_ms()).map(|_| ()))?;
    }

    // A move across two watched folders arrives as two separate scans: the file shows up as a new record in one
    // before it vanishes in the other. Merge such a record back into the original, but only when the newcomer
    // carries no user data of its own, so nothing the user did can be lost.
    let since = now_ms() - TWIN_WINDOW_MS;
    for e in gone {
        let (id, size, hash) = (e.row.id, e.row.size, e.row.quick_hash);
        let twins = db.read(|c| assets::recent_untouched_twins(c, size, hash, id, since))?;
        if let [twin] = twins.as_slice() {
            // The newcomer has to be the same file in full, when the library knows the old file's full hash.
            let confirmed = twin.abs_path.as_deref().is_none_or(|p| confirms_same_content(db, id, p, size, &mut report));
            if !confirmed {
                continue;
            }
            let twin = twin.clone();
            let thumbs = db.write(move |tx| assets::absorb_twin(tx, id, &twin, now_ms()))?;
            report.merged_twins += 1;
            report.marked_missing = report.marked_missing.saturating_sub(1);
            report.orphaned_thumbs.extend(thumbs);
        }
    }

    report.unreadable_dirs = unreadable_dirs;
    Ok(report)
}

/// Whether `path` may be the moved copy of asset `id`. When the library holds a full hash of that asset, the new file
/// has to match it; a file that shares size and samples but differs elsewhere is a different file. Without a stored
/// hash, or when confirming would read too much, the quick hash alone decides.
fn confirms_same_content(db: &Db, id: AssetId, path: &Path, size: i64, report: &mut ScanReport) -> bool {
    let Ok(Some(stored)) = db.read(|c| assets::content_hash_of(c, id)) else { return true };
    let Ok(len) = u64::try_from(size) else { return true };
    if len > CONFIRM_MAX_FILE || report.relink_checked_bytes + len > CONFIRM_BUDGET {
        return true;
    }
    let Ok(file) = File::open(path) else { return true };
    let Ok(found) = content_hash(&file, len, &|| true) else { return true };
    report.relink_checked_bytes += len;
    if found[..] == stored[..] {
        true
    } else {
        report.relink_rejected += 1;
        false
    }
}

/// Among vanished candidates with identical content, prefers the same file name, then the same modification
/// time, then the oldest record.
fn pick_match(
    mut cands: Vec<(AssetId, String, i64)>,
    name: &str,
    mtime: i64,
    mut accept: impl FnMut(AssetId) -> bool,
) -> Option<AssetId> {
    cands.sort_by_key(|(id, n, m)| (n != name, *m != mtime, id.0));
    cands.into_iter().map(|(id, _, _)| id).find(|id| accept(*id))
}

/// Keeps only the outermost directories (a failure below an already failed directory adds nothing).
fn collapse_dirs(mut dirs: Vec<String>) -> Vec<String> {
    dirs.sort();
    dirs.dedup();
    let mut out: Vec<String> = Vec::new();
    for d in dirs {
        if !out.iter().any(|p| d == *p || util::is_within(&d, p)) {
            out.push(d);
        }
    }
    out
}

/// Hashes a chunk in parallel, then records it: changed files update their record; new files are inserted at once
/// (first scan) or held back until the walk ends (rescan).
#[allow(clippy::too_many_arguments)]
fn flush(
    db: &Db,
    pool: &ScannerPool,
    target: &ScanTarget,
    chunk: &mut Vec<Candidate>,
    streaming: bool,
    missing_elsewhere: bool,
    pending_new: &mut Vec<Hashed>,
    report: &mut ScanReport,
) -> Result<()> {
    if chunk.is_empty() {
        return Ok(());
    }
    let batch = std::mem::take(chunk);
    let hashed: Vec<std::io::Result<Hashed>> = pool.pool.install(|| {
        batch
            .into_par_iter()
            .map(|cand| {
                let file = File::open(&cand.abs)?;
                let hash = quick_hash(&file, u64::try_from(cand.size).unwrap_or(0))?;
                Ok(Hashed { cand, hash })
            })
            .collect()
    });

    let mut changed: Vec<(AssetId, i64, i64, [u8; 16])> = Vec::new();
    let mut fresh: Vec<Hashed> = Vec::new();
    for item in hashed {
        match item {
            Ok(h) => match h.cand.existing {
                Some(id) => changed.push((id, h.cand.size, h.cand.mtime, h.hash)),
                None => fresh.push(h),
            },
            Err(e) => {
                tracing::debug!(error = %e, "file skipped this scan");
                report.skipped_unreadable += 1;
            }
        }
    }

    if !changed.is_empty() {
        report.changed += changed.len() as u64;
        db.write(move |tx| {
            let now = now_ms();
            for (id, size, mtime, hash) in changed {
                assets::update_changed(tx, id, size, mtime, hash, now)?;
            }
            Ok(())
        })?;
    }

    if streaming && !missing_elsewhere {
        insert_now(db, target, fresh, report)?;
    } else if streaming {
        // A first scan can still be the new home of files that went missing from another folder.
        let mut plain = Vec::new();
        let mut relinks = Vec::new();
        for h in fresh {
            let (size, hash) = (h.cand.size, h.hash);
            let cands = db.read(|c| assets::relink_candidates(c, size, hash))?;
            let name = paths::rel_name(&h.cand.rel_path).to_string();
            let list = cands
                .into_iter()
                .map(|r| (r.id, paths::rel_name(&r.rel_path).to_string(), r.mtime))
                .filter(|(id, _, _)| !relinks.iter().any(|(rid, _, _, _): &(AssetId, FolderId, String, i64)| rid == id))
                .collect();
            let accept = |id| confirms_same_content(db, id, &h.cand.abs, h.cand.size, report);
            match pick_match(list, &name, h.cand.mtime, accept) {
                Some(id) => relinks.push((id, target.folder, h.cand.rel_path.clone(), h.cand.mtime)),
                None => plain.push(h),
            }
        }
        report.relinked += relinks.len() as u64;
        if !relinks.is_empty() {
            db.write(move |tx| {
                for (id, folder, rel, mtime) in &relinks {
                    assets::relink(tx, *id, *folder, rel, *mtime)?;
                }
                Ok(())
            })?;
        }
        insert_now(db, target, plain, report)?;
    } else {
        pending_new.extend(fresh);
    }
    Ok(())
}

fn insert_now(db: &Db, target: &ScanTarget, fresh: Vec<Hashed>, report: &mut ScanReport) -> Result<()> {
    if fresh.is_empty() {
        return Ok(());
    }
    let files: Vec<ScannedFile> = fresh
        .into_iter()
        .map(|h| ScannedFile {
            rel_path: h.cand.rel_path,
            kind: h.cand.kind,
            size: h.cand.size,
            mtime: h.cand.mtime,
            quick_hash: h.hash,
        })
        .collect();
    let (folder, lane) = (target.folder, target.lane);
    let inserted = db.write(move |tx| assets::insert_assets(tx, folder, &files, lane, now_ms()))?;
    report.new_files += inserted.len() as u64;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapse_keeps_outermost() {
        let c = collapse_dirs(vec!["a/b".into(), "a".into(), "c/d".into(), "a/b".into(), "ab".into()]);
        assert_eq!(c, vec!["a".to_string(), "ab".to_string(), "c/d".to_string()]);
    }

    #[test]
    fn pick_prefers_name_then_mtime_then_age() {
        let cands = vec![
            (AssetId(5), "x.jpg".to_string(), 10),
            (AssetId(3), "y.jpg".to_string(), 20),
            (AssetId(9), "y.jpg".to_string(), 10),
        ];
        assert_eq!(pick_match(cands.clone(), "y.jpg", 10, |_| true), Some(AssetId(9)));
        assert_eq!(pick_match(cands.clone(), "z.jpg", 10, |_| true), Some(AssetId(5)));
        assert_eq!(pick_match(cands.clone(), "z.jpg", 99, |_| true), Some(AssetId(3)));
        assert_eq!(pick_match(vec![], "a", 0, |_| true), None);
        // A candidate that is not accepted is skipped for the next best one.
        assert_eq!(pick_match(cands, "y.jpg", 10, |id| id != AssetId(9)), Some(AssetId(3)));
    }
}
