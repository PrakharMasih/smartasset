#![allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    clippy::many_single_char_names,
    clippy::needless_pass_by_value,
    clippy::cast_possible_truncation,
    clippy::assert_is_empty,
    clippy::unnecessary_debug_formatting,
    clippy::cast_sign_loss
)]
//! Phase 2: exact and near duplicates, the hash job, and the cleanup guard (plan A1–A3).

use parking_lot::Mutex;
use sa_core::{AssetId, Error, FolderId, SearchQuery};
use sa_engine::{
    AddFolderRequest, BatchTasks, Conditions, DuplicateGroup, DuplicateKind, Engine, EngineConfig, Event, EventSink,
    Calibration, EmbeddingTasks, MountedVolume, PerceptualTasks, Thermal,
};
use sa_providers::{
    EmbeddingProvider, FakeEmbeddingProvider, FakeMediaProvider, FakePerceptualProvider, MediaProvider, PerceptualProvider,
};
use sa_store::folders::AddFolderOutcome;
use std::collections::BTreeSet;
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

fn volume() -> MountedVolume {
    MountedVolume { uuid: "TEST-VOL".into(), name: "Test Disk".into(), mount_path: PathBuf::from("/"), is_internal: true }
}

fn config(data: &Path) -> EngineConfig {
    let mut c = EngineConfig::new(data);
    c.watch = false;
    c.scan_threads = 2;
    c
}

#[allow(dead_code)]
struct H {
    dir: tempfile::TempDir,
    data: PathBuf,
    media: PathBuf,
    events: Arc<Events>,
    engine: Engine,
}

fn harness() -> H {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    let events = Arc::new(Events::default());
    let (engine, _) = Engine::open(config(&data), events.clone()).unwrap();
    H { dir, data, media, events, engine }
}

/// Deterministic pseudo-random bytes.
fn pattern(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect()
}

fn put(root: &Path, rel: &str, bytes: &[u8]) -> PathBuf {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, bytes).unwrap();
    let f = fs::OpenOptions::new().write(true).open(&p).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_600_000_000)).unwrap();
    p
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
            .add_folder(AddFolderRequest { path: path.to_path_buf(), bookmark: Some(vec![1]), volume: volume() })
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

    /// Fake media worker: finishes the browse pass so the duplicate jobs may start.
    fn drain_media(&self) {
        let provider = FakeMediaProvider;
        while let BatchTasks::Batch(b) = self.engine.next_media_batch(16).unwrap() {
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_media_results(b.batch_id, results).unwrap();
        }
    }

    /// Fake perceptual worker. Returns how many files it hashed.
    fn drain_perceptual(&self) -> usize {
        let provider = FakePerceptualProvider;
        let mut n = 0;
        while let PerceptualTasks::Batch(b) = self.engine.next_perceptual_batch(16).unwrap() {
            n += b.tasks.len();
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_perceptual_results(b.batch_id, results).unwrap();
        }
        n
    }

    fn path_of(&self, id: i64) -> PathBuf {
        self.engine.asset_detail(AssetId(id)).unwrap().path.unwrap()
    }

    fn id_of(&self, path: &Path) -> i64 {
        let want = path.canonicalize().unwrap();
        self.all().into_iter().find(|id| self.path_of(*id) == want).unwrap_or_else(|| panic!("{path:?} is not indexed"))
    }

    fn hash_hex(&self, id: i64) -> Option<String> {
        self.engine.asset_detail(AssetId(id)).unwrap().content_hash_hex
    }

    /// Waits until the exact groups are complete (`groups` of them) and nothing is left to hash.
    fn wait_exact(&self, groups: usize) -> Vec<DuplicateGroup> {
        wait_until("exact duplicate groups", Duration::from_secs(20), || {
            self.engine.duplicates().is_ok_and(|d| d.sets.exact.len() == groups && d.hash_remaining == 0)
        });
        self.engine.duplicates().unwrap().sets.exact.clone()
    }
}

fn blake_hex(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

fn ids_of(g: &DuplicateGroup) -> BTreeSet<i64> {
    g.members.iter().map(|m| m.asset_id).collect()
}

/// Every file under `root`: path, size, modification time, content. A change to any of it shows up.
fn fingerprint_tree(root: &Path) -> Vec<(PathBuf, u64, SystemTime, String)> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                let m = fs::metadata(&p).unwrap();
                out.push((p.clone(), m.len(), m.modified().unwrap(), blake_hex(&fs::read(&p).unwrap())));
            }
        }
    }
    out.sort();
    out
}

// ---- exact duplicates (A1) -------------------------------------------------------------------------------------

struct Known {
    /// The known sets of copies.
    groups: Vec<Vec<PathBuf>>,
    /// Files that look like copies to the cheap check (same size, same samples) but are not.
    impostors: Vec<PathBuf>,
    uniques: Vec<PathBuf>,
}

