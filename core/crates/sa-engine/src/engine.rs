//! The engine: lifecycle, queries, organizing, progress. Folder management is in `folders.rs`, scanning in
//! `scanner.rs`, the worker batch API in `workers.rs`.

use crate::cleanup::PlanRecord;
use crate::config::EngineConfig;
use crate::duplicates::GroupSets;
use crate::hasher::Hasher;
use crate::events::{EventSink, Notice, Progress};
use crate::notifier::Notifier;
use crate::scanner::Scanner;
use parking_lot::Mutex;
use sa_core::time::now_ms;
use sa_core::{
    AssetId, ColorLabel, Error, Flag, FolderId, Result, SearchQuery,
};
use sa_index::ScannerPool;
use sa_jobs::{Conditions, Manager, Settings};
use sa_search::LibraryStats;
use sa_store::model::{AssetDetail, AssetSummary, CollectionRow, SmartCollectionRow, Tag, ThumbKey};
use sa_store::{DataDirs, Db, assets, dedupe, jobs, organize};
use sa_watch::Watcher;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

pub(crate) const MEDIA: &str = assets::MEDIA_JOB;
pub(crate) const HASH: &str = dedupe::HASH_JOB;
pub(crate) const PHASH: &str = dedupe::PHASH_JOB;
pub(crate) const EMBED: &str = sa_store::embeddings::EMBED_JOB;
pub(crate) const TEXT: &str = sa_store::text::TEXT_JOB;
const SETTING_ONLY_ON_POWER: &str = "indexing.only_on_power";

/// What opening the library found out.
#[derive(Debug, Clone)]
pub struct OpenInfo {
    pub schema_before: i64,
    pub schema_after: i64,
    pub unclean_exit: bool,
    /// A health check after an unclean exit failed. The app should tell the user and offer to rebuild.
    pub database_problem: Option<String>,
    pub asset_count: i64,
}

/// Rolling rate of finished media jobs, for the ETA.
#[derive(Default)]
struct Throughput {
    samples: VecDeque<(Instant, i64)>,
}

impl Throughput {
    const WINDOW: Duration = Duration::from_secs(30);

    fn record(&mut self, done: i64) -> Option<f64> {
        let now = Instant::now();
        // A counter that goes backwards means a new run started: forget the old rate.
        if self.samples.back().is_some_and(|&(_, d)| done < d) {
            self.samples.clear();
        }
        self.samples.push_back((now, done));
        while self.samples.front().is_some_and(|&(t, _)| now.duration_since(t) > Self::WINDOW) {
            self.samples.pop_front();
        }
        let (t0, d0) = *self.samples.front()?;
        let secs = now.duration_since(t0).as_secs_f64();
        if secs < 2.0 || done <= d0 {
            return None;
        }
        #[allow(clippy::cast_precision_loss)]
        Some((done - d0) as f64 / secs)
    }
}

pub(crate) struct Inner {
    pub(crate) config: EngineConfig,
    pub(crate) db: Db,
    pub(crate) dirs: DataDirs,
    pub(crate) manager: Manager,
    pub(crate) pool: ScannerPool,
    pub(crate) notifier: Arc<Notifier>,
    pub(crate) scanner: Scanner,
    pub(crate) watcher: OnceLock<Watcher>,
    /// Registered watch root -> folder.
    pub(crate) watch_roots: Mutex<HashMap<PathBuf, FolderId>>,
    pub(crate) discovered: AtomicU64,
    pub(crate) scans_running: AtomicUsize,
    throughput: Mutex<Throughput>,
    /// Thumbnail shard directories already created this session.
    pub(crate) shards: Mutex<HashSet<i64>>,
    pub(crate) generation: AtomicU64,
    /// Runs the full-content hash jobs (plan A1).
    pub(crate) hasher: Hasher,
    /// Set when files were added or changed: the hasher looks for new suspects before its next turn.
    pub(crate) queue_dirty: AtomicBool,
    pub(crate) dup_cache: Mutex<Option<(u64, Arc<GroupSets>)>>,
    /// The model configuration the worker announced (Phase 4). None while no model is ready: no vectors are made.
    pub(crate) embedding: Mutex<Option<sa_store::embeddings::ModelConfig>>,
    /// The exact-scan index over the stored vectors of that configuration, built on first use.
    pub(crate) vectors: Mutex<Option<crate::embedding::VectorCache>>,
    /// What the announced model's similarities mean (measured per model configuration).
    pub(crate) calibration: Mutex<crate::embedding::Calibration>,
    /// Set when files were added or changed, or the configuration changed: look for files without vectors.
    pub(crate) embed_dirty: AtomicBool,
    /// The text reader the worker announced (S4). None while no reader is ready: no text is read.
    pub(crate) text_reader: Mutex<Option<String>>,
    /// Set when files were added or changed, or the reader changed: look for files whose text was not read.
    pub(crate) text_dirty: AtomicBool,
    /// The label words the model embedded (C1). None until a model announces them.
    pub(crate) labels: Mutex<Option<crate::labels::LabelSet>>,
    /// Cleanup plans waiting for the user's decision (plan A3).
    pub(crate) plans: Mutex<HashMap<String, PlanRecord>>,
}

