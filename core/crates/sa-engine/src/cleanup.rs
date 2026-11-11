//! Duplicate cleanup (plan A3): the only place in SmartAsset where a user's file may be moved.
//!
//! The rules of plan §3.2 are enforced here, in Rust, not left to the interface:
//!
//! 1. **Review first.** [`Engine::plan_cleanup`] builds a plan for one group and shows every file with its size,
//!    modification date, location and match. Nothing moves.
//! 2. **Only what was confirmed.** [`Engine::approve_cleanup`] accepts a subset of the plan the user confirmed and
//!    refuses any id that is not in it, an unknown or used-up token, an expired plan, or an attempt to remove every
//!    copy. It checks each file again against the disk right then.
//! 3. **Trash, never delete.** Rust never removes a file. It returns the approved paths; the Swift side moves them
//!    to the Trash with the system API and reports back with [`Engine::cleanup_done`], and only then do the records
//!    leave the library.
//! 4. **Nothing is lost on the way.** Ratings, tags, notes and collections of a removed copy move to the copy kept.
//!
//! A file that changed since it was reviewed (different size, time or content samples), a symbolic link, or a file
//! on a drive that is not connected is refused, and refusing one file refuses the whole action.

use crate::duplicates::DuplicateKind;
use crate::engine::{Engine, Inner};
use sa_core::time::{now_ms, system_time_to_ms};
use sa_core::{AssetId, Error, Result};
use sa_index::quick_hash;
use sa_store::{assets, dedupe};
use std::collections::{BTreeSet, HashMap};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// A plan the user did not act on is forgotten after this long.
const PLAN_LIFETIME: Duration = Duration::from_mins(15);
const MAX_PLANS: usize = 16;

static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

/// One file in a cleanup review.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupFile {
    pub asset_id: i64,
    pub name: String,
    /// Full path on disk.
    pub path: String,
    /// Name of the drive holding it.
    pub volume_name: String,
    pub size: i64,
    /// Modification date, milliseconds since 1970.
    pub modified_ms: i64,
    /// How sure the match is: 100 for byte-identical, otherwise the similarity of the picture.
    pub match_percent: u8,
}

/// What the user reviews before anything moves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupPlan {
    pub token: String,
    pub kind: DuplicateKind,
    /// Files that would go to the Trash.
    pub remove: Vec<CleanupFile>,
    /// Files that stay.
    pub keep: Vec<CleanupFile>,
    /// Space the removed files take.
    pub bytes: i64,
}

/// A file Rust agrees may be moved to the Trash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovedTrash {
    pub asset_id: i64,
    pub path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CleanupSummary {
    pub removed: usize,
    pub bytes: i64,
}

#[derive(Debug)]
struct Snapshot {
    path: PathBuf,
    size: i64,
    mtime: i64,
    quick_hash: [u8; 16],
}

#[derive(Debug)]
pub(crate) struct PlanRecord {
    created: Instant,
    remove: BTreeSet<i64>,
    keeper: i64,
    keep: Vec<i64>,
    snapshots: HashMap<i64, Snapshot>,
    /// Set once the user confirmed; holds exactly what may be moved.
    approved: Option<BTreeSet<i64>>,
}

fn refuse<T>(why: impl Into<String>) -> Result<T> {
    Err(Error::Refused(why.into()))
}

/// Checks that the file at `path` is still the file the library describes. Never follows a symbolic link.
fn verify(path: &Path, snap: &Snapshot) -> Result<()> {
    let name = path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let meta = std::fs::symlink_metadata(path)
        .map_err(|_| Error::Refused(format!("{name} is no longer where SmartAsset last saw it. Rescan the folder and review again.")))?;
    if !meta.file_type().is_file() {
        return refuse(format!("{name} is not an ordinary file any more."));
    }
    let changed = i64::try_from(meta.len()).ok() != Some(snap.size)
        || meta.modified().map_or(0, system_time_to_ms) != snap.mtime;
    if changed {
        return refuse(format!("{name} changed after it was scanned. Rescan the folder and review again."));
    }
    let file = File::open(path).map_err(|e| Error::Refused(format!("{name} cannot be read: {e}")))?;
    match quick_hash(&file, meta.len()) {
        Ok(h) if h == snap.quick_hash => Ok(()),
        _ => refuse(format!("{name} changed after it was scanned. Rescan the folder and review again.")),
    }
}