fn known_library(root: &Path) -> Known {
    let (a, b, c) = (root.join("shoot-a"), root.join("backup"), root.join("exports/2024"));
    let big = pattern(200_000, 1);
    let small = pattern(5_000, 2);
    let video = pattern(300_000, 3);
    let groups = vec![
        vec![put(&a, "IMG_0001.jpg", &big), put(&b, "copy of IMG_0001.jpg", &big)],
        vec![put(&a, "note.wav", &small), put(&b, "note.wav", &small), put(&c, "note final.wav", &small)],
        vec![put(&a, "clip.mov", &video), put(&c, "renamed.mov", &video)],
    ];
    // Same size and the same first, middle and last 16 KiB, but one byte differs in between.
    let twin = pattern(200_000, 4);
    let mut other = twin.clone();
    other[50_000] ^= 0xFF;
    let impostors = vec![put(&a, "twin-a.jpg", &twin), put(&b, "twin-b.jpg", &other)];
    // Same size as the first set, different content at the start.
    let uniques = vec![
        put(&a, "same-size.jpg", &pattern(200_000, 5)),
        put(&a, "solo1.jpg", &pattern(77_777, 6)),
        put(&b, "solo2.mov", &pattern(1_000_000, 7)),
        put(&c, "empty1.wav", b""),
        put(&c, "empty2.wav", b""),
    ];
    Known { groups, impostors, uniques }
}

#[test]
fn exact_copies_are_found_and_look_alikes_are_not() {
    let h = harness();
    h.engine.start().unwrap();
    let known = known_library(&h.media);
    h.add(&h.media);
    h.wait_scanned(14);
    h.drain_media();

    let found = h.wait_exact(3);

    // 100 % recall, 0 false groups: the found sets are exactly the known sets.
    let want: BTreeSet<BTreeSet<i64>> = known.groups.iter().map(|g| g.iter().map(|p| h.id_of(p)).collect()).collect();
    let got: BTreeSet<BTreeSet<i64>> = found.iter().map(ids_of).collect();
    assert_eq!(got, want);
    assert!(found.iter().all(|g| g.kind == DuplicateKind::Exact && g.members.iter().all(|m| m.similarity == 100)));
    assert!(found.iter().all(|g| g.members.iter().filter(|m| m.suggested_keep).count() == 1 && g.members[0].suggested_keep));

    // The impostors share size and samples but not content: both were read in full and kept apart.
    let (t1, t2) = (h.id_of(&known.impostors[0]), h.id_of(&known.impostors[1]));
    let (h1, h2) = (h.hash_hex(t1).unwrap(), h.hash_hex(t2).unwrap());
    assert_ne!(h1, h2);
    assert_eq!(h1, blake_hex(&fs::read(&known.impostors[0]).unwrap()));

    // Hashes are right, and files that cannot be copies of anything were never read in full.
    for g in &known.groups {
        for p in g {
            assert_eq!(h.hash_hex(h.id_of(p)).unwrap(), blake_hex(&fs::read(p).unwrap()));
        }
    }
    for p in &known.uniques {
        assert!(h.hash_hex(h.id_of(p)).is_none(), "{p:?} has no possible copy, so it needs no full hash");
    }

    // Space wasted: (n - 1) copies of each.
    let d = h.engine.duplicates().unwrap();
    assert_eq!(d.sets.exact_wasted, 200_000 + 2 * 5_000 + 300_000);
    assert_eq!(found.iter().map(|g| g.wasted_bytes).sum::<i64>(), d.sets.exact_wasted);
    // Biggest waste first.
    assert!(found.windows(2).all(|w| w[0].wasted_bytes >= w[1].wasted_bytes));
    wait_until("the duplicates event", Duration::from_secs(5), || {
        h.events.0.lock().iter().any(|e| matches!(e, Event::DuplicatesChanged))
    });
}

#[test]
fn finding_duplicates_changes_no_file() {
    let h = harness();
    h.engine.start().unwrap();
    let known = known_library(&h.media);
    let before = fingerprint_tree(&h.media);
    h.add(&h.media);
    h.wait_scanned(14);
    h.drain_media();
    h.wait_exact(known.groups.len());
    h.drain_perceptual();
    // A rescan after hashing, too.
    h.engine.rescan(None).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(fingerprint_tree(&h.media), before, "every byte, size and modification time is as it was");
}

#[test]
fn a_new_copy_and_an_edited_copy_are_noticed() {
    let h = harness();
    h.engine.start().unwrap();
    let data = pattern(150_000, 9);
    let first = put(&h.media, "a/one.jpg", &data);
    let second = put(&h.media, "b/two.jpg", &data);
    h.add(&h.media);
    h.wait_scanned(2);
    h.drain_media();
    assert_eq!(h.wait_exact(1)[0].members.len(), 2);

    // A third copy arrives.
    let third = put(&h.media, "c/three.jpg", &data);
    h.engine.rescan(None).unwrap();
    wait_until("the third file", Duration::from_secs(10), || h.all().len() == 3 && !h.engine.progress().scanning);
    h.drain_media();
    wait_until("three in the group", Duration::from_secs(10), || {
        h.engine.duplicates().is_ok_and(|d| d.sets.exact.first().is_some_and(|g| g.members.len() == 3) && d.hash_remaining == 0)
    });

    // One copy is edited in place: its old hash is dropped, it leaves the group, and nothing stale remains.
    let mut edited = data.clone();
    edited[10] ^= 1;
    fs::write(&third, &edited).unwrap();
    fs::OpenOptions::new().write(true).open(&third).unwrap().set_modified(SystemTime::now()).unwrap();
    h.engine.rescan(None).unwrap();
    wait_until("the edit to be seen", Duration::from_secs(10), || {
        h.hash_hex(h.id_of(&third)).is_none() && !h.engine.progress().scanning
    });
    h.drain_media();
    let g = h.wait_exact(1);
    assert_eq!(g[0].members.len(), 2);
    assert_eq!(ids_of(&g[0]), [h.id_of(&first), h.id_of(&second)].into_iter().collect());
}