/// Cheap to clone; every clone is the same engine.
#[derive(Clone)]
pub struct Engine {
    pub(crate) inner: Arc<Inner>,
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine").finish_non_exhaustive()
    }
}

impl Engine {
    /// Opens the library. Queries work immediately; call [`Engine::start`] to begin watching and scanning.
    pub fn open(config: EngineConfig, sink: Arc<dyn EventSink>) -> Result<(Self, OpenInfo)> {
        let dirs = DataDirs::new(&config.data_dir);
        dirs.ensure().map_err(|e| Error::io("create data directory", &config.data_dir, &e))?;
        let (db, report) = Db::open(&dirs.database())?;

        let only_on_power = db
            .read(|c| sa_store::settings::get(c, SETTING_ONLY_ON_POWER))?
            .is_some_and(|v| v == "1");
        let manager = Manager::new(
            db.clone(),
            Settings {
                index_only_on_power: only_on_power,
                max_parallelism: config.worker_parallelism,
                ..Settings::default()
            },
        )?;
        db.write(sa_store::folders::reset_scan_states)?;
        let pool = ScannerPool::new(config.scan_threads)?;

        let database_problem = match &report.quick_check {
            Some(Err(problem)) => Some(problem.clone()),
            _ => None,
        };
        let asset_count = db.read(assets::count)?;

        // The notifier needs the engine to compute progress, and the engine needs the notifier: tie the knot
        // with a late-bound handle.
        let progress_source: Arc<OnceLock<std::sync::Weak<Inner>>> = Arc::new(OnceLock::new());
        let ps = Arc::clone(&progress_source);
        let notifier = Notifier::start(sink, move || {
            ps.get()
                .and_then(std::sync::Weak::upgrade)
                .map_or_else(Progress::default, |inner| inner.progress())
        });
        let inner = Arc::new(Inner {
            scanner: Scanner::new(),
            config,
            db,
            dirs,
            manager,
            pool,
            notifier,
            watcher: OnceLock::new(),
            watch_roots: Mutex::new(HashMap::new()),
            discovered: AtomicU64::new(0),
            scans_running: AtomicUsize::new(0),
            throughput: Mutex::new(Throughput::default()),
            shards: Mutex::new(HashSet::new()),
            generation: AtomicU64::new(0),
            hasher: Hasher::new(),
            queue_dirty: AtomicBool::new(true),
            dup_cache: Mutex::new(None),
            embedding: Mutex::new(None),
            vectors: Mutex::new(None),
            calibration: Mutex::new(crate::embedding::Calibration::default()),
            embed_dirty: AtomicBool::new(true),
            text_reader: Mutex::new(None),
            text_dirty: AtomicBool::new(true),
            labels: Mutex::new(None),
            plans: Mutex::new(HashMap::new()),
        });
        let _ = progress_source.set(Arc::downgrade(&inner));

        if let Some(problem) = &database_problem {
            inner.notifier.notice(Notice::DatabaseProblem { message: problem.clone() });
        }
        let info = OpenInfo {
            schema_before: report.schema_before,
            schema_after: report.schema_after,
            unclean_exit: report.unclean_exit,
            database_problem,
            asset_count,
        };
        Ok((Self { inner }, info))
    }

