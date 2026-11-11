//! The scan coordinator: one scan at a time, merging requests, holding while indexing is paused.

use crate::engine::Inner;
use crate::events::Notice;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::{Mutex, MutexGuard};
use sa_core::FolderId;
use sa_index::{ScanOutcome, ScanTarget};
use sa_store::model::ScanState;
use sa_store::{folders, jobs};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

enum Msg {
    Request { folder: FolderId, dirs: Vec<String>, lane: u8 },
    /// Drop queued requests for one folder, or all.
    Purge(Option<FolderId>),
    /// Re-check whether work may run (a pause was lifted).
    Wake,
    Stop,
}

struct Wanted {
    dirs: BTreeSet<String>,
    lane: u8,
}

pub(crate) struct Scanner {
    tx: Sender<Msg>,
    rx: Mutex<Option<Receiver<Msg>>>,
    /// Cancel flags of scans that are running right now.
    running: Mutex<HashMap<FolderId, Arc<AtomicBool>>>,
    /// Held while a scan runs; folder changes take it so they never race a scan.
    gate: Mutex<()>,
    /// Requests sent but not yet taken by the thread.
    in_flight: AtomicUsize,
    /// Requests the thread holds while it works through them.
    queued: AtomicUsize,
}

impl Scanner {
    pub(crate) fn new() -> Self {
        let (tx, rx) = unbounded();
        Self {
            tx,
            rx: Mutex::new(Some(rx)),
            running: Mutex::new(HashMap::new()),
            gate: Mutex::new(()),
            in_flight: AtomicUsize::new(0),
            queued: AtomicUsize::new(0),
        }
    }

    pub(crate) fn start(inner: &Arc<Inner>) {
        let Some(rx) = inner.scanner.rx.lock().take() else { return };
        let weak = Arc::downgrade(inner);
        let spawned = std::thread::Builder::new().name("sa-scanner".into()).spawn(move || run(&weak, &rx));
        if let Err(e) = spawned {
            tracing::error!(error = %e, "cannot start scanner thread");
        }
    }

    /// Asks for directories of a folder to be scanned. Requests are merged; `""` means the whole folder.
    pub(crate) fn request(&self, folder: FolderId, dirs: Vec<String>, lane: u8) {
        self.in_flight.fetch_add(1, Ordering::Relaxed);
        if self.tx.send(Msg::Request { folder, dirs, lane }).is_err() {
            self.in_flight.fetch_sub(1, Ordering::Relaxed);
        }
    }

    pub(crate) fn wake(&self) {
        let _ = self.tx.send(Msg::Wake);
    }

    pub(crate) fn stop(&self) {
        for flag in self.running.lock().values() {
            flag.store(true, Ordering::Relaxed);
        }
        let _ = self.tx.send(Msg::Stop);
    }

    /// Stops running scans and forgets queued ones, for one folder or all.
    pub(crate) fn cancel(&self, folder: Option<FolderId>) {
        for (id, flag) in self.running.lock().iter() {
            if folder.is_none_or(|f| f == *id) {
                flag.store(true, Ordering::Relaxed);
            }
        }
        let _ = self.tx.send(Msg::Purge(folder));
    }

    #[must_use]
    pub(crate) fn has_pending(&self) -> bool {
        self.in_flight.load(Ordering::Relaxed) > 0 || self.queued.load(Ordering::Relaxed) > 0
    }

    /// Runs `f` while no scan is running. Scans that were in progress are cancelled first and started again
    /// afterwards, so a folder change is never slowed by a long scan and never races one.
    pub(crate) fn quiesced<R>(&self, inner: &Inner, f: impl FnOnce() -> R) -> R {
        let interrupted: Vec<FolderId> = {
            let running = self.running.lock();
            for flag in running.values() {
                flag.store(true, Ordering::Relaxed);
            }
            running.keys().copied().collect()
        };
        let out = {
            let _guard: MutexGuard<'_, ()> = self.gate.lock();
            f()
        };
        for folder in interrupted {
            if inner.db.read(|c| folders::folder(c, folder)).is_ok() {
                self.request(folder, vec![String::new()], jobs::lane::BACKLOG);
            }
        }
        out
    }
}

fn absorb(queue: &mut BTreeMap<FolderId, Wanted>, scanner: &Scanner, msg: Msg, stop: &mut bool) {
    match msg {
        Msg::Request { folder, dirs, lane } => {
            scanner.in_flight.fetch_sub(1, Ordering::Relaxed);
            let w = queue.entry(folder).or_insert_with(|| Wanted { dirs: BTreeSet::new(), lane });
            w.lane = w.lane.min(lane);
            w.dirs.extend(dirs);
            if w.dirs.contains("") {
                w.dirs = std::iter::once(String::new()).collect();
            } else {
                w.dirs = sa_watch::collapse(std::mem::take(&mut w.dirs)).into_iter().collect();
            }
        }
        Msg::Purge(Some(folder)) => {
            queue.remove(&folder);
        }
        Msg::Purge(None) => queue.clear(),
        Msg::Wake => {}
        Msg::Stop => *stop = true,
    }
    scanner.queued.store(queue.len(), Ordering::Relaxed);
}