#[test]
fn hashing_waits_while_held_and_finishes_when_released() {
    let h = harness();
    h.engine.start().unwrap();
    let data = pattern(120_000, 11);
    put(&h.media, "a.jpg", &data);
    put(&h.media, "b.jpg", &data);
    h.add(&h.media);
    h.wait_scanned(2);

    // Hold a media batch so the hasher cannot start, make the Mac too hot, then let the media pass finish.
    let BatchTasks::Batch(batch) = h.engine.next_media_batch(16).unwrap() else { panic!("expected work") };
    h.engine.set_conditions(Conditions { thermal: Thermal::Serious, ..Conditions::default() });
    let provider = FakeMediaProvider;
    let results = batch.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
    h.engine.submit_media_results(batch.batch_id, results).unwrap();

    std::thread::sleep(Duration::from_millis(1500));
    let d = h.engine.duplicates().unwrap();
    assert!(d.sets.exact.is_empty(), "nothing is hashed while the Mac is hot");
    assert!(h.all().iter().all(|id| h.hash_hex(*id).is_none()));

    h.engine.set_conditions(Conditions::default());
    h.wait_exact(1);
}

#[test]
fn hashing_waits_on_battery_when_the_setting_is_on() {
    let h = harness();
    h.engine.start().unwrap();
    h.engine.set_index_only_on_power(true).unwrap();
    let data = pattern(110_000, 13);
    put(&h.media, "a.jpg", &data);
    put(&h.media, "b.jpg", &data);
    h.add(&h.media);
    h.wait_scanned(2);
    let BatchTasks::Batch(batch) = h.engine.next_media_batch(16).unwrap() else { panic!("expected work") };
    h.engine.set_conditions(Conditions { on_battery: true, ..Conditions::default() });
    let provider = FakeMediaProvider;
    h.engine
        .submit_media_results(batch.batch_id, batch.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect())
        .unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(h.all().iter().all(|id| h.hash_hex(*id).is_none()), "nothing is hashed on battery");
    assert!(matches!(h.engine.next_media_batch(1).unwrap(), BatchTasks::Held(_) | BatchTasks::Empty));
    // Plugged in again: the work finishes.
    h.engine.set_conditions(Conditions::default());
    h.wait_exact(1);
}

#[test]
fn a_user_pause_holds_the_hasher_and_resume_continues() {
    let h = harness();
    h.engine.start().unwrap();
    let data = pattern(90_000, 12);
    put(&h.media, "a.jpg", &data);
    put(&h.media, "b.jpg", &data);
    h.add(&h.media);
    h.wait_scanned(2);
    let BatchTasks::Batch(batch) = h.engine.next_media_batch(16).unwrap() else { panic!("expected work") };
    h.engine.pause_indexing();
    let provider = FakeMediaProvider;
    h.engine
        .submit_media_results(batch.batch_id, batch.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect())
        .unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(h.engine.duplicates().unwrap().sets.exact.is_empty());
    h.engine.resume_indexing();
    h.wait_exact(1);
}

// ---- restart and crash --------------------------------------------------------------------------------------

fn put_copies(root: &Path, pairs: usize, len: usize) {
    for i in 0..pairs {
        let data = pattern(len, 100 + i as u64);
        put(root, &format!("one/f{i:03}.mov"), &data);
        put(root, &format!("two/f{i:03}-copy.mov"), &data);
    }
}