    /// Starts background activity: the scanner, the file watcher, and a catch-up scan of every added folder to
    /// find what changed while the app was closed. Call after the app has re-established folder access and told
    /// the engine which volumes are mounted ([`Engine::sync_volumes`]).
    pub fn start(&self) -> Result<()> {
        Scanner::start(&self.inner);
        Hasher::start(&self.inner);
        if self.inner.config.watch {
            let weak = Arc::downgrade(&self.inner);
            let watcher = Watcher::new(self.inner.config.debounce, move |batch| {
                if let Some(inner) = weak.upgrade() {
                    inner.on_watch_batch(&batch);
                }
            })?;
            let _ = self.inner.watcher.set(watcher);
        }
        for info in self.inner.db.read(sa_store::folders::list_folders)? {
            if info.folder.enabled && info.volume.is_online {
                self.inner.watch_folder(&info);
                self.inner.scanner.request(info.folder.id, vec![String::new()], jobs::lane::BACKLOG);
            }
        }
        if self.inner.manager.counts(MEDIA)?.remaining() > 0 {
            self.inner.notifier.work_started();
        }
        Ok(())
    }

    /// Stops everything and marks the session as cleanly finished.
    pub fn shutdown(&self) -> Result<()> {
        let inner = &self.inner;
        inner.scanner.stop();
        inner.hasher.stop();
        if let Some(w) = inner.watcher.get() {
            for root in w.watched() {
                w.unwatch(&root);
            }
        }
        let _ = inner.manager.revoke_all(MEDIA);
        let _ = inner.manager.revoke_all(HASH);
        let _ = inner.manager.revoke_all(PHASH);
        let _ = inner.manager.revoke_all(EMBED);
        let _ = inner.manager.revoke_all(TEXT);
        inner.notifier.stop();
        inner.db.close()
    }

    // ---- queries ----

    /// Runs a search and returns every matching asset id in display order.
    pub fn search(&self, query: &SearchQuery) -> Result<Arc<Vec<i64>>> {
        let ids = self.inner.db.read(|c| sa_search::run(c, query))?;
        Ok(Arc::new(ids))
    }

    pub fn summaries(&self, ids: &[i64]) -> Result<Vec<AssetSummary>> {
        self.inner.db.read(|c| assets::summaries(c, ids))
    }

    pub fn asset_detail(&self, id: AssetId) -> Result<AssetDetail> {
        self.inner.db.read(|c| assets::detail(c, id))
    }

    /// Absolute paths of assets whose drive is online, in the order asked.
    pub fn paths(&self, ids: &[i64]) -> Result<Vec<(AssetId, Option<PathBuf>)>> {
        self.inner.db.read(|c| assets::resolve_paths(c, ids))
    }

    pub fn stats(&self) -> Result<LibraryStats> {
        self.inner.db.read(sa_search::stats)
    }

    #[must_use]
    pub fn thumb_path(&self, asset_id: i64, rev: i64) -> PathBuf {
        self.inner.dirs.thumb_path(asset_id, rev)
    }

    #[must_use]
    pub fn data_dirs(&self) -> &DataDirs {
        &self.inner.dirs
    }

    // ---- organizing (plan O1–O3) ----

    fn changed(&self) {
        self.inner.generation.fetch_add(1, Ordering::Relaxed);
        self.inner.notifier.library_changed(false);
    }

    pub fn set_rating(&self, ids: &[AssetId], rating: u8) -> Result<()> {
        let ids = ids.to_vec();
        self.inner.db.write(move |tx| organize::set_rating(tx, &ids, rating).map(|_| ()))?;
        self.changed();
        Ok(())
    }

    pub fn set_flag(&self, ids: &[AssetId], flag: Flag) -> Result<()> {
        let ids = ids.to_vec();
        self.inner.db.write(move |tx| organize::set_flag(tx, &ids, flag).map(|_| ()))?;
        self.changed();
        Ok(())
    }

    pub fn set_color_label(&self, ids: &[AssetId], label: ColorLabel) -> Result<()> {
        let ids = ids.to_vec();
        self.inner.db.write(move |tx| organize::set_color_label(tx, &ids, label).map(|_| ()))?;
        self.changed();
        Ok(())
    }

    pub fn set_notes(&self, id: AssetId, notes: &str) -> Result<()> {
        let notes = notes.to_string();
        self.inner.db.write(move |tx| organize::set_notes(tx, id, &notes))?;
        self.changed();
        Ok(())
    }

    pub fn add_tags(&self, ids: &[AssetId], names: &[String]) -> Result<()> {
        let (ids, names) = (ids.to_vec(), names.to_vec());
        self.inner.db.write(move |tx| organize::add_tags(tx, &ids, &names))?;
        self.changed();
        Ok(())
    }