impl Inner {
    fn forget_old_plans(&self) {
        let mut plans = self.plans.lock();
        plans.retain(|_, p| p.created.elapsed() < PLAN_LIFETIME);
        while plans.len() >= MAX_PLANS {
            let oldest = plans.iter().min_by_key(|(_, p)| p.created).map(|(k, _)| k.clone());
            match oldest {
                Some(k) => plans.remove(&k),
                None => break,
            };
        }
    }

    fn snapshot(&self, id: i64) -> Result<(Snapshot, sa_store::model::AssetDetail)> {
        let detail = self.db.read(|c| assets::detail(c, AssetId(id)))?;
        let ident = self
            .db
            .read(|c| dedupe::file_identity(c, AssetId(id)))?
            .ok_or_else(|| Error::NotFound(format!("asset {id}")))?;
        if !ident.present {
            return refuse(format!("{} is marked missing.", detail.summary.name));
        }
        let Some(path) = detail.path.clone() else {
            return refuse(format!(
                "{} is on {}, which is not connected. Connect it and try again.",
                detail.summary.name, detail.summary.volume_name
            ));
        };
        Ok((Snapshot { path, size: ident.size, mtime: ident.mtime, quick_hash: ident.quick_hash }, detail))
    }
}

fn file_of(detail: &sa_store::model::AssetDetail, snap: &Snapshot, percent: u8) -> CleanupFile {
    CleanupFile {
        asset_id: detail.summary.id.0,
        name: detail.summary.name.clone(),
        path: snap.path.to_string_lossy().into_owned(),
        volume_name: detail.summary.volume_name.clone(),
        size: snap.size,
        modified_ms: snap.mtime,
        match_percent: percent,
    }
}

impl Engine {
    /// Step 1: prepare a review. `remove` are the copies the user picked from the group with this `group_key`; every
    /// other member stays. Nothing is moved, and the plan is only good for fifteen minutes.
    pub fn plan_cleanup(&self, group_key: &str, remove: &[AssetId]) -> Result<CleanupPlan> {
        let inner = &self.inner;
        let dups = self.duplicates()?;
        let group = dups
            .sets
            .exact
            .iter()
            .chain(dups.sets.similar.iter())
            .find(|g| g.key == group_key)
            .ok_or_else(|| Error::NotFound("This group has changed. Open Duplicates again.".into()))?;
        let wanted: BTreeSet<i64> = remove.iter().map(|a| a.0).collect();
        if wanted.is_empty() {
            return Err(Error::Invalid("Choose at least one copy to remove.".into()));
        }
        let members: BTreeSet<i64> = group.members.iter().map(|m| m.asset_id).collect();
        if !wanted.is_subset(&members) {
            return refuse("A chosen file is not part of this group.");
        }
        if wanted.len() >= members.len() {
            return refuse("Keep at least one copy. Removing every copy would lose the file.");
        }
        let percent_of: HashMap<i64, u8> = group.members.iter().map(|m| (m.asset_id, m.similarity)).collect();

        // Every file that goes is verified, and so is the copy that stays.
        let mut snapshots = HashMap::new();
        let mut remove_files = Vec::new();
        for m in group.members.iter().filter(|m| wanted.contains(&m.asset_id)) {
            let (snap, detail) = inner.snapshot(m.asset_id)?;
            verify(&snap.path, &snap)?;
            remove_files.push(file_of(&detail, &snap, percent_of[&m.asset_id]));
            snapshots.insert(m.asset_id, snap);
        }
        let mut keep_files = Vec::new();
        let mut keep_ids = Vec::new();
        for m in group.members.iter().filter(|m| !wanted.contains(&m.asset_id)) {
            // A copy that cannot be verified does not count as kept; it is simply not listed as one.
            let Ok((snap, detail)) = inner.snapshot(m.asset_id) else { continue };
            if verify(&snap.path, &snap).is_err() {
                continue;
            }
            keep_files.push(file_of(&detail, &snap, percent_of[&m.asset_id]));
            keep_ids.push(m.asset_id);
            snapshots.insert(m.asset_id, snap);
        }
        let Some(&keeper) = keep_ids.first() else {
            return refuse("No copy that would stay can be checked right now (is its drive connected?), so nothing was removed.");
        };

        inner.forget_old_plans();
        let token = format!(
            "plan-{}-{}",
            NEXT_TOKEN.fetch_add(1, Ordering::Relaxed),
            blake3::hash(format!("{}{}", now_ms(), std::process::id()).as_bytes()).to_hex().get(..12).unwrap_or("")
        );
        let bytes = remove_files.iter().map(|f| f.size).sum();
        inner.plans.lock().insert(
            token.clone(),
            PlanRecord {
                created: Instant::now(),
                remove: wanted,
                keeper,
                keep: keep_ids,
                snapshots,
                approved: None,
            },
        );
        Ok(CleanupPlan { token, kind: group.kind, remove: remove_files, keep: keep_files, bytes })
    }

