#![allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    clippy::many_single_char_names,
    clippy::assert_is_empty,
    clippy::needless_pass_by_value
)]

use parking_lot::Mutex;
use sa_core::{AssetId, Filters, FolderId, MediaKind, SearchQuery};
use sa_engine::{
    AddFolderRequest, BatchTasks, Conditions, Engine, EngineConfig, Event, EventSink, MountedVolume, PauseReason,
    Thermal,
};
use sa_engine::PerceptualTasks;
use sa_providers::{FakeMediaProvider, FakePerceptualProvider, MediaOutcome, MediaProvider, PerceptualProvider};
use sa_store::folders::AddFolderOutcome;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

#[derive(Default)]
struct Events(Mutex<Vec<Event>>);

impl EventSink for Events {
    fn on_event(&self, event: Event) {
        self.0.lock().push(event);
    }
}

struct H {
    _dir: tempfile::TempDir,
    data: PathBuf,
    media: PathBuf,
    events: Arc<Events>,
    engine: Engine,
}

fn volume() -> MountedVolume {
    MountedVolume { uuid: "TEST-VOL".into(), name: "Test Disk".into(), mount_path: PathBuf::from("/"), is_internal: true }
}

fn config(data: &Path, watch: bool) -> EngineConfig {
    let mut c = EngineConfig::new(data);
    c.watch = watch;
    c.scan_threads = 2;
    c.debounce = sa_watch::DebounceConfig {
        quiet: Duration::from_millis(250),
        max_wait: Duration::from_secs(2),
        max_dirs: 100,
    };
    c
}

fn harness(watch: bool) -> H {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    let events = Arc::new(Events::default());
    let (engine, _) = Engine::open(config(&data, watch), events.clone()).unwrap();
    H { _dir: dir, data, media, events, engine }
}

fn put(root: &Path, rel: &str, content: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, content.repeat(30)).unwrap();
    let f = fs::OpenOptions::new().write(true).open(&p).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_600_000_000)).unwrap();
}