    pub fn remove_tags(&self, ids: &[AssetId], names: &[String]) -> Result<()> {
        let (ids, names) = (ids.to_vec(), names.to_vec());
        self.inner.db.write(move |tx| organize::remove_tags(tx, &ids, &names))?;
        self.changed();
        Ok(())
    }

    pub fn rename_tag(&self, from: &str, to: &str) -> Result<()> {
        let (from, to) = (from.to_string(), to.to_string());
        self.inner.db.write(move |tx| organize::rename_tag(tx, &from, &to))?;
        self.changed();
        Ok(())
    }

    pub fn delete_tag(&self, name: &str) -> Result<()> {
        let name = name.to_string();
        self.inner.db.write(move |tx| organize::delete_tag(tx, &name))?;
        self.changed();
        Ok(())
    }

    pub fn tags(&self) -> Result<Vec<Tag>> {
        self.inner.db.read(organize::list_tags)
    }

    pub fn create_collection(&self, name: &str) -> Result<i64> {
        let name = name.to_string();
        let id = self.inner.db.write(move |tx| organize::create_collection(tx, &name, now_ms()))?;
        self.inner.notifier.folders_changed();
        Ok(id)
    }

    pub fn rename_collection(&self, id: i64, name: &str) -> Result<()> {
        let name = name.to_string();
        self.inner.db.write(move |tx| organize::rename_collection(tx, id, &name))?;
        self.inner.notifier.folders_changed();
        Ok(())
    }

    pub fn delete_collection(&self, id: i64) -> Result<()> {
        self.inner.db.write(move |tx| organize::delete_collection(tx, id))?;
        self.inner.notifier.folders_changed();
        Ok(())
    }

    pub fn add_to_collection(&self, id: i64, ids: &[AssetId]) -> Result<usize> {
        let ids = ids.to_vec();
        let n = self.inner.db.write(move |tx| organize::add_to_collection(tx, id, &ids, now_ms()))?;
        self.inner.notifier.folders_changed();
        self.changed();
        Ok(n)
    }

    pub fn remove_from_collection(&self, id: i64, ids: &[AssetId]) -> Result<usize> {
        let ids = ids.to_vec();
        let n = self.inner.db.write(move |tx| organize::remove_from_collection(tx, id, &ids))?;
        self.inner.notifier.folders_changed();
        self.changed();
        Ok(n)
    }

    pub fn collections(&self) -> Result<Vec<CollectionRow>> {
        self.inner.db.read(organize::list_collections)
    }

    pub fn collections_of(&self, asset: AssetId) -> Result<Vec<i64>> {
        self.inner.db.read(|c| organize::collections_of(c, asset))
    }

    pub fn create_smart_collection(&self, name: &str, query: &SearchQuery) -> Result<i64> {
        let (name, query) = (name.to_string(), query.clone());
        let id = self
            .inner
            .db
            .write(move |tx| organize::create_smart_collection(tx, &name, &query, now_ms()))?;
        self.inner.notifier.folders_changed();
        Ok(id)
    }

    pub fn update_smart_collection(&self, id: i64, name: &str, query: &SearchQuery) -> Result<()> {
        let (name, query) = (name.to_string(), query.clone());
        self.inner.db.write(move |tx| organize::update_smart_collection(tx, id, &name, &query))?;
        self.inner.notifier.folders_changed();
        Ok(())
    }

    pub fn delete_smart_collection(&self, id: i64) -> Result<()> {
        self.inner.db.write(move |tx| organize::delete_smart_collection(tx, id))?;
        self.inner.notifier.folders_changed();
        Ok(())
    }

    pub fn smart_collections(&self) -> Result<Vec<SmartCollectionRow>> {
        self.inner.db.read(organize::list_smart_collections)
    }

    // ---- indexing control (plan L5) ----

    /// Pauses background indexing. Work in flight finishes; nothing new starts until resumed.
    pub fn pause_indexing(&self) {
        self.inner.manager.set_paused(true);
        self.inner.notifier.work_started();
    }

