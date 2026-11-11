//! Collects raw change events and delivers them in calm, minimal batches.

use crate::{RawChange, WatchBatch};
use crossbeam_channel::{Receiver, RecvTimeoutError};
use sa_core::paths;
use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
pub struct DebounceConfig {
    /// A batch is delivered after this long without new events.
    pub quiet: Duration,
    /// ...but never later than this after the first event (a long copy must not postpone indexing forever).
    pub max_wait: Duration,
    /// More changed directories than this collapse into "rescan the whole folder".
    pub max_dirs: usize,
}

#[derive(Default)]
struct Pending {
    dirs: BTreeSet<String>,
    all: bool,
}

/// Directory to rescan for a changed path. A directory that exists is scanned itself (everything inside it is
/// new or changed). Anything else, a file or a path that is already gone, is handled by rescanning its parent,
/// which covers a changed file and a vanished directory alike.
fn dir_for(rel: &str, is_dir: bool) -> String {
    if is_dir { rel.to_string() } else { paths::rel_parent(rel).to_string() }
}

/// Reduces directories to the outermost ones: if `a` and `a/b` both changed, scanning `a` covers `a/b`.
#[must_use]
pub fn collapse(dirs: impl IntoIterator<Item = String>) -> Vec<String> {
    let sorted: BTreeSet<String> = dirs.into_iter().collect();
    let mut out: Vec<String> = Vec::new();
    for d in sorted {
        let covered = out.iter().any(|p| p.is_empty() || d == *p || (d.starts_with(p.as_str()) && d[p.len()..].starts_with('/')));
        if !covered {
            out.push(d);
        }
    }
    out
}

pub(crate) fn spawn(rx: Receiver<RawChange>, cfg: DebounceConfig, on_batch: impl Fn(WatchBatch) + Send + 'static) {
    let _ = std::thread::Builder::new().name("sa-watch-debounce".into()).spawn(move || {
        let mut pending: HashMap<PathBuf, Pending> = HashMap::new();
        loop {
            // Wait for the first event of a burst.
            let Ok(first) = rx.recv() else { return }; // watcher dropped
            let started = Instant::now();
            add(&mut pending, first, cfg.max_dirs);
            // Keep collecting until things go quiet, or the burst has lasted long enough.
            loop {
                let remaining = cfg.max_wait.saturating_sub(started.elapsed());
                if remaining.is_zero() {
                    break;
                }
                match rx.recv_timeout(cfg.quiet.min(remaining)) {
                    Ok(c) => add(&mut pending, c, cfg.max_dirs),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => {
                        flush(&mut pending, &on_batch);
                        return;
                    }
                }
            }
            flush(&mut pending, &on_batch);
        }
    });
}

fn add(pending: &mut HashMap<PathBuf, Pending>, change: RawChange, max_dirs: usize) {
    let p = pending.entry(change.root_key).or_default();
    match change.rel {
        None => p.all = true,
        Some(rel) => {
            if p.dirs.len() >= max_dirs {
                p.all = true;
            } else {
                p.dirs.insert(dir_for(&rel, change.is_dir));
            }
        }
    }
}

fn flush(pending: &mut HashMap<PathBuf, Pending>, on_batch: &impl Fn(WatchBatch)) {
    for (root, p) in pending.drain() {
        // `rescan_all` means events were lost or overflowed. A change at the top level is just directory "".
        let dirs = if p.all { vec![String::new()] } else { collapse(p.dirs) };
        on_batch(WatchBatch { root, dirs, rescan_all: p.all });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(items: &[&str]) -> Vec<String> {
        collapse(items.iter().map(|s| (*s).to_string()))
    }

    #[test]
    fn collapse_keeps_outermost_only() {
        assert_eq!(c(&["a/b", "a", "a/b/c", "x"]), vec!["a", "x"]);
        assert_eq!(c(&["ab", "a"]), vec!["a", "ab"]);
        assert_eq!(c(&["a/b", "a/c"]), vec!["a/b", "a/c"]);
        assert_eq!(c(&["", "a", "b/c"]), vec![""]);
        assert_eq!(c(&[]), Vec::<String>::new());
    }

    #[test]
    fn parent_of_changed_path() {
        assert_eq!(dir_for("a/b/c.jpg", false), "a/b");
        assert_eq!(dir_for("c.jpg", false), "");
        assert_eq!(dir_for("a/b", true), "a/b");
    }
}