fn hash_jobs(data: &Path) -> Vec<(i64, i64)> {
    let conn =
        rusqlite::Connection::open_with_flags(data.join("library.sqlite"), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let mut stmt = conn.prepare("SELECT asset_id, state FROM jobs WHERE kind = 'hash' ORDER BY asset_id").unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(Result::unwrap).collect()
}

#[test]
fn a_restart_finishes_the_hashing_exactly_once() {
    let dir = tempfile::tempdir().unwrap();
    let (data, media) = (dir.path().join("data"), dir.path().join("media"));
    fs::create_dir_all(&media).unwrap();
    put_copies(&media, 6, 100_000);
    {
        let (engine, _) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
        engine.start().unwrap();
        engine.add_folder(AddFolderRequest { path: media.clone(), bookmark: None, volume: volume() }).unwrap();
        wait_until("scan", Duration::from_secs(20), || engine.search(&SearchQuery::default()).unwrap().len() == 12 && !engine.progress().scanning);
        // Pause before the media pass finishes, so hash jobs never start; quit.
        engine.pause_indexing();
        engine.shutdown().unwrap();
    }
    let (engine, info) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
    assert!(!info.unclean_exit);
    engine.start().unwrap();
    let h = H { dir, data: data.clone(), media, events: Arc::new(Events::default()), engine };
    h.drain_media();
    h.wait_exact(6);
    let jobs = hash_jobs(&data);
    assert_eq!(jobs.len(), 12, "one job per file, never two: {jobs:?}");
    assert!(jobs.iter().all(|(_, state)| *state == 2), "all done: {jobs:?}");
}

fn job_states(data: &Path) -> Vec<i64> {
    hash_jobs(data).into_iter().map(|(_, state)| state).collect()
}

#[test]
fn pausing_stops_a_hash_in_the_middle_of_a_big_file() {
    let dir = tempfile::tempdir().unwrap();
    let (data, media) = (dir.path().join("data"), dir.path().join("media"));
    fs::create_dir_all(&media).unwrap();
    let big = pattern(48 * 1024 * 1024, 77);
    put(&media, "a/take.mov", &big);
    put(&media, "b/take-copy.mov", &big);
    let mut c = config(&data);
    c.hash_throttle = Duration::from_millis(15); // 48 reads of 1 MiB: about 0.7 s per file
    let (engine, _) = Engine::open(c, Arc::new(Events::default())).unwrap();
    engine.start().unwrap();
    let h = H { dir, data: data.clone(), media: media.clone(), events: Arc::new(Events::default()), engine };
    h.add(&media);
    h.wait_scanned(2);
    h.drain_media();

    // Wait until both files are being read, then pause.
    wait_until("a hash in flight", Duration::from_secs(10), || job_states(&data).contains(&1));
    h.engine.pause_indexing();
    wait_until("the reads to stop", Duration::from_millis(400), || !job_states(&data).contains(&1));
    assert!(h.all().iter().all(|id| h.hash_hex(*id).is_none()), "a half-read file stores nothing");
    std::thread::sleep(Duration::from_millis(900));
    assert!(h.all().iter().all(|id| h.hash_hex(*id).is_none()), "and nothing is read while paused");
    assert!(job_states(&data).iter().all(|s| *s == 0), "the files wait in the queue: {:?}", job_states(&data));

    h.engine.resume_indexing();
    let g = h.wait_exact(1);
    assert_eq!(g[0].members.len(), 2);
    for id in h.all() {
        assert_eq!(h.hash_hex(id).unwrap(), blake_hex(&big));
    }
}

/// The child half of the kill test. It does nothing unless the parent started it.
#[test]
fn crash_child() {
    let Ok(spec) = std::env::var("SA_CRASH_CHILD") else { return };
    let (data, media) = spec.split_once('|').unwrap();
    let mut c = config(Path::new(data));
    c.hash_throttle = Duration::from_millis(25);
    let (engine, _) = Engine::open(c, Arc::new(Events::default())).unwrap();
    engine.start().unwrap();
    engine.add_folder(AddFolderRequest { path: PathBuf::from(media), bookmark: None, volume: volume() }).unwrap();
    wait_until("scan", Duration::from_secs(30), || !engine.progress().scanning && engine.search(&SearchQuery::default()).unwrap().len() >= 40);
    let provider = FakeMediaProvider;
    while let BatchTasks::Batch(b) = engine.next_media_batch(16).unwrap() {
        let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
        engine.submit_media_results(b.batch_id, results).unwrap();
    }
    println!("CHILD-WORKING");
    std::thread::sleep(Duration::from_secs(120));
}

#[test]
fn a_hash_job_survives_kill_dash_9() {
    let dir = tempfile::tempdir().unwrap();
    let (data, media) = (dir.path().join("data"), dir.path().join("media"));
    fs::create_dir_all(&media).unwrap();
    put_copies(&media, 20, 3 * 1024 * 1024);
    let before = fingerprint_tree(&media);

    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "crash_child", "--nocapture", "--test-threads=1"])
        .env("SA_CRASH_CHILD", format!("{}|{}", data.display(), media.display()))
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();

    // Wait until some, but not all, hashes are stored, then kill it without warning.
    let db = data.join("library.sqlite");
    let count = || -> i64 {
        rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .and_then(|c| c.query_row("SELECT COUNT(content_hash) FROM assets", [], |r| r.get(0)))
            .unwrap_or(0)
    };
    wait_until("the child to store a few hashes", Duration::from_secs(60), || {
        let n = count();
        assert!(n < 40, "the child finished before it could be killed");
        n >= 2
    });
    child.kill().unwrap();
    child.wait().unwrap();
    let stored_before_restart = count();
    assert!((2..40).contains(&stored_before_restart), "{stored_before_restart}");

    // Reopen: the library recovers, the interrupted work is redone, and nothing is doubled.
    let (engine, info) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
    assert!(info.unclean_exit);
    assert!(info.database_problem.is_none(), "{:?}", info.database_problem);
    engine.start().unwrap();
    let h = H { dir, data: data.clone(), media: media.clone(), events: Arc::new(Events::default()), engine };
    h.drain_media();
    let groups = h.wait_exact(20);
    assert!(groups.iter().all(|g| g.members.len() == 2));
    for id in h.all() {
        let p = h.path_of(id);
        assert_eq!(h.hash_hex(id).unwrap(), blake_hex(&fs::read(&p).unwrap()), "{p:?}");
    }
    let jobs = hash_jobs(&data);
    assert_eq!(jobs.len(), 40, "one job per file");
    assert!(jobs.iter().all(|(_, state)| *state == 2));
    assert_eq!(fingerprint_tree(&media), before, "the kill left every file as it was");
}

// ---- near duplicates (A2) --------------------------------------------------------------------------------------

const P: u64 = 0x5555_5555_5555_5555;
const D: u64 = 0x0F0F_0F0F_0F0F_0F0F;

fn hashed(name: &str, p: u64, d: u64) -> (String, Vec<u8>) {
    // The text differs per file, so no two of these are byte-identical; the fake reads the hashes out of it.
    (name.to_string(), format!("p={p} d={d} {name}").into_bytes())
}

