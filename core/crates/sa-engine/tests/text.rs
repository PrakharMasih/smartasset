#![allow(clippy::unwrap_used, clippy::field_reassign_with_default, clippy::assert_is_empty)]
//! Phase 4, S4: text in pictures. Driven with a fake reader (`FakeTextProvider`: a file "shows" every word after
//! `says=`), so these tests prove the pipeline, never the quality of Vision: what is stored, what is found, what is
//! dropped when a file changes or goes away.

use sa_core::{AssetId, FolderId, SearchQuery, SortKey};
use sa_engine::{AddFolderRequest, BatchTasks, Engine, EngineConfig, Event, EventSink, MountedVolume, TextTasks};
use sa_providers::{FakeMediaProvider, FakeTextProvider, MediaProvider, TextOutcome, TextProvider};
use sa_store::folders::AddFolderOutcome;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

const READER: &str = "fake-reader-v1";

#[derive(Default)]
struct Events;

impl EventSink for Events {
    fn on_event(&self, _event: Event) {}
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

struct H {
    _dir: tempfile::TempDir,
    media: PathBuf,
    engine: Engine,
}

fn harness() -> H {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    let (engine, _) = Engine::open(config(&data), Arc::new(Events)).unwrap();
    engine.start().unwrap();
    H { _dir: dir, media, engine }
}

fn put(root: &Path, rel: &str, text: &str, secs: u64) -> PathBuf {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, text).unwrap();
    let f = fs::OpenOptions::new().write(true).open(&p).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs)).unwrap();
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
        match self
            .engine
            .add_folder(AddFolderRequest { path: path.to_path_buf(), bookmark: Some(vec![1]), volume: volume() })
            .unwrap()
        {
            AddFolderOutcome::Added { id, .. } => id,
            other => panic!("{other:?}"),
        }
    }

    fn all(&self) -> Vec<i64> {
        self.engine.search(&SearchQuery::default()).unwrap().to_vec()
    }

    fn drain_media(&self) {
        let provider = FakeMediaProvider;
        while let BatchTasks::Batch(b) = self.engine.next_media_batch(16).unwrap() {
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_media_results(b.batch_id, results).unwrap();
        }
    }

    /// The fake reader. Returns how many files it read.
    fn drain_text(&self) -> usize {
        let provider = FakeTextProvider;
        let mut n = 0;
        while let TextTasks::Batch(b) = self.engine.next_text_batch(16).unwrap() {
            n += b.tasks.len();
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_text_results(b.batch_id, results).unwrap();
        }
        n
    }

    fn id_of(&self, name: &str) -> i64 {
        self.all()
            .into_iter()
            .find(|id| self.engine.asset_detail(AssetId(*id)).unwrap().path.is_some_and(|p| p.ends_with(name)))
            .unwrap_or_else(|| panic!("{name} is not indexed"))
    }

    fn find(&self, words: &str) -> Vec<i64> {
        let mut q = SearchQuery::default();
        q.text = Some(words.into());
        q.sort.key = SortKey::Relevance;
        self.engine.search(&q).unwrap().to_vec()
    }
}

/// Three pictures: a slide that says "quarterly roadmap", a thumbnail that says "summer sale", a photo with no text.
fn library(h: &H) -> FolderId {
    put(&h.media, "slide-07.png", "says=Quarterly says=Roadmap", 1_600_000_000);
    put(&h.media, "IMG_0042.jpg", "says=SUMMER says=SALE says=50%", 1_600_000_000);
    put(&h.media, "beach.jpg", "just waves", 1_600_000_000);
    let folder = h.add(&h.media);
    wait_until("the scan", Duration::from_secs(20), || h.all().len() >= 3 && !h.engine.progress().scanning);
    h.drain_media();
    folder
}

#[test]
fn with_no_reader_nothing_is_read() {
    let h = harness();
    library(&h);
    assert!(matches!(h.engine.next_text_batch(16).unwrap(), TextTasks::Empty));
    assert!(h.find("roadmap").is_empty());
    assert_eq!(h.engine.text_status().unwrap().reader, None);
}

#[test]
fn a_picture_is_found_by_the_words_it_shows() {
    let h = harness();
    library(&h);
    h.engine.set_text_reader(READER);
    assert_eq!(h.drain_text(), 3, "every picture is read once, including the one without text");
    let status = h.engine.text_status().unwrap();
    assert_eq!((status.read, status.remaining), (3, 0));
    assert_eq!(h.find("roadmap"), vec![h.id_of("slide-07.png")]);
    assert_eq!(h.find("summer sale"), vec![h.id_of("IMG_0042.jpg")], "every word must match, case-insensitively");
    assert_eq!(h.find("sum"), vec![h.id_of("IMG_0042.jpg")], "words are prefixes, as in the rest of search");
    assert_eq!(h.engine.text_of(AssetId(h.id_of("beach.jpg"))).unwrap().as_deref(), Some(""));
    assert!(h.drain_text() == 0, "nothing is read twice");
}

#[test]
fn a_file_found_by_its_name_and_its_text_keeps_one_place() {
    let h = harness();
    put(&h.media, "roadmap.png", "says=roadmap", 1_600_000_000);
    h.add(&h.media);
    wait_until("the scan", Duration::from_secs(20), || h.all().len() == 1 && !h.engine.progress().scanning);
    h.drain_media();
    h.engine.set_text_reader(READER);
    h.drain_text();
    assert_eq!(h.find("roadmap").len(), 1, "once, not once per table");
}

#[test]
fn an_edited_file_is_read_again_and_its_old_words_are_gone() {
    let h = harness();
    library(&h);
    h.engine.set_text_reader(READER);
    h.drain_text();
    put(&h.media, "slide-07.png", "says=Hiring says=Plan", 1_700_000_000);
    h.engine.rescan(None).unwrap();
    wait_until("the change to be seen", Duration::from_secs(10), || {
        let p = h.engine.progress();
        !p.scanning && p.media_remaining > 0
    });
    h.drain_media();
    assert_eq!(h.drain_text(), 1, "only the changed file is read again");
    assert!(h.find("roadmap").is_empty(), "the old words are gone");
    assert_eq!(h.find("hiring"), vec![h.id_of("slide-07.png")]);
}

#[test]
fn a_result_for_a_file_that_changed_meanwhile_is_thrown_away() {
    let h = harness();
    library(&h);
    h.engine.set_text_reader(READER);
    let TextTasks::Batch(b) = h.engine.next_text_batch(16).unwrap() else { panic!("no batch") };
    put(&h.media, "slide-07.png", "says=Other", 1_700_000_000);
    h.engine.rescan(None).unwrap();
    wait_until("the change to be seen", Duration::from_secs(10), || h.engine.progress().media_remaining > 0);
    let results = b.tasks.iter().map(|t| (t.job_id, TextOutcome::Done("stale words".into()))).collect();
    let report = h.engine.submit_text_results(b.batch_id, results).unwrap();
    assert!(report.discarded >= 1, "{report:?}");
    assert!(h.find("stale").iter().all(|id| *id != h.id_of("slide-07.png")));
}

#[test]
fn removing_the_folder_removes_its_text_from_search() {
    let h = harness();
    let folder = library(&h);
    h.engine.set_text_reader(READER);
    h.drain_text();
    assert_eq!(h.find("roadmap").len(), 1);
    h.engine.remove_folder(folder).unwrap();
    assert!(h.find("roadmap").is_empty());
    assert_eq!(h.engine.text_status().unwrap().read, 0);
}
