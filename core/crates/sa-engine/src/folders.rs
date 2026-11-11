//! Folders and volumes: what the user added, and the drives they live on (plan L1, L1a, L1b, L4, L5, H2).
//!
//! macOS integration stays in Swift (plan D1): Swift runs the folder picker, keeps the security-scoped bookmark,
//! and tells the engine which volumes are mounted. The engine only ever indexes folders it was given here.

use crate::engine::{Engine, Inner};
use sa_core::time::now_ms;
use sa_core::{Error, FolderId, Result, VolumeId};
use sa_store::folders::{self, AddFolderOutcome};
use sa_store::jobs;
use sa_store::model::{FolderInfo, VolumeRow};
use sa_watch::WatchBatch;
use std::path::{Path, PathBuf};

/// A volume as macOS reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MountedVolume {
    /// The volume UUID. Identifies a drive across mount points and re-plugs.
    pub uuid: String,
    pub name: String,
    pub mount_path: PathBuf,
    pub is_internal: bool,
}

#[derive(Debug, Clone)]
pub struct AddFolderRequest {
    /// Absolute path the user picked.
    pub path: PathBuf,
    /// Security-scoped bookmark data, kept so access survives relaunch (plan L1b).
    pub bookmark: Option<Vec<u8>>,
    pub volume: MountedVolume,
}

fn split_on_volume(path: &Path, mount: &Path) -> Result<String> {
    let rel = path
        .strip_prefix(mount)
        .map_err(|_| Error::Invalid(format!("{} is not on the volume mounted at {}", path.display(), mount.display())))?;
    rel.to_str()
        .map(str::to_string)
        .ok_or_else(|| Error::Invalid("folder path is not valid UTF-8".into()))
}

impl Engine {
    /// Adds a folder the user picked and starts indexing it in place. Nothing is copied.
    #[allow(clippy::needless_pass_by_value)] // a request is consumed conceptually; callers build it per call
    pub fn add_folder(&self, req: AddFolderRequest) -> Result<AddFolderOutcome> {
        let path = req.path.canonicalize().map_err(|e| Error::io("open folder", &req.path, &e))?;
        if !path.is_dir() {
            return Err(Error::Invalid(format!("{} is not a folder", path.display())));
        }
        let mount = req.volume.mount_path.canonicalize().unwrap_or_else(|_| req.volume.mount_path.clone());
        let rel = split_on_volume(&path, &mount)?;
        let display_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .map_or_else(|| req.volume.name.clone(), str::to_string);

        let inner = &self.inner;
        let vol = req.volume.clone();
        let mount_str = mount.to_string_lossy().into_owned();
        let bookmark = req.bookmark.clone();
        let outcome = inner.scanner.quiesced(inner, || {
            inner.db.write(move |tx| {
                let now = now_ms();
                let vid = folders::upsert_volume(tx, &vol.uuid, &vol.name, &mount_str, vol.is_internal, now)?;
                folders::add_folder(tx, vid, &rel, &display_name, bookmark.as_deref(), now)
            })
        })?;

        if let AddFolderOutcome::Added { id, absorbed } = &outcome {
            for child in absorbed {
                inner.unwatch_folder(*child);
            }
            if let Some(info) = inner.db.read(sa_store::folders::list_folders)?.into_iter().find(|i| i.folder.id == *id) {
                inner.watch_folder(&info);
            }
            inner.scanner.request(*id, vec![String::new()], jobs::lane::NEW);
            inner.notifier.work_started();
            inner.notifier.folders_changed();
            inner.notifier.library_changed(true);
        }
        Ok(outcome)
    }

    /// Removes a folder from the index. The files on disk are never touched (plan L1a).
    pub fn remove_folder(&self, id: FolderId) -> Result<()> {
        let inner = &self.inner;
        inner.unwatch_folder(id);
        inner.scanner.cancel(Some(id));
        let removed = inner.scanner.quiesced(inner, || inner.db.write(move |tx| folders::remove_folder(tx, id)))?;
        inner.remove_thumb_files(&removed.thumbs);
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(())
    }

