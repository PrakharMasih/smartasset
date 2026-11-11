#![allow(clippy::unwrap_used, clippy::assert_is_empty)]

use crossbeam_channel::{Receiver, unbounded};
use sa_watch::{DebounceConfig, WatchBatch, Watcher};
use std::fs;
use std::time::Duration;

fn setup() -> (tempfile::TempDir, Watcher, Receiver<WatchBatch>) {
    let dir = tempfile::tempdir().unwrap();
    let (tx, rx) = unbounded();
    let cfg = DebounceConfig { quiet: Duration::from_millis(300), max_wait: Duration::from_secs(3), max_dirs: 50 };
    let w = Watcher::new(cfg, move |b| {
        let _ = tx.send(b);
    })
    .unwrap();
    // Let FSEvents establish its stream before the test starts changing things.
    w.watch(dir.path()).unwrap();
    // Events that pre-date the watch (creating the temp directory) can still be in flight. Let them settle so a
    // test only ever sees what it caused itself.
    std::thread::sleep(Duration::from_millis(500));
    while rx.recv_timeout(Duration::from_millis(1500)).is_ok() {}
    (dir, w, rx)
}

fn next(rx: &Receiver<WatchBatch>) -> WatchBatch {
    rx.recv_timeout(Duration::from_secs(15)).expect("a batch within 15 s")
}

#[test]
fn new_and_changed_files_report_their_directory_once() {
    let (dir, _w, rx) = setup();
    fs::create_dir_all(dir.path().join("shoot/day1")).unwrap();
    for i in 0..30 {
        fs::write(dir.path().join(format!("shoot/day1/f{i}.jpg")), b"x").unwrap();
    }
    let batch = next(&rx);
    assert_eq!(batch.root, dir.path());
    assert!(!batch.rescan_all);
    // 30 files and two new directories collapse to a small, non-overlapping set that covers the new files.
    assert!(batch.dirs.len() <= 2, "{batch:?}");
    assert!(batch.dirs.iter().all(|d| "shoot/day1".starts_with(d.as_str()) || d.starts_with("shoot")), "{batch:?}");
    assert!(rx.recv_timeout(Duration::from_millis(900)).is_err(), "one burst, one batch");
}

#[test]
fn hidden_files_and_bundles_never_trigger_a_rescan() {
    let (dir, _w, rx) = setup();
    fs::write(dir.path().join(".DS_Store"), b"x").unwrap();
    fs::create_dir_all(dir.path().join("Photos.photoslibrary/originals")).unwrap();
    fs::write(dir.path().join("Photos.photoslibrary/originals/a.jpg"), b"x").unwrap();
    fs::create_dir_all(dir.path().join(".hidden")).unwrap();
    fs::write(dir.path().join(".hidden/b.jpg"), b"x").unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(2500)).is_err(), "noise must stay silent");
}

#[test]
fn deleting_and_renaming_are_reported() {
    let (dir, _w, rx) = setup();
    fs::write(dir.path().join("a.jpg"), b"x").unwrap();
    let _ = next(&rx);
    fs::rename(dir.path().join("a.jpg"), dir.path().join("b.jpg")).unwrap();
    let batch = next(&rx);
    assert_eq!(batch.dirs, vec![String::new()]);
    fs::remove_file(dir.path().join("b.jpg")).unwrap();
    assert_eq!(next(&rx).dirs, vec![String::new()]);
}

#[test]
fn unwatching_stops_events() {
    let (dir, w, rx) = setup();
    w.unwatch(dir.path());
    assert!(w.watched().is_empty());
    fs::write(dir.path().join("late.jpg"), b"x").unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(1800)).is_err());
}

#[test]
fn too_many_directories_collapse_into_a_full_rescan() {
    let (dir, _w, rx) = setup();
    for i in 0..120 {
        fs::create_dir_all(dir.path().join(format!("d{i}"))).unwrap();
        fs::write(dir.path().join(format!("d{i}/f.jpg")), b"x").unwrap();
    }
    let mut batch = next(&rx);
    // Large bursts can arrive as several batches; the first that overflows must be a full rescan.
    while !batch.rescan_all && batch.dirs.len() < 50 {
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(b) => batch = b,
            Err(_) => break,
        }
    }
    assert!(batch.rescan_all || batch.dirs.len() <= 50, "{batch:?}");
}