fn wait_until(what: &str, timeout: Duration, mut cond: impl FnMut() -> bool) {
    let start = Instant::now();
    while !cond() {
        assert!(start.elapsed() < timeout, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

impl H {
    fn add(&self, path: &Path) -> FolderId {
        let out = self
            .engine
            .add_folder(AddFolderRequest { path: path.to_path_buf(), bookmark: Some(vec![1, 2, 3]), volume: volume() })
            .unwrap();
        match out {
            AddFolderOutcome::Added { id, .. } => id,
            other => panic!("{other:?}"),
        }
    }

    fn all(&self) -> Vec<i64> {
        self.engine.search(&SearchQuery::default()).unwrap().to_vec()
    }

    fn wait_scanned(&self, expect: usize) {
        wait_until("the scan", Duration::from_secs(20), || self.all().len() >= expect && !self.engine.progress().scanning);
    }

    /// A fake worker: drains every batch it can get, returns what it processed. Like the app, it also runs the
    /// perceptual-hash worker once the thumbnails are done, so the engine can go idle.
    fn drain_worker(&self) -> u32 {
        let provider = FakeMediaProvider;
        let mut processed = 0;
        while let BatchTasks::Batch(b) = self.engine.next_media_batch(16).unwrap() {
            let results: Vec<(i64, MediaOutcome)> = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            processed += u32::try_from(results.len()).unwrap();
            self.engine.submit_media_results(b.batch_id, results).unwrap();
        }
        let hasher = FakePerceptualProvider;
        while let Ok(PerceptualTasks::Batch(b)) = self.engine.next_perceptual_batch(16) {
            let results = b.tasks.iter().map(|t| (t.job_id, hasher.process(t))).collect();
            self.engine.submit_perceptual_results(b.batch_id, results).unwrap();
        }
        processed
    }

    fn thumb_files(&self) -> usize {
        let mut n = 0;
        let mut stack = vec![self.data.join("thumbs")];
        while let Some(d) = stack.pop() {
            for e in fs::read_dir(d).unwrap().flatten() {
                if e.path().is_dir() {
                    stack.push(e.path());
                } else {
                    n += 1;
                }
            }
        }
        n
    }
}

#[test]
fn end_to_end_add_scan_index_search() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..40 {
        put(&h.media, &format!("shoot/clip{i}.mov"), &format!("video {i}"));
    }
    for i in 0..20 {
        put(&h.media, &format!("stills/IMG_{i:04}.jpg"), &format!("photo {i}"));
    }
    put(&h.media, "audio/interview.wav", "voice");
    h.add(&h.media);
    h.wait_scanned(61);

    // Browse pass done: everything is listed before any worker has run (plan: library usable at once).
    assert_eq!(h.all().len(), 61);
    let s = h.engine.stats().unwrap();
    assert_eq!((s.images, s.videos, s.audio), (20, 40, 1));
    let p = h.engine.progress();
    assert_eq!(p.media_remaining, 61);

    // The worker finishes the metadata + thumbnail pass.
    assert_eq!(h.drain_worker(), 61);
    let p = h.engine.progress();
    assert_eq!((p.media_remaining, p.media_done, p.media_failed), (0, 61, 0));
    assert_eq!(h.thumb_files(), 61);

    let ids = h.all();
    let sums = h.engine.summaries(&ids[..5]).unwrap();
    assert!(sums.iter().all(|s| s.thumb_rev == 1 && s.width.is_some() || s.kind == MediaKind::Audio));
    let detail = h.engine.asset_detail(AssetId(ids[0])).unwrap();
    assert!(detail.path.unwrap().starts_with(h.media.canonicalize().unwrap()));

    // Keyword search over names and folders works straight away.
    let q = SearchQuery { text: Some("clip7".into()), ..SearchQuery::default() };
    assert_eq!(h.engine.search(&q).unwrap().len(), 1);
    let q = SearchQuery { text: Some("interview".into()), ..SearchQuery::default() };
    assert_eq!(h.engine.search(&q).unwrap().len(), 1);

    // Events reached the app, including a final progress report that says "idle".
    // The final report comes after the changes it summarises (an early idle report, before any file was seen, does
    // not count).
    wait_until("the idle progress event after the changes", Duration::from_secs(5), || {
        let events = h.events.0.lock();
        let first_change = events.iter().position(|e| matches!(e, Event::LibraryChanged { structural: true }));
        first_change.is_some_and(|i| events[i..].iter().any(|e| matches!(e, Event::Progress(p) if p.is_idle())))
    });
    let events = h.events.0.lock();
    assert!(events.iter().any(|e| matches!(e, Event::LibraryChanged { structural: true })));
    assert!(events.iter().any(|e| matches!(e, Event::ThumbnailsReady { .. })));
    assert!(events.iter().any(|e| matches!(e, Event::FoldersChanged)));
}

#[test]
fn failures_are_isolated_and_classified() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "good1.jpg", "g1");
    put(&h.media, "good2.mov", "g2");
    put(&h.media, "corrupt1.jpg", "c1");
    put(&h.media, "unsupported1.mov", "u1");
    put(&h.media, "locked1.jpg", "l1");
    put(&h.media, "flaky1.jpg", "f1");
    h.add(&h.media);
    h.wait_scanned(6);
    h.drain_worker();

    let p = h.engine.progress();
    // good x2 done; corrupt / unsupported / locked failed for good; flaky is backing off.
    assert_eq!(p.media_done, 2, "{p:?}");
    assert_eq!(p.media_failed, 3, "{p:?}");
    assert_eq!(p.media_remaining, 1, "the flaky file waits out its backoff: {p:?}");
    // Failed files stay in the library, browsable by name.
    assert_eq!(h.all().len(), 6);
    let corrupt = h.engine.search(&SearchQuery { text: Some("corrupt1".into()), ..SearchQuery::default() }).unwrap();
    let s = h.engine.summaries(&corrupt).unwrap();
    assert_eq!(s[0].probe_state, sa_store::model::ProbeState::Failed);
    assert_eq!(s[0].thumb_rev, 0);
}