    /// Turns a folder on or off without losing anything attached to its files (plan L5).
    pub fn set_folder_enabled(&self, id: FolderId, enabled: bool) -> Result<()> {
        let inner = &self.inner;
        inner.scanner.quiesced(inner, || inner.db.write(move |tx| folders::set_folder_enabled(tx, id, enabled)))?;
        if let Some(info) = inner.db.read(folders::list_folders)?.into_iter().find(|i| i.folder.id == id) {
            if enabled && info.volume.is_online {
                inner.watch_folder(&info);
                inner.scanner.request(id, vec![String::new()], jobs::lane::NEW);
                inner.notifier.work_started();
            } else {
                inner.unwatch_folder(id);
            }
        }
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(())
    }

    /// Sets the subfolders to skip. Anything already indexed below them leaves the index.
    pub fn set_excludes(&self, id: FolderId, excludes: &[String]) -> Result<()> {
        let inner = &self.inner;
        let excludes = excludes.to_vec();
        let removed = inner.scanner.quiesced(inner, || inner.db.write(move |tx| folders::set_excludes(tx, id, &excludes)))?;
        inner.remove_thumb_files(&removed.thumbs);
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(())
    }

    /// The folder was moved to a new place (plan H2): keep everything attached to its files and rescan there.
    pub fn relocate_folder(&self, id: FolderId, new_path: &Path, bookmark: Option<Vec<u8>>, volume: MountedVolume) -> Result<()> {
        let path = new_path.canonicalize().map_err(|e| Error::io("open folder", new_path, &e))?;
        let mount = volume.mount_path.canonicalize().unwrap_or_else(|_| volume.mount_path.clone());
        let rel = split_on_volume(&path, &mount)?;
        let name = path.file_name().and_then(|n| n.to_str()).map_or_else(|| volume.name.clone(), str::to_string);
        let inner = &self.inner;
        inner.unwatch_folder(id);
        let mount_str = mount.to_string_lossy().into_owned();
        inner.scanner.quiesced(inner, || {
            inner.db.write(move |tx| {
                let now = now_ms();
                let vid: VolumeId = folders::upsert_volume(tx, &volume.uuid, &volume.name, &mount_str, volume.is_internal, now)?;
                folders::relocate_folder(tx, id, vid, &rel, &name)?;
                if let Some(b) = &bookmark {
                    folders::set_folder_bookmark(tx, id, b)?;
                }
                Ok(())
            })
        })?;
        if let Some(info) = inner.db.read(folders::list_folders)?.into_iter().find(|i| i.folder.id == id) {
            inner.watch_folder(&info);
        }
        inner.scanner.request(id, vec![String::new()], jobs::lane::NEW);
        inner.notifier.work_started();
        inner.notifier.folders_changed();
        Ok(())
    }

    /// "Remove from Library" for files that are really gone (plan H2). Only assets already marked missing can be removed;
    /// the files on disk are never touched. `None` removes every missing asset. Returns how many left the index.
    pub fn remove_missing(&self, ids: Option<&[sa_core::AssetId]>) -> Result<usize> {
        let inner = &self.inner;
        let ids = ids.map(<[sa_core::AssetId]>::to_vec);
        let (n, thumbs) = inner.scanner.quiesced(inner, || {
            inner.db.write(move |tx| sa_store::assets::delete_missing(tx, ids.as_deref()))
        })?;
        inner.remove_thumb_files(&thumbs);
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(n)
    }

    /// Replaces the stored security-scoped bookmark (macOS reported it stale and made a fresh one).
    pub fn update_bookmark(&self, id: FolderId, bookmark: &[u8]) -> Result<()> {
        let b = bookmark.to_vec();
        self.inner.db.write(move |tx| folders::set_folder_bookmark(tx, id, &b))
    }

    pub fn list_folders(&self) -> Result<Vec<FolderInfo>> {
        self.inner.db.read(folders::list_folders)
    }

