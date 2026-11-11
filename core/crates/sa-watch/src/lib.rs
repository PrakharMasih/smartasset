//! Live updates inside the folders the user added (plan L2), using FSEvents through `notify`.
//!
//! Only folders passed to [`Watcher::watch`] are watched. Raw events are noisy (a copy of one big file is hundreds
//! of events), so they are collected, de-duplicated and collapsed to the smallest set of directories to rescan,
//! then delivered as one [`WatchBatch`] per watched folder once things go quiet.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod debounce;

use crossbeam_channel::{Sender, unbounded};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher as _};
use parking_lot::Mutex;
use sa_core::{Error, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

pub use debounce::{DebounceConfig, collapse};

/// Changes inside one watched folder, ready to rescan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchBatch {
    /// The folder root exactly as it was registered with [`Watcher::watch`].
    pub root: PathBuf,
    /// Directories (relative to `root`, `""` = the root) that changed. Never overlapping.
    pub dirs: Vec<String>,
    /// Events were lost or too many arrived: rescan the whole folder.
    pub rescan_all: bool,
}

pub(crate) struct RawChange {
    pub root_key: PathBuf,
    /// Path relative to the canonical root, or `None` when the whole folder needs a rescan.
    pub rel: Option<String>,
    /// The path is an existing directory right now (so it can be scanned itself rather than its parent).
    pub is_dir: bool,
}

struct Registry {
    /// canonical root -> root as registered
    roots: HashMap<PathBuf, PathBuf>,
}

pub struct Watcher {
    inner: Mutex<RecommendedWatcher>,
    registry: Arc<Mutex<Registry>>,
    // Dropping the sender stops the debounce thread.
    _tx: Sender<RawChange>,
}

impl std::fmt::Debug for Watcher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Watcher").finish_non_exhaustive()
    }
}

/// Whether a path below a watched root is noise that must never trigger a rescan.
#[must_use]
pub fn is_ignored_rel(rel: &str) -> bool {
    rel.split('/').any(|c| sa_core::paths::is_hidden_name(c) || sa_core::paths::is_opaque_bundle_dir(c))
}

impl Watcher {
    /// Starts a watcher. `on_batch` runs on a background thread after each quiet period.
    pub fn new(
        config: DebounceConfig,
        on_batch: impl Fn(WatchBatch) + Send + 'static,
    ) -> Result<Self> {
        let (tx, rx) = unbounded::<RawChange>();
        debounce::spawn(rx, config, on_batch);

        let registry = Arc::new(Mutex::new(Registry { roots: HashMap::new() }));
        let reg = Arc::clone(&registry);
        let sender = tx.clone();
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let event = match res {
                Ok(e) => e,
                Err(e) => {
                    tracing::warn!(error = %e, "file watcher error; rescanning watched folders");
                    for root_key in reg.lock().roots.values() {
                        let _ = sender.send(RawChange { root_key: root_key.clone(), rel: None, is_dir: false });
                    }
                    return;
                }
            };
            if matches!(event.kind, EventKind::Access(_)) {
                return;
            }
            let rescan = event.need_rescan();
            let roots = reg.lock();
            for path in &event.paths {
                for (canon, key) in &roots.roots {
                    let Ok(rel) = path.strip_prefix(canon) else { continue };
                    if rescan {
                        let _ = sender.send(RawChange { root_key: key.clone(), rel: None, is_dir: false });
                        continue;
                    }
                    let Some(rel) = rel.to_str() else { continue };
                    if is_ignored_rel(rel) {
                        continue;
                    }
                    let _ = sender.send(RawChange { root_key: key.clone(), rel: Some(rel.to_string()), is_dir: path.is_dir() });
                }
            }
        })
        .map_err(|e| Error::Invalid(format!("cannot start file watcher: {e}")))?;

        Ok(Self { inner: Mutex::new(watcher), registry, _tx: tx })
    }

    /// Starts watching a folder (and everything below it).
    pub fn watch(&self, root: &Path) -> Result<()> {
        let canon = root.canonicalize().map_err(|e| Error::io("watch", root, &e))?;
        self.inner
            .lock()
            .watch(&canon, RecursiveMode::Recursive)
            .map_err(|e| Error::Invalid(format!("cannot watch {}: {e}", root.display())))?;
        self.registry.lock().roots.insert(canon, root.to_path_buf());
        Ok(())
    }

    /// Stops watching a folder. Unknown folders are ignored.
    pub fn unwatch(&self, root: &Path) {
        let mut reg = self.registry.lock();
        let found: Vec<PathBuf> = reg
            .roots
            .iter()
            .filter(|(_, key)| key.as_path() == root)
            .map(|(canon, _)| canon.clone())
            .collect();
        for canon in found {
            let _ = self.inner.lock().unwatch(&canon);
            reg.roots.remove(&canon);
        }
    }

    #[must_use]
    pub fn watched(&self) -> Vec<PathBuf> {
        self.registry.lock().roots.values().cloned().collect()
    }
}

/// Convenience for the engine: a sensible default quiet period (see [`DebounceConfig`]).
#[must_use]
pub fn default_config() -> DebounceConfig {
    DebounceConfig { quiet: Duration::from_millis(600), max_wait: Duration::from_secs(5), max_dirs: 2_000 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noise_is_ignored() {
        assert!(is_ignored_rel(".DS_Store"));
        assert!(is_ignored_rel("shoot/._clip.mov"));
        assert!(is_ignored_rel("a/.Spotlight-V100/x"));
        assert!(is_ignored_rel("Photos Library.photoslibrary/originals/x.jpg"));
        assert!(!is_ignored_rel("shoot/clip.mov"));
        assert!(!is_ignored_rel(""));
    }
}