#[test]
fn look_alike_pictures_and_videos_are_grouped_apart_from_exact_copies() {
    let h = harness();
    h.engine.start().unwrap();
    let files = [
        hashed("shoot/orig.jpg", P, D),
        hashed("shoot/resized.jpg", P ^ 0b101, D ^ 0b1100),
        hashed("export/recompressed.jpg", P ^ (1 << 40), D),
        hashed("shoot/other.jpg", !P, !D),
        hashed("shoot/black.jpg", 0, 0),
        hashed("shoot/black2.jpg", 0, 0),
        hashed("clips/take1.mov", P, D),
        hashed("clips/take1-small.mov", P ^ 0b11, D),
        hashed("clips/take2.mov", !P, !D),
    ];
    for (name, bytes) in &files {
        put(&h.media, name, bytes);
    }
    // Two byte-identical pictures: an exact group, not a similar one.
    let twin = hashed("shoot/twin.jpg", 0x1234_5678_9ABC_DEF1, 0xFEDC_BA98_7654_3210).1;
    put(&h.media, "a/twin1.jpg", &twin);
    put(&h.media, "b/twin2.jpg", &twin);
    h.add(&h.media);
    h.wait_scanned(11);

    // The browse pass comes first: no hashing work is handed out until the thumbnails are done.
    assert_eq!(h.drain_perceptual(), 0);
    h.drain_media();
    wait_until("the picture jobs", Duration::from_secs(5), || h.engine.progress().dedupe_remaining >= 10);
    assert_eq!(h.drain_perceptual(), 11);

    // The byte-identical pair is compared in full first; only then are the look-alikes sorted out.
    wait_until("the twin pair", Duration::from_secs(10), || {
        h.engine.duplicates().is_ok_and(|d| d.sets.exact.len() == 1 && d.hash_remaining == 0)
    });
    let d = h.engine.duplicates().unwrap();
    let id = |name: &str| h.id_of(&h.media.join(name));
    let similar: BTreeSet<BTreeSet<i64>> = d.sets.similar.iter().map(ids_of).collect();
    let want_pictures: BTreeSet<i64> = ["shoot/orig.jpg", "shoot/resized.jpg", "export/recompressed.jpg"].map(id).into_iter().collect();
    let want_videos: BTreeSet<i64> = ["clips/take1.mov", "clips/take1-small.mov"].map(id).into_iter().collect();
    assert_eq!(similar, [want_pictures, want_videos].into_iter().collect(), "{:?}", d.sets.similar);
    assert!(d.sets.similar.iter().all(|g| g.kind == DuplicateKind::Similar && g.members[0].suggested_keep));
    // The flat pictures never match each other, and the byte-identical pair is exact only.
    assert!(d.sets.similar.iter().all(|g| !ids_of(g).contains(&id("shoot/black.jpg"))));
    assert!(d.sets.similar.iter().all(|g| !ids_of(g).contains(&id("a/twin1.jpg"))));
}

#[test]
fn an_edited_picture_loses_its_hash_and_gets_a_new_one() {
    let h = harness();
    h.engine.start().unwrap();
    let a = put(&h.media, "a.jpg", &hashed("a", P, D).1);
    put(&h.media, "b.jpg", &hashed("b", P ^ 1, D).1);
    h.add(&h.media);
    h.wait_scanned(2);
    h.drain_media();
    wait_until("jobs", Duration::from_secs(5), || h.engine.progress().dedupe_remaining >= 2);
    h.drain_perceptual();
    assert_eq!(h.engine.duplicates().unwrap().sets.similar.len(), 1);

    // Replace a.jpg with a completely different picture.
    fs::write(&a, hashed("a", !P, !D).1).unwrap();
    fs::OpenOptions::new().write(true).open(&a).unwrap().set_modified(SystemTime::now()).unwrap();
    h.engine.rescan(None).unwrap();
    wait_until("the edit to be seen", Duration::from_secs(10), || {
        h.engine.duplicates().is_ok_and(|d| d.sets.similar.is_empty()) && !h.engine.progress().scanning
    });
    h.drain_media();
    wait_until("a new job", Duration::from_secs(5), || h.engine.progress().dedupe_remaining >= 1);
    assert_eq!(h.drain_perceptual(), 1, "only the edited file is hashed again");
    assert!(h.engine.duplicates().unwrap().sets.similar.is_empty());
}

// ---- cleanup (A3) ----------------------------------------------------------------------------------------------

struct Trio {
    h: H,
    ids: Vec<i64>,
    paths: Vec<PathBuf>,
    key: String,
}

/// Three identical files and one unrelated file, hashed and grouped.
fn trio() -> Trio {
    let h = harness();
    h.engine.start().unwrap();
    let data = pattern(180_000, 21);
    let paths = vec![
        put(&h.media, "keep/original.jpg", &data),
        put(&h.media, "backup/copy1.jpg", &data),
        put(&h.media, "backup/copy2.jpg", &data),
    ];
    put(&h.media, "solo.jpg", &pattern(50_000, 22));
    h.add(&h.media);
    h.wait_scanned(4);
    h.drain_media();
    let g = h.wait_exact(1);
    let ids: Vec<i64> = paths.iter().map(|p| h.id_of(p)).collect();
    Trio { key: g[0].key.clone(), h, ids, paths }
}

fn pretend_trash(p: &Path, trash: &Path) {
    fs::create_dir_all(trash).unwrap();
    fs::rename(p, trash.join(p.file_name().unwrap())).unwrap();
}