#[test]
fn a_crash_mid_batch_loses_nothing_and_duplicates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    for i in 0..30 {
        put(&media, &format!("f{i}.jpg"), &format!("c{i}"));
    }
    {
        let events = Arc::new(Events::default());
        let (engine, info) = Engine::open(config(&data, false), events).unwrap();
        assert!(!info.unclean_exit);
        engine.start().unwrap();
        engine
            .add_folder(AddFolderRequest { path: media.clone(), bookmark: None, volume: volume() })
            .unwrap();
        wait_until("scan", Duration::from_secs(20), || {
            engine.search(&SearchQuery::default()).unwrap().len() == 30 && !engine.progress().scanning
        });
        // Lease a batch and do half the work, then "crash": drop everything with no submit and no shutdown.
        let BatchTasks::Batch(b) = engine.next_media_batch(10).unwrap() else { panic!("expected a batch") };
        assert_eq!(b.tasks.len(), 10);
        assert_eq!(engine.progress().media_remaining, 30);
        drop(engine);
    }
    let events = Arc::new(Events::default());
    let (engine, info) = Engine::open(config(&data, false), events).unwrap();
    assert!(info.unclean_exit, "the previous session did not shut down cleanly");
    assert_eq!(info.database_problem, None);
    assert_eq!(info.asset_count, 30);
    // The orphaned leases are back in the queue: all 30 jobs are runnable, none lost, none doubled.
    let p = engine.progress();
    assert_eq!(p.media_remaining, 30);
    assert_eq!(p.media_total, 30);
    let h = H { _dir: dir, data: data.clone(), media: media.clone(), events: Arc::new(Events::default()), engine };
    assert_eq!(h.drain_worker(), 30);
    let p = h.engine.progress();
    assert_eq!((p.media_done, p.media_remaining), (30, 0));
    assert_eq!(h.all().len(), 30);
    assert_eq!(h.thumb_files(), 30);
    // Reopening and rescanning changes nothing (idempotent).
    h.engine.start().unwrap();
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(h.all().len(), 30);
    assert_eq!(h.engine.progress().media_total, 30);
}

#[test]
fn pause_resume_and_conditions_gate_the_workers() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..5 {
        put(&h.media, &format!("f{i}.jpg"), &format!("c{i}"));
    }
    h.add(&h.media);
    h.wait_scanned(5);

    h.engine.pause_indexing();
    assert!(matches!(h.engine.next_media_batch(10).unwrap(), BatchTasks::Held(PauseReason::User)));
    assert_eq!(h.engine.progress().hold, Some(PauseReason::User));
    h.engine.resume_indexing();

    h.engine.set_index_only_on_power(true).unwrap();
    h.engine.set_conditions(Conditions { on_battery: true, ..Conditions::default() });
    assert!(matches!(h.engine.next_media_batch(10).unwrap(), BatchTasks::Held(PauseReason::Battery)));
    h.engine.set_conditions(Conditions::default());
    h.engine.set_conditions(Conditions { thermal: Thermal::Serious, ..Conditions::default() });
    assert!(matches!(h.engine.next_media_batch(10).unwrap(), BatchTasks::Held(PauseReason::Thermal)));
    h.engine.set_conditions(Conditions::default());
    assert_eq!(h.drain_worker(), 5);
}

#[test]
fn cancel_stops_work_and_reindex_picks_it_up_again() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..12 {
        put(&h.media, &format!("f{i}.jpg"), &format!("c{i}"));
    }
    h.add(&h.media);
    h.wait_scanned(12);
    let BatchTasks::Batch(b) = h.engine.next_media_batch(4).unwrap() else { panic!() };
    h.engine.cancel_indexing(None).unwrap();
    assert!(h.engine.is_batch_revoked(b.batch_id), "the worker is told to stop between items");
    // The revoked batch's late results are thrown away, not committed.
    let late: Vec<_> = b.tasks.iter().map(|t| (t.job_id, FakeMediaProvider.process(t))).collect();
    let r = h.engine.submit_media_results(b.batch_id, late).unwrap();
    assert_eq!((r.committed, r.discarded), (0, 4));
    assert!(matches!(h.engine.next_media_batch(10).unwrap(), BatchTasks::Empty));
    assert_eq!(h.all().len(), 12, "cancelling never removes files from the library");

    assert_eq!(h.engine.reindex_unfinished().unwrap(), 12);
    assert_eq!(h.drain_worker(), 12);
    assert_eq!(h.engine.progress().media_done, 12);
}