    pub fn resume_indexing(&self) {
        self.inner.manager.set_paused(false);
        self.inner.scanner.wake();
        self.inner.hasher.wake();
        self.inner.notifier.work_started();
    }

    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.inner.manager.is_paused()
    }

    /// Stops all pending indexing work, for one folder or all. Files already indexed stay. Resume with
    /// [`Engine::reindex_unfinished`].
    pub fn cancel_indexing(&self, folder: Option<FolderId>) -> Result<()> {
        self.inner.scanner.cancel(folder);
        self.inner.manager.cancel(MEDIA, folder)?;
        self.inner.manager.cancel(HASH, folder)?;
        self.inner.manager.cancel(PHASH, folder)?;
        self.inner.manager.cancel(EMBED, folder)?;
        self.inner.manager.cancel(TEXT, folder)?;
        self.inner.notifier.work_started();
        self.inner.notifier.folders_changed();
        Ok(())
    }

    /// Queues everything that still lacks metadata or a thumbnail, for example after a cancel. Returns how many
    /// assets were queued.
    pub fn reindex_unfinished(&self) -> Result<usize> {
        let mut total = 0;
        loop {
            let ids = self.inner.db.read(|c| assets::unprobed_without_job(c, 5_000))?;
            if ids.is_empty() {
                break;
            }
            total += ids.len();
            self.inner.db.write(move |tx| {
                let now = now_ms();
                for id in ids {
                    jobs::enqueue(tx, MEDIA, id, "", jobs::lane::BACKLOG, true, now)?;
                }
                Ok(())
            })?;
        }
        if total > 0 {
            self.inner.notifier.work_started();
        }
        Ok(total)
    }

    /// Rescans one folder, or all, to pick up changes the watcher cannot see (a network share, a restored backup).
    pub fn rescan(&self, folder: Option<FolderId>) -> Result<()> {
        for info in self.inner.db.read(sa_store::folders::list_folders)? {
            if folder.is_none_or(|f| f == info.folder.id) && info.folder.enabled && info.volume.is_online {
                self.inner.scanner.request(info.folder.id, vec![String::new()], jobs::lane::BACKLOG);
            }
        }
        Ok(())
    }

    pub fn set_conditions(&self, c: Conditions) {
        self.inner.manager.set_conditions(c);
        self.inner.scanner.wake();
        self.inner.hasher.wake();
    }

    pub fn set_index_only_on_power(&self, on: bool) -> Result<()> {
        let mut s = self.inner.manager.settings();
        s.index_only_on_power = on;
        self.inner.manager.set_settings(s);
        self.inner.db.write(move |tx| {
            sa_store::settings::set(tx, SETTING_ONLY_ON_POWER, if on { "1" } else { "0" })
        })?;
        self.inner.scanner.wake();
        Ok(())
    }

    #[must_use]
    pub fn index_only_on_power(&self) -> bool {
        self.inner.manager.settings().index_only_on_power
    }

    /// Assets on screen jump the queue (plan §6.6 lane 1).
    pub fn prioritize(&self, ids: &[AssetId]) -> Result<()> {
        self.inner.manager.prioritize(MEDIA, ids.to_vec())?;
        Ok(())
    }

    #[must_use]
    pub fn progress(&self) -> Progress {
        self.inner.progress()
    }

}

impl Drop for Inner {
    fn drop(&mut self) {
        // The last engine handle is gone: stop the threads (they only hold weak references to this state).
        self.scanner.stop();
        self.hasher.stop();
        self.notifier.stop();
    }
}

impl Inner {
    pub(crate) fn progress(&self) -> Progress {
        let c = self.manager.counts(MEDIA).unwrap_or_default();
        let dedupe_remaining = self.manager.counts(HASH).unwrap_or_default().remaining()
            + self.manager.counts(PHASH).unwrap_or_default().remaining();
        let remaining = c.remaining();
        let done = c.done + c.failed;
        let rate = self.throughput.lock().record(done);
        #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let eta_seconds = rate.filter(|r| *r > 0.0 && remaining > 0).map(|r| (remaining as f64 / r).ceil() as u64);
        Progress {
            scanning: self.scans_running.load(Ordering::Relaxed) > 0 || self.scanner.has_pending(),
            files_discovered: self.discovered.load(Ordering::Relaxed),
            media_total: c.total() - c.cancelled,
            media_done: c.done,
            media_failed: c.failed,
            media_remaining: remaining,
            dedupe_remaining,
            embed_remaining: self.manager.counts(EMBED).unwrap_or_default().remaining(),
            hold: self.manager.hold_reason(),
            eta_seconds,
        }
    }

    pub(crate) fn remove_thumb_files(&self, keys: &[ThumbKey]) {
        for k in keys {
            let _ = std::fs::remove_file(self.dirs.thumb_path(k.asset_id, k.rev));
            let _ = std::fs::remove_file(self.dirs.filmstrip_path(k.asset_id, k.rev));
        }
    }
}