fn refused<T: std::fmt::Debug>(r: sa_core::Result<T>) -> String {
    match r {
        Err(Error::Refused(m)) => m,
        other => panic!("expected a refusal, got {other:?}"),
    }
}

#[test]
fn cleanup_follows_review_then_confirm_then_trash() {
    let t = trio();
    let e = &t.h.engine;
    // Organize the copies we will remove: their work must survive on the copy that stays.
    e.set_rating(&[AssetId(t.ids[1])], 4).unwrap();
    e.add_tags(&[AssetId(t.ids[1])], &["client".to_string()]).unwrap();
    let col = e.create_collection("Delivery").unwrap();
    e.add_to_collection(col, &[AssetId(t.ids[2])]).unwrap();
    let keeper = t.h.engine.duplicates().unwrap().sets.exact[0].members[0].asset_id;
    let remove: Vec<AssetId> = t.ids.iter().copied().filter(|i| *i != keeper).map(AssetId).collect();

    // Review: nothing moves, every file is described.
    let plan = e.plan_cleanup(&t.key, &remove).unwrap();
    assert_eq!(plan.kind, DuplicateKind::Exact);
    assert_eq!(plan.remove.len(), 2);
    assert_eq!(plan.keep.len(), 1);
    assert_eq!(plan.bytes, 360_000);
    assert!(plan.remove.iter().all(|f| f.size == 180_000 && f.match_percent == 100 && f.modified_ms == 1_600_000_000_000 && f.path.starts_with('/')));
    assert!(t.paths.iter().all(|p| p.exists()), "reviewing moves nothing");

    // Confirm one of the two: only that one is approved.
    let approved = e.approve_cleanup(&plan.token, &[remove[0]]).unwrap();
    assert_eq!(approved.len(), 1);
    assert_eq!(approved[0].asset_id, remove[0].0);
    assert!(approved[0].path.exists(), "the guard approves; it never moves");

    // The Swift side moves it to the Trash and reports back.
    let trash = t.h.dir.path().join("Trash");
    pretend_trash(&approved[0].path, &trash);
    let done = e.cleanup_done(&plan.token, &[remove[0]]).unwrap();
    assert_eq!((done.removed, done.bytes), (1, 180_000));

    // Exactly that record is gone; the other copy and the keeper are untouched.
    let left: BTreeSet<i64> = t.h.all().into_iter().collect();
    assert!(!left.contains(&remove[0].0));
    assert!(left.contains(&remove[1].0) && left.contains(&keeper));
    assert_eq!(left.len(), 3);
    assert_eq!(t.paths.iter().filter(|p| p.exists()).count(), 2);

    // What the removed copy carried is now on the keeper.
    let detail = e.asset_detail(AssetId(keeper)).unwrap();
    let removed_had_it = remove[0].0 == t.ids[1];
    if removed_had_it {
        assert_eq!(detail.summary.rating, 4);
        assert_eq!(detail.tags, vec!["client".to_string()]);
        let q = SearchQuery { text: Some("client".into()), ..SearchQuery::default() };
        assert!(e.search(&q).unwrap().contains(&keeper));
    } else {
        assert_eq!(e.collections_of(AssetId(keeper)).unwrap(), vec![col]);
    }
    // The group is now a pair.
    t.h.wait_exact(1);
    assert_eq!(t.h.engine.duplicates().unwrap().sets.exact[0].members.len(), 2);
}

#[test]
fn the_guard_refuses_everything_that_was_not_confirmed() {
    let t = trio();
    let e = &t.h.engine;
    let g = e.duplicates().unwrap().sets.exact[0].clone();
    let keeper = g.members[0].asset_id;
    let others: Vec<AssetId> = g.members[1..].iter().map(|m| AssetId(m.asset_id)).collect();

    // Choosing nothing, everything, or a file from somewhere else is refused before any review exists.
    assert!(matches!(e.plan_cleanup(&t.key, &[]), Err(Error::Invalid(_))));
    let all: Vec<AssetId> = g.members.iter().map(|m| AssetId(m.asset_id)).collect();
    assert!(refused(e.plan_cleanup(&t.key, &all)).contains("Keep at least one copy"));
    let solo = t.h.id_of(&t.h.media.join("solo.jpg"));
    refused(e.plan_cleanup(&t.key, &[AssetId(solo)]));
    assert!(matches!(e.plan_cleanup("x:nope", &others), Err(Error::NotFound(_))));

    let plan = e.plan_cleanup(&t.key, &others[..1]).unwrap();
    // The keeper is not in the review, so it cannot be approved; neither can an unrelated file.
    refused(e.approve_cleanup(&plan.token, &[AssetId(keeper)]));
    refused(e.approve_cleanup(&plan.token, &[AssetId(solo)]));
    refused(e.approve_cleanup(&plan.token, &[others[0], AssetId(keeper)]));
    assert!(matches!(e.approve_cleanup(&plan.token, &[]), Err(Error::Invalid(_))));
    refused(e.approve_cleanup("plan-unknown", &others[..1]));
    // Nothing was approved by any of that, so nothing can be reported as trashed.
    let nothing = e.cleanup_done(&plan.token, &[others[0]]);
    refused(nothing);
    assert!(t.paths.iter().all(|p| p.exists()));
    assert_eq!(t.h.all().len(), 4, "no record was removed");

    // A review can be used once.
    let plan = e.plan_cleanup(&t.key, &others[..1]).unwrap();
    e.approve_cleanup(&plan.token, &others[..1]).unwrap();
    assert!(refused(e.approve_cleanup(&plan.token, &others[..1])).contains("already used"));

    // Cancelling forgets it.
    let plan = e.plan_cleanup(&t.key, &others[1..]).unwrap();
    e.cancel_cleanup(&plan.token);
    refused(e.approve_cleanup(&plan.token, &others[1..]));
}