    /// Step 2: the user pressed **Move to Trash**. `confirmed` is what they confirmed; it must be inside the plan.
    /// Every file is checked against the disk again. Returns the paths the caller may move to the Trash, and nothing
    /// else.
    pub fn approve_cleanup(&self, token: &str, confirmed: &[AssetId]) -> Result<Vec<ApprovedTrash>> {
        let inner = &self.inner;
        let mut plans = inner.plans.lock();
        let Some(plan) = plans.get_mut(token) else {
            return refuse("This review is no longer open. Review the files again.");
        };
        if plan.created.elapsed() >= PLAN_LIFETIME {
            plans.remove(token);
            return refuse("This review is too old. Review the files again.");
        }
        if plan.approved.is_some() {
            return refuse("This review was already used.");
        }
        let ids: BTreeSet<i64> = confirmed.iter().map(|a| a.0).collect();
        if ids.is_empty() {
            return Err(Error::Invalid("Nothing was confirmed.".into()));
        }
        if !ids.is_subset(&plan.remove) {
            return refuse("A file that was not in the review cannot be moved to the Trash.");
        }
        // The copy that stays must still be there and unchanged; otherwise this could be the last copy.
        let some_copy_stays = plan.keep.iter().filter_map(|k| plan.snapshots.get(k)).any(|s| verify(&s.path, s).is_ok());
        if !some_copy_stays {
            return refuse("The copy that was going to stay can no longer be found, so nothing was moved.");
        }
        let mut approved = Vec::with_capacity(ids.len());
        for id in &ids {
            let Some(snap) = plan.snapshots.get(id) else {
                return refuse("A file in the review has no record. Review the files again.");
            };
            verify(&snap.path, snap)?;
            approved.push(ApprovedTrash { asset_id: *id, path: snap.path.clone() });
        }
        plan.approved = Some(ids);
        Ok(approved)
    }

    /// The user closed the review without confirming.
    pub fn cancel_cleanup(&self, token: &str) {
        self.inner.plans.lock().remove(token);
    }

    /// Step 3: the files were moved to the Trash (the ids that actually moved). Their records leave the library, and
    /// what the user attached to them moves to the copy that stays. Ids that were not approved are ignored.
    pub fn cleanup_done(&self, token: &str, trashed: &[AssetId]) -> Result<CleanupSummary> {
        let inner = &self.inner;
        let plan = inner.plans.lock().remove(token);
        let Some(plan) = plan else { return refuse("This review is no longer open.") };
        let Some(approved) = plan.approved else { return refuse("This review was never confirmed.") };
        let moved: Vec<AssetId> = trashed.iter().copied().filter(|a| approved.contains(&a.0)).collect();
        let bytes = moved.iter().filter_map(|a| plan.snapshots.get(&a.0)).map(|s| s.size).sum();
        let keeper = AssetId(plan.keeper);
        let doomed = moved.clone();
        let thumbs = inner.scanner.quiesced(inner, || {
            inner.db.write(move |tx| {
                dedupe::merge_user_data(tx, keeper, &doomed)?;
                assets::delete_assets(tx, &doomed)
            })
        })?;
        inner.remove_thumb_files(&thumbs);
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        inner.touch_duplicates();
        Ok(CleanupSummary { removed: moved.len(), bytes })
    }
}