#[test]
fn a_file_edited_while_being_processed_is_processed_again() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "edit.jpg", "version one");
    h.add(&h.media);
    h.wait_scanned(1);
    let BatchTasks::Batch(b) = h.engine.next_media_batch(10).unwrap() else { panic!() };
    // The user saves the file in an editor while the worker is busy with the old content.
    put(&h.media, "edit.jpg", "version two is longer");
    h.engine.rescan(None).unwrap();
    wait_until("the rescan to see the edit", Duration::from_secs(10), || {
        let id = h.all()[0];
        h.engine.summaries(&[id]).unwrap()[0].size > 330
    });
    let results: Vec<_> = b.tasks.iter().map(|t| (t.job_id, FakeMediaProvider.process(t))).collect();
    let r = h.engine.submit_media_results(b.batch_id, results).unwrap();
    assert_eq!(r.discarded, 1, "stale result for the old content must not be committed");
    assert_eq!(h.engine.summaries(&h.all()).unwrap()[0].thumb_rev, 0);
    assert_eq!(h.thumb_files(), 0, "the stale thumbnail file is removed");
    // The job is runnable again and now commits.
    assert_eq!(h.drain_worker(), 1);
    assert_eq!(h.engine.summaries(&h.all()).unwrap()[0].thumb_rev, 1);
}

#[test]
fn unplugged_drives_stay_searchable_and_work_waits_for_them() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..6 {
        put(&h.media, &format!("beach{i}.jpg"), &format!("c{i}"));
    }
    h.add(&h.media);
    h.wait_scanned(6);
    h.engine.volume_unmounted("TEST-VOL").unwrap();
    // L4: results remain, they name the drive to plug in, nothing is marked missing, no job can run.
    let q = SearchQuery { text: Some("beach".into()), ..SearchQuery::default() };
    let ids = h.engine.search(&q).unwrap();
    assert_eq!(ids.len(), 6);
    let s = h.engine.summaries(&ids).unwrap();
    assert!(s.iter().all(|a| !a.volume_online && a.volume_name == "Test Disk"));
    assert!(matches!(h.engine.next_media_batch(10).unwrap(), BatchTasks::Empty));
    assert!(h.engine.paths(&ids).unwrap().iter().all(|(_, p)| p.is_none()));
    // A rescan while unplugged does nothing destructive.
    h.engine.rescan(None).unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(h.engine.stats().unwrap().missing, 0);

    // Plugged back in (possibly at a different mount path): work resumes.
    h.engine.volume_mounted(&volume()).unwrap();
    assert_eq!(h.engine.paths(&ids).unwrap().iter().filter(|(_, p)| p.is_some()).count(), 6);
    assert_eq!(h.drain_worker(), 6);
}

#[test]
fn removing_a_folder_removes_index_data_thumbnails_and_never_touches_files() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..8 {
        put(&h.media, &format!("a{i}.jpg"), &format!("c{i}"));
    }
    let id = h.add(&h.media);
    h.wait_scanned(8);
    h.drain_worker();
    assert_eq!(h.thumb_files(), 8);
    let before: Vec<_> = fs::read_dir(&h.media).unwrap().flatten().map(|e| e.file_name()).collect();

    h.engine.remove_folder(id).unwrap();
    assert!(h.all().is_empty());
    assert_eq!(h.thumb_files(), 0);
    assert!(h.engine.list_folders().unwrap().is_empty());
    let after: Vec<_> = fs::read_dir(&h.media).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(before.len(), after.len(), "the originals are untouched");
    assert_eq!(h.engine.progress().media_remaining, 0);
}