fn run(weak: &Weak<Inner>, rx: &Receiver<Msg>) {
    let mut queue: BTreeMap<FolderId, Wanted> = BTreeMap::new();
    let mut stop = false;
    loop {
        if queue.is_empty() {
            let Ok(msg) = rx.recv() else { return };
            let Some(inner) = weak.upgrade() else { return };
            absorb(&mut queue, &inner.scanner, msg, &mut stop);
        }
        let Some(inner) = weak.upgrade() else { return };
        while let Ok(msg) = rx.try_recv() {
            absorb(&mut queue, &inner.scanner, msg, &mut stop);
        }
        if stop {
            return;
        }
        if queue.is_empty() {
            continue;
        }
        // Indexing is paused or the Mac is busy: wait, still listening for new requests, wake-ups and stop.
        if inner.manager.hold_reason().is_some() {
            drop(inner);
            match rx.recv_timeout(Duration::from_millis(400)) {
                Ok(msg) => {
                    let Some(inner) = weak.upgrade() else { return };
                    absorb(&mut queue, &inner.scanner, msg, &mut stop);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            continue;
        }
        // Most urgent lane first, then folder order.
        let Some(next) = queue.iter().min_by_key(|(id, w)| (w.lane, **id)).map(|(id, _)| *id) else { continue };
        if let Some(w) = queue.remove(&next) {
            inner.scanner.queued.store(queue.len(), Ordering::Relaxed);
            inner.run_scan(next, w.dirs.into_iter().collect(), w.lane);
        }
    }
}

impl Inner {
    /// Scans directories of one folder and publishes the result.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn run_scan(&self, folder: FolderId, dirs: Vec<String>, lane: u8) {
        let _gate = self.scanner.gate.lock();
        let Ok((f, v, excludes)) = self.db.read(|c| {
            let f = folders::folder(c, folder)?;
            let v = folders::volume(c, f.volume_id)?;
            let ex = folders::excludes(c, folder)?;
            Ok((f, v, ex))
        }) else {
            return; // removed while queued
        };
        let Some(root) = f.root(&v).filter(|_| f.enabled) else {
            return; // off, or its drive is unplugged: nothing to do, nothing to change
        };
        let whole = dirs.iter().any(String::is_empty);

        let cancel = Arc::new(AtomicBool::new(false));
        self.scanner.running.lock().insert(folder, Arc::clone(&cancel));
        self.scans_running.fetch_add(1, Ordering::Relaxed);
        self.notifier.work_started();
        if whole {
            let _ = self.db.write(move |tx| folders::set_scan_state(tx, folder, ScanState::Scanning, None, sa_core::time::now_ms()));
            self.notifier.folders_changed();
        }

        let mut structural = false;
        let mut metadata = false;
        let mut failure: Option<String> = None;
        let mut warning: Option<String> = None;
        let mut cancelled = false;
        let mut cloud_skipped = 0u64;
        let mut unreadable_dirs = 0usize;
        let mut held_back = false;
        let mut orphaned = Vec::new();

        for dir in dirs {
            let target = ScanTarget { folder, root: root.clone(), dir, excludes: excludes.clone(), lane };
            let last_seen = std::sync::atomic::AtomicU64::new(0);
            let result = sa_index::scan(&self.db, &self.pool, &target, &cancel, &|p| {
                let before = last_seen.swap(p.files_seen, Ordering::Relaxed);
                self.discovered.fetch_add(p.files_seen.saturating_sub(before), Ordering::Relaxed);
                if p.new_files > 0 {
                    self.notifier.library_changed(true);
                }
            });
            match result {
                Ok(r) => {
                    structural |= r.new_files + r.relinked + r.restored + r.marked_missing + r.merged_twins > 0;
                    metadata |= r.changed > 0;
                    cloud_skipped += r.skipped_cloud_only;
                    unreadable_dirs += r.unreadable_dirs.len();
                    held_back |= r.held_back_missing;
                    orphaned.extend(r.orphaned_thumbs);
                    if r.outcome == ScanOutcome::Cancelled {
                        cancelled = true;
                        break;
                    }
                }
                Err(e) => {
                    failure = Some(e.to_string());
                    break;
                }
            }
        }
        if !orphaned.is_empty() {
            self.remove_thumb_files(&orphaned);
        }
        if held_back {
            warning = Some("Everything in this folder disappeared at once, so nothing was marked missing. If the drive or share is connected, check access; otherwise remove the folder.".into());
            self.notifier.notice(Notice::FolderLooksEmpty { folder_id: folder.0, folder_name: f.display_name.clone() });
        } else if unreadable_dirs > 0 {
            warning = Some(format!(
                "{unreadable_dirs} subfolder{} could not be read; files in {} were left as they were.",
                if unreadable_dirs == 1 { "" } else { "s" },
                if unreadable_dirs == 1 { "it" } else { "them" },
            ));
        }
        if cloud_skipped > 0 && whole {
            self.notifier.notice(Notice::CloudFilesSkipped {
                folder_id: folder.0,
                folder_name: f.display_name.clone(),
                count: cloud_skipped,
            });
        }

        if whole {
            let (state, message) = match (&failure, cancelled) {
                (Some(e), _) => (ScanState::Error, Some(e.clone())),
                (None, true) => (ScanState::Pending, None),
                (None, false) => (ScanState::Idle, warning),
            };
            if let (ScanState::Error, Some(msg)) = (state, &message) {
                self.notifier.notice(Notice::FolderUnreadable {
                    folder_id: folder.0,
                    folder_name: f.display_name.clone(),
                    message: msg.clone(),
                });
            }
            let _ = self.db.write(move |tx| {
                folders::set_scan_state(tx, folder, state, message.as_deref(), sa_core::time::now_ms())
            });
            self.notifier.folders_changed();
        } else if let Some(e) = &failure {
            tracing::warn!(folder = folder.0, error = %e, "partial scan failed");
        }
        if structural {
            self.notifier.library_changed(true);
        } else if metadata {
            self.notifier.library_changed(false);
        }
        if structural || metadata {
            self.mark_dedupe_dirty();
        }
        self.scanner.running.lock().remove(&folder);
        self.scans_running.fetch_sub(1, Ordering::Relaxed);
    }
}