    pub fn list_volumes(&self) -> Result<Vec<VolumeRow>> {
        self.inner.db.read(folders::list_volumes)
    }

    /// Tells the engine exactly which volumes are mounted now (call at launch). Volumes it knows about that are
    /// not in the list go offline; their files stay searchable and name the drive to plug in (plan L4).
    pub fn sync_volumes(&self, mounted: &[MountedVolume]) -> Result<()> {
        let known = self.inner.db.read(folders::list_volumes)?;
        let mounted_uuids: std::collections::HashSet<&str> = mounted.iter().map(|m| m.uuid.as_str()).collect();
        for v in known.iter().filter(|v| v.is_online && !mounted_uuids.contains(v.uuid.as_str())) {
            self.volume_unmounted(&v.uuid)?;
        }
        for m in mounted {
            // Only volumes that hold an added folder matter; others are recorded when a folder is added.
            if known.iter().any(|k| k.uuid == m.uuid) {
                self.volume_mounted(m)?;
            }
        }
        Ok(())
    }

    /// A drive was plugged in. Its folders are watched again and rescanned for changes made while it was away.
    pub fn volume_mounted(&self, m: &MountedVolume) -> Result<()> {
        let inner = &self.inner;
        let (uuid, mount) = (m.uuid.clone(), m.mount_path.to_string_lossy().into_owned());
        let id = inner.db.write(move |tx| folders::set_volume_online(tx, &uuid, Some(&mount), now_ms()))?;
        let Some(vid) = id else { return Ok(()) };
        for info in inner.db.read(folders::list_folders)? {
            if info.volume.id == vid && info.folder.enabled {
                inner.watch_folder(&info);
                inner.scanner.request(info.folder.id, vec![String::new()], jobs::lane::NEW);
            }
        }
        inner.notifier.work_started();
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(())
    }

    /// A drive was removed. Nothing is marked missing: its files simply wait for it to come back.
    pub fn volume_unmounted(&self, uuid: &str) -> Result<()> {
        let inner = &self.inner;
        let u = uuid.to_string();
        let id = inner.db.write(move |tx| folders::set_volume_online(tx, &u, None, now_ms()))?;
        let Some(vid) = id else { return Ok(()) };
        for info in inner.db.read(folders::list_folders)? {
            if info.volume.id == vid {
                inner.unwatch_folder(info.folder.id);
                inner.scanner.cancel(Some(info.folder.id));
            }
        }
        inner.notifier.folders_changed();
        inner.notifier.library_changed(true);
        Ok(())
    }
}

impl Inner {
    pub(crate) fn watch_folder(&self, info: &FolderInfo) {
        let Some(watcher) = self.watcher.get() else { return };
        let Some(root) = info.folder.root(&info.volume) else { return };
        match watcher.watch(&root) {
            Ok(()) => {
                self.watch_roots.lock().insert(root, info.folder.id);
            }
            Err(e) => tracing::warn!(folder = info.folder.id.0, error = %e, "cannot watch folder; it will be rescanned on demand"),
        }
    }

    pub(crate) fn unwatch_folder(&self, id: FolderId) {
        let roots: Vec<PathBuf> = {
            let mut map = self.watch_roots.lock();
            let keys: Vec<PathBuf> = map.iter().filter(|(_, f)| **f == id).map(|(p, _)| p.clone()).collect();
            for k in &keys {
                map.remove(k);
            }
            keys
        };
        if let Some(w) = self.watcher.get() {
            for r in roots {
                w.unwatch(&r);
            }
        }
    }

    /// Live updates (plan L2). A batch for a folder that was just removed is ignored.
    pub(crate) fn on_watch_batch(&self, batch: &WatchBatch) {
        let Some(folder) = self.watch_roots.lock().get(&batch.root).copied() else { return };
        self.scanner.request(folder, batch.dirs.clone(), jobs::lane::NEW);
        self.notifier.work_started();
    }
}