#[test]
fn adding_a_parent_folder_merges_a_child_and_keeps_its_tags() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "day1/a.jpg", "a");
    put(&h.media, "day2/b.jpg", "b");
    let child = h.add(&h.media.join("day1"));
    h.wait_scanned(1);
    let id = AssetId(h.all()[0]);
    h.engine.add_tags(&[id], &["keeper".into()]).unwrap();
    h.engine.set_rating(&[id], 5).unwrap();

    let out = h
        .engine
        .add_folder(AddFolderRequest { path: h.media.clone(), bookmark: None, volume: volume() })
        .unwrap();
    let AddFolderOutcome::Added { absorbed, .. } = out else { panic!("{out:?}") };
    assert_eq!(absorbed, vec![child]);
    h.wait_scanned(2);
    assert_eq!(h.engine.list_folders().unwrap().len(), 1);
    let d = h.engine.asset_detail(id).unwrap();
    assert_eq!(d.rel_path, "day1/a.jpg");
    assert_eq!((d.summary.rating, d.tags.clone()), (5, vec!["keeper".to_string()]));
    assert_eq!(h.all().len(), 2, "no duplicate of the merged file");
}

#[test]
fn live_updates_pick_up_new_moved_and_deleted_files() {
    let h = harness(true);
    h.engine.start().unwrap();
    put(&h.media, "keep.jpg", "keep");
    put(&h.media, "move-me.jpg", "mover");
    h.add(&h.media);
    h.wait_scanned(2);
    std::thread::sleep(Duration::from_millis(800)); // let FSEvents settle
    let mover = AssetId(
        h.engine.search(&SearchQuery { text: Some("move-me".into()), ..SearchQuery::default() }).unwrap()[0],
    );
    h.engine.set_rating(&[mover], 4).unwrap();

    // A new file appears.
    put(&h.media, "new/arrival.mov", "arrived");
    wait_until("the new file to appear", Duration::from_secs(20), || h.all().len() == 3);
    // A file is moved: same asset, same rating.
    fs::create_dir_all(h.media.join("sorted")).unwrap();
    fs::rename(h.media.join("move-me.jpg"), h.media.join("sorted/renamed.jpg")).unwrap();
    wait_until("the move to be recognised", Duration::from_secs(20), || {
        h.engine.asset_detail(mover).is_ok_and(|d| d.rel_path == "sorted/renamed.jpg")
    });
    assert_eq!(h.engine.asset_detail(mover).unwrap().summary.rating, 4);
    assert_eq!(h.all().len(), 3, "a move creates no new record");
    // A file is deleted: it is marked missing, hidden from the default view, and keeps its data.
    fs::remove_file(h.media.join("keep.jpg")).unwrap();
    wait_until("the deletion", Duration::from_secs(20), || h.all().len() == 2);
    assert_eq!(h.engine.stats().unwrap().missing, 1);
}

#[test]
fn organizing_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    put(&media, "a.jpg", "a");
    put(&media, "b.jpg", "b");
    let id;
    {
        let (engine, _) = Engine::open(config(&data, false), Arc::new(Events::default())).unwrap();
        engine.start().unwrap();
        engine.add_folder(AddFolderRequest { path: media.clone(), bookmark: None, volume: volume() }).unwrap();
        wait_until("scan", Duration::from_secs(20), || engine.search(&SearchQuery::default()).unwrap().len() == 2);
        id = AssetId(engine.search(&SearchQuery { text: Some("a.jpg".into()), ..SearchQuery::default() }).unwrap()[0]);
        engine.set_rating(&[id], 3).unwrap();
        engine.add_tags(&[id], &["Hero".into()]).unwrap();
        let c = engine.create_collection("Picks").unwrap();
        engine.add_to_collection(c, &[id]).unwrap();
        let q = SearchQuery { filters: Filters { min_rating: Some(3), ..Filters::default() }, ..SearchQuery::default() };
        engine.create_smart_collection("Good", &q).unwrap();
        engine.shutdown().unwrap();
    }
    let (engine, info) = Engine::open(config(&data, false), Arc::new(Events::default())).unwrap();
    assert!(!info.unclean_exit, "a clean shutdown must not look like a crash");
    let d = engine.asset_detail(id).unwrap();
    assert_eq!((d.summary.rating, d.tags), (3, vec!["Hero".to_string()]));
    assert_eq!(engine.collections().unwrap()[0].asset_count, 1);
    let smart = engine.smart_collections().unwrap().remove(0);
    assert_eq!(engine.search(&smart.query).unwrap().to_vec(), vec![id.0]);
    // The folder list survives, offline until the app reports the volume.
    assert_eq!(engine.list_folders().unwrap().len(), 1);
}