#[test]
fn cleanup_done_ignores_files_that_were_not_approved() {
    let t = trio();
    let e = &t.h.engine;
    let g = e.duplicates().unwrap().sets.exact[0].clone();
    let keeper = AssetId(g.members[0].asset_id);
    let (a, b) = (AssetId(g.members[1].asset_id), AssetId(g.members[2].asset_id));
    let plan = e.plan_cleanup(&t.key, &[a, b]).unwrap();
    let approved = e.approve_cleanup(&plan.token, &[a]).unwrap();
    pretend_trash(&approved[0].path, &t.h.dir.path().join("Trash"));
    // The caller also claims the keeper and the other copy were trashed. Only the approved one counts.
    let done = e.cleanup_done(&plan.token, &[a, b, keeper]).unwrap();
    assert_eq!(done.removed, 1);
    let left: BTreeSet<i64> = t.h.all().into_iter().collect();
    assert!(left.contains(&keeper.0) && left.contains(&b.0) && !left.contains(&a.0));
}

#[test]
fn a_file_changed_since_review_is_refused() {
    for how in ["edited", "touched", "replaced by a link", "deleted", "keeper gone"] {
        let t = trio();
        let e = &t.h.engine;
        let g = e.duplicates().unwrap().sets.exact[0].clone();
        let by_id = |id: i64| t.paths[t.ids.iter().position(|i| *i == id).unwrap()].clone();
        let victim = g.members[1].asset_id;
        let victim_path = by_id(victim);
        let remove = [AssetId(victim)];
        let plan = e.plan_cleanup(&t.key, &remove).unwrap();

        match how {
            "edited" => {
                let mut bytes = fs::read(&victim_path).unwrap();
                bytes[100] ^= 1; // between the samples: size and quick hash unchanged, so the time must catch it
                fs::write(&victim_path, bytes).unwrap();
            }
            "touched" => {
                fs::OpenOptions::new().write(true).open(&victim_path).unwrap().set_modified(SystemTime::now()).unwrap();
            }
            "replaced by a link" => {
                fs::remove_file(&victim_path).unwrap();
                std::os::unix::fs::symlink(&t.paths[0], &victim_path).unwrap();
            }
            "deleted" => fs::remove_file(&victim_path).unwrap(),
            _ => {
                // The two other copies both disappear: the one that was to stay is gone, so this would lose the file.
                for p in &t.paths {
                    if *p != victim_path {
                        fs::remove_file(p).unwrap();
                    }
                }
            }
        }
        let why = refused(e.approve_cleanup(&plan.token, &remove));
        assert!(!why.is_empty(), "{how}");
        assert!(t.h.all().len() == 4, "{how}: no record was removed");
        if how != "deleted" && how != "keeper gone" && how != "replaced by a link" {
            assert!(victim_path.exists(), "{how}");
        }
    }
}

#[test]
fn a_file_on_a_drive_that_is_not_connected_cannot_be_reviewed() {
    let t = trio();
    let e = &t.h.engine;
    let g = e.duplicates().unwrap().sets.exact[0].clone();
    e.volume_unmounted("TEST-VOL").unwrap();
    let why = refused(e.plan_cleanup(&t.key, &[AssetId(g.members[1].asset_id)]));
    assert!(why.contains("not connected"), "{why}");
}

#[test]
fn a_plan_for_a_group_that_changed_is_not_found() {
    let t = trio();
    let e = &t.h.engine;
    let g = e.duplicates().unwrap().sets.exact[0].clone();
    // Delete two of the three copies behind the app's back and rescan: the group is gone.
    fs::remove_file(&t.paths[1]).unwrap();
    fs::remove_file(&t.paths[2]).unwrap();
    e.rescan(None).unwrap();
    wait_until("the scan", Duration::from_secs(10), || e.duplicates().is_ok_and(|d| d.sets.exact.is_empty()));
    assert!(matches!(e.plan_cleanup(&t.key, &[AssetId(g.members[1].asset_id)]), Err(Error::NotFound(_))));
}

