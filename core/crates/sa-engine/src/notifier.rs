//! Coalesces engine events so the app is told about bursts once, not per item.
//!
//! The delivery thread sleeps on a condition variable and uses no CPU while the library is idle (plan §8:
//! idle CPU ~0%). It only ticks while indexing work is active, to report progress.

use crate::events::{Event, EventSink, Notice, Progress};
use parking_lot::{Condvar, Mutex};
use std::collections::BTreeSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Events arriving within this window are delivered together.
const COALESCE: Duration = Duration::from_millis(120);
/// How often progress is reported while work is active.
const PROGRESS_EVERY: Duration = Duration::from_millis(500);
/// Thumbnails reported per event; a larger burst is split so one event stays small.
const MAX_THUMBS_PER_EVENT: usize = 512;

#[derive(Default)]
struct Pending {
    structural: bool,
    metadata: bool,
    folders: bool,
    duplicates: bool,
    thumbs: BTreeSet<i64>,
    notices: Vec<Notice>,
}

impl Pending {
    fn has_work(&self) -> bool {
        self.structural
            || self.metadata
            || self.folders
            || self.duplicates
            || !self.thumbs.is_empty()
            || !self.notices.is_empty()
    }
}

#[derive(Default)]
struct State {
    pending: Pending,
    /// Indexing work may be running: tick to report progress.
    active: bool,
    stop: bool,
}

pub struct Notifier {
    state: Mutex<State>,
    cv: Condvar,
    /// Counts every library change, so a cached answer (the duplicate groups) knows when it is out of date.
    epoch: AtomicU64,
}

impl Notifier {
    /// Starts the delivery thread. `progress` computes the current progress snapshot on demand.
    pub fn start(
        sink: Arc<dyn EventSink>,
        progress: impl Fn() -> Progress + Send + 'static,
    ) -> Arc<Self> {
        let n = Arc::new(Self { state: Mutex::new(State::default()), cv: Condvar::new(), epoch: AtomicU64::new(1) });
        let this = Arc::clone(&n);
        let spawned = std::thread::Builder::new().name("sa-events".into()).spawn(move || {
            let mut last_progress = Instant::now()
                .checked_sub(PROGRESS_EVERY)
                .unwrap_or_else(Instant::now);
            loop {
                let (batch, report_progress) = {
                    let mut s = this.state.lock();
                    // Idle: sleep until something happens. Active: wake at least for the next progress report.
                    while !s.stop && !s.pending.has_work() {
                        if s.active {
                            let wait = PROGRESS_EVERY.saturating_sub(last_progress.elapsed());
                            if wait.is_zero() || this.cv.wait_for(&mut s, wait).timed_out() {
                                break;
                            }
                        } else {
                            this.cv.wait(&mut s);
                        }
                    }
                    if s.stop {
                        return;
                    }
                    let has_events = s.pending.has_work();
                    if has_events {
                        // Let a burst finish before delivering it.
                        drop(s);
                        std::thread::sleep(COALESCE);
                        s = this.state.lock();
                    }
                    (std::mem::take(&mut s.pending), s.active)
                };

                if batch.structural {
                    sink.on_event(Event::LibraryChanged { structural: true });
                } else if batch.metadata {
                    sink.on_event(Event::LibraryChanged { structural: false });
                }
                if batch.folders {
                    sink.on_event(Event::FoldersChanged);
                }
                if batch.duplicates {
                    sink.on_event(Event::DuplicatesChanged);
                }
                if !batch.thumbs.is_empty() {
                    let all: Vec<i64> = batch.thumbs.into_iter().collect();
                    for chunk in all.chunks(MAX_THUMBS_PER_EVENT) {
                        sink.on_event(Event::ThumbnailsReady { asset_ids: chunk.to_vec() });
                    }
                }
                for notice in batch.notices {
                    sink.on_event(Event::Notice(notice));
                }

                if report_progress && last_progress.elapsed() >= PROGRESS_EVERY {
                    last_progress = Instant::now();
                    let p = progress();
                    let idle = p.is_idle();
                    sink.on_event(Event::Progress(p));
                    if idle {
                        // Work finished: the final report above lets the app clear its indicator.
                        this.state.lock().active = false;
                    }
                }
            }
        });
        if let Err(e) = spawned {
            tracing::error!(error = %e, "cannot start event thread");
        }
        n
    }

    fn with(&self, f: impl FnOnce(&mut State)) {
        f(&mut self.state.lock());
        self.cv.notify_one();
    }

    /// Changes whenever the library, or what is derived from it, changed.
    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Relaxed)
    }

    pub fn library_changed(&self, structural: bool) {
        self.epoch.fetch_add(1, Ordering::Relaxed);
        self.with(|s| {
            if structural {
                s.pending.structural = true;
            } else {
                s.pending.metadata = true;
            }
        });
    }

    pub fn folders_changed(&self) {
        self.with(|s| s.pending.folders = true);
    }

    pub fn duplicates_changed(&self) {
        self.epoch.fetch_add(1, Ordering::Relaxed);
        self.with(|s| s.pending.duplicates = true);
    }

    pub fn thumbs(&self, ids: impl IntoIterator<Item = i64>) {
        self.with(|s| s.pending.thumbs.extend(ids));
    }

    pub fn notice(&self, notice: Notice) {
        self.with(|s| s.pending.notices.push(notice));
    }

    /// Indexing work started or may have started: report progress until it is done.
    pub fn work_started(&self) {
        self.with(|s| s.active = true);
    }

    pub fn stop(&self) {
        self.with(|s| s.stop = true);
    }
}