#[test]
fn prioritised_assets_are_processed_first() {
    let h = harness(false);
    h.engine.start().unwrap();
    for i in 0..30 {
        put(&h.media, &format!("f{i:02}.jpg"), &format!("c{i}"));
    }
    h.add(&h.media);
    h.wait_scanned(30);
    let ids = h.all();
    let last = AssetId(*ids.last().unwrap());
    h.engine.prioritize(&[last]).unwrap();
    let BatchTasks::Batch(b) = h.engine.next_media_batch(5).unwrap() else { panic!() };
    assert_eq!(b.tasks[0].asset_id, last.0, "what is on screen is indexed first");
    h.engine.release_batch(b.batch_id).unwrap();
    assert_eq!(h.engine.progress().media_remaining, 30, "a released batch loses nothing");
}

#[test]
fn excluded_subfolders_are_never_indexed() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "keep/a.jpg", "a");
    put(&h.media, "cache/b.jpg", "b");
    let id = h.add(&h.media);
    h.wait_scanned(2);
    h.engine.set_excludes(id, &["cache".into()]).unwrap();
    assert_eq!(h.all().len(), 1);
    h.engine.rescan(None).unwrap();
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(h.all().len(), 1, "a rescan does not bring excluded files back");
    h.engine.set_excludes(id, &[]).unwrap();
    h.engine.rescan(None).unwrap();
    wait_until("the include", Duration::from_secs(10), || h.all().len() == 2);
}

#[test]
fn disabling_a_folder_hides_it_without_losing_anything() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "a.jpg", "a");
    let id = h.add(&h.media);
    h.wait_scanned(1);
    let asset = AssetId(h.all()[0]);
    h.engine.set_rating(&[asset], 5).unwrap();
    h.engine.set_folder_enabled(id, false).unwrap();
    assert!(h.all().is_empty());
    assert!(matches!(h.engine.next_media_batch(5).unwrap(), BatchTasks::Empty));
    h.engine.set_folder_enabled(id, true).unwrap();
    wait_until("it to come back", Duration::from_secs(10), || h.all().len() == 1);
    assert_eq!(h.engine.asset_detail(asset).unwrap().summary.rating, 5);
}

#[test]
fn idle_engine_stays_quiet() {
    let h = harness(false);
    h.engine.start().unwrap();
    put(&h.media, "a.jpg", "a");
    h.add(&h.media);
    h.wait_scanned(1);
    h.drain_worker();
    wait_until("idle", Duration::from_secs(5), || h.engine.progress().is_idle());
    std::thread::sleep(Duration::from_millis(1500));
    let n = h.events.0.lock().len();
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(h.events.0.lock().len(), n, "no events, no ticking, when nothing is happening");
}

#[test]
fn bad_input_is_rejected_cleanly() {
    let h = harness(false);
    h.engine.start().unwrap();
    let file = h.media.join("not-a-folder.jpg");
    fs::write(&file, b"x").unwrap();
    for bad in [file, h.media.join("does-not-exist")] {
        let r = h.engine.add_folder(AddFolderRequest { path: bad, bookmark: None, volume: volume() });
        assert!(r.is_err());
    }
    let wrong_volume = MountedVolume { mount_path: PathBuf::from("/Volumes/Elsewhere"), ..volume() };
    let r = h.engine.add_folder(AddFolderRequest { path: h.media.clone(), bookmark: None, volume: wrong_volume });
    assert!(matches!(r, Err(sa_core::Error::Invalid(_))));
    assert!(h.engine.list_folders().unwrap().is_empty());
    assert!(h.engine.remove_folder(FolderId(999)).is_err());
}