/// `cargo test -p sa-engine --release --test duplicates -- --ignored --nocapture`
#[test]
#[ignore = "benchmark: 250,000 assets with picture hashes, 6,000 exact pairs and 6,000 look-alike pairs"]
fn bench_duplicates_page_at_250k() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    {
        let (engine, _) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
        engine.shutdown().unwrap();
    }
    let conn = rusqlite::Connection::open(data.join("library.sqlite")).unwrap();
    conn.execute_batch(
        "INSERT INTO volumes(id, uuid, name, mount_path, is_internal, is_online, last_seen_at) VALUES (1,'V','Disk','/',1,1,0);
         INSERT INTO folders(id, volume_id, rel_path, display_name, enabled, added_at) VALUES (1,1,'m','m',1,0);",
    )
    .unwrap();
    let mut seed = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let informative = |h: u64| (14..=49).contains(&h.count_ones());
    let started = Instant::now();
    conn.execute_batch("BEGIN").unwrap();
    {
        let mut asset = conn
            .prepare(
                "INSERT INTO assets(id, folder_id, rel_path, name, ext, kind, size, mtime, quick_hash, content_hash, added_at, sort_date,
                                    probe_state, duration_ms, width, height)
                 VALUES (?1, 1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?8, 1, 1, 1, ?9, 1920, 1080)",
            )
            .unwrap();
        let mut hash = conn.prepare("INSERT INTO perceptual(asset_id, slot, dhash, phash) VALUES (?1, ?2, ?3, ?4)").unwrap();
        let mut last = (0u64, 0u64);
        for i in 0..250_000i64 {
            let video = i % 10 == 9;
            let exact_pair = i % 10 < 2 && i < 60_000; // 6,000 pairs of identical files
            let size = if exact_pair { 1_000_000 + (i / 10) } else { 2_000_000 + i };
            let content = exact_pair.then(|| blake3::hash(&(i / 10).to_le_bytes()).as_bytes().to_vec());
            let quick = if exact_pair { (i / 10).to_le_bytes().repeat(2) } else { ((i + 1) << 20).to_le_bytes().repeat(2) };
            asset
                .execute(rusqlite::params![
                    i + 1,
                    format!("d{}/f{i}", i % 500),
                    format!("f{i}"),
                    if video { "mov" } else { "jpg" },
                    i64::from(video),
                    size,
                    quick,
                    content,
                    video.then_some(10_000 + i % 5_000),
                ])
                .unwrap();
            // 6,000 look-alike pairs: the second picture of a pair repeats the first with a few bits changed.
            let (mut d, mut p) = (next(), next());
            while !informative(p) || !(4..=60).contains(&d.count_ones()) {
                p = next();
                d = next();
            }
            if i % 10 == 3 && i < 60_000 {
                (d, p) = (last.0 ^ 0b101, last.1 ^ 0b1_0001);
            } else if i % 10 == 2 {
                last = (d, p);
            }
            for slot in 0..if video { 3 } else { 1 } {
                hash.execute(rusqlite::params![i + 1, slot, sa_store::dedupe::to_db(d), sa_store::dedupe::to_db(p)]).unwrap();
            }
        }
    }
    conn.execute_batch("COMMIT").unwrap();
    println!("built the library in {:?}", started.elapsed());
    drop(conn);

    let (engine, _) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
    let t = Instant::now();
    let first = engine.duplicates().unwrap();
    println!(
        "duplicates() first call: {:?}: {} exact groups, {} similar groups",
        t.elapsed(),
        first.sets.exact.len(),
        first.sets.similar.len()
    );
    let t = Instant::now();
    let _ = engine.duplicates().unwrap();
    println!("duplicates() cached: {:?}", t.elapsed());
    assert_eq!(first.sets.exact.len(), 6_000);
    assert!(first.sets.similar.len() >= 5_500, "{}", first.sets.similar.len());
}

/// A2: three pictures the fingerprints call copies, one of which shows something else by meaning. Before the pictures
/// are described the group stands as found; once they are, the one that does not look like the others leaves it.
#[test]
fn a_group_of_similar_copies_is_confirmed_by_meaning() {
    let h = harness();
    h.engine.start().unwrap();
    // (The fake model reads `topic=` words; "beach" and "dog" are on different axes of its 16.)
    put(&h.media, "a.jpg", format!("p={P} d={D} topic=beach a").as_bytes());
    put(&h.media, "b.jpg", format!("p={P} d={D} topic=beach b").as_bytes());
    put(&h.media, "c.jpg", format!("p={P} d={D} topic=dog c").as_bytes());
    h.add(&h.media);
    h.wait_scanned(3);
    h.drain_media();
    wait_until("the picture jobs", Duration::from_secs(5), || h.engine.progress().dedupe_remaining >= 3);
    h.drain_perceptual();
    let id = |name: &str| h.id_of(&h.media.join(name));
    let group = || h.engine.duplicates().unwrap().sets.similar.first().map(ids_of).unwrap_or_default();
    wait_until("the look-alike group", Duration::from_secs(10), || group().len() == 3);

    let model = sa_store::embeddings::ModelConfig {
        id: "fake-16-v1".into(),
        model: "fake".into(),
        version: "1".into(),
        modality: "image".into(),
        dims: 16,
        preprocessing: "test".into(),
    };
    h.engine.set_embedding_config(model, Calibration { min_match: 0.5, band: 0.1, copy_match: Some(0.9) }).unwrap();
    assert_eq!(group().len(), 3, "not described yet: the group stands as the fingerprints found it");
    let provider = FakeEmbeddingProvider::new(16);
    while let EmbeddingTasks::Batch(b) = h.engine.next_embedding_batch(16).unwrap() {
        let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
        h.engine.submit_embedding_results(b.batch_id, results).unwrap();
    }
    let want: BTreeSet<i64> = [id("a.jpg"), id("b.jpg")].into_iter().collect();
    assert_eq!(group(), want, "the dog picture is not a copy of the beach pictures");

    // A model that never measured its cut-off does not confirm.
    let unmeasured = sa_store::embeddings::ModelConfig {
        id: "fake-16-v1".into(),
        model: "fake".into(),
        version: "1".into(),
        modality: "image".into(),
        dims: 16,
        preprocessing: "test".into(),
    };
    h.engine.set_embedding_config(unmeasured, Calibration { min_match: 0.5, band: 0.1, copy_match: None }).unwrap();
    assert_eq!(group().len(), 3);
}
