#![allow(clippy::unwrap_used, clippy::too_many_lines, clippy::assert_is_empty, clippy::cast_possible_truncation, clippy::field_reassign_with_default)]
//! Phase 4: vectors for search by meaning. Driven with a fake model (`FakeEmbeddingProvider`), so these tests prove
//! the pipeline, never the quality of a real model: what is stored, what is found, what survives a restart.

use parking_lot::Mutex;
use sa_core::{AssetId, FolderId, SearchQuery, SortKey};
use sa_engine::{
    AddFolderRequest, BatchTasks, Calibration, Engine, EngineConfig, EmbeddingTasks, Event, EventSink, MountedVolume,
};
use sa_providers::{
    EmbeddingOutcome, EmbeddingProvider, FakeEmbeddingProvider, FakeMediaProvider, MediaProvider, fake_text_vector,
};
use sa_store::embeddings::ModelConfig;
use sa_store::folders::AddFolderOutcome;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

const DIMS: usize = 16;
/// The fake model's similarities are 1 for a file about the question and 0 otherwise.
const CAL: Calibration = Calibration { min_match: 0.5, band: 0.1, copy_match: None };

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

fn model() -> ModelConfig {
    ModelConfig {
        id: "fake-16-v1".into(),
        model: "fake".into(),
        version: "1".into(),
        modality: "image".into(),
        dims: DIMS as u32,
        preprocessing: "test".into(),
    }
}

struct H {
    _dir: tempfile::TempDir,
    data: PathBuf,
    media: PathBuf,
    engine: Engine,
}

fn harness() -> H {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    let (engine, _) = Engine::open(config(&data), Arc::new(Events::default())).unwrap();
    engine.start().unwrap();
    H { _dir: dir, data, media, engine }
}

fn put(root: &Path, rel: &str, text: &str) -> PathBuf {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, text).unwrap();
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

    fn wait_scanned(&self, expect: usize) {
        wait_until("the scan", Duration::from_secs(20), || self.all().len() >= expect && !self.engine.progress().scanning);
    }

    fn drain_media(&self) {
        let provider = FakeMediaProvider;
        while let BatchTasks::Batch(b) = self.engine.next_media_batch(16).unwrap() {
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_media_results(b.batch_id, results).unwrap();
        }
    }

    /// The fake model worker. Returns how many files it embedded.
    fn drain_embeddings(&self) -> usize {
        let provider = FakeEmbeddingProvider::new(DIMS);
        let mut n = 0;
        while let EmbeddingTasks::Batch(b) = self.engine.next_embedding_batch(16).unwrap() {
            n += b.tasks.len();
            let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
            self.engine.submit_embedding_results(b.batch_id, results).unwrap();
        }
        n
    }

    fn id_of(&self, name: &str) -> i64 {
        self.all()
            .into_iter()
            .find(|id| self.engine.asset_detail(AssetId(*id)).unwrap().path.is_some_and(|p| p.ends_with(name)))
            .unwrap_or_else(|| panic!("{name} is not indexed"))
    }

    /// A relevance-ordered query: the words, and the vector the fake model gives them.
    fn ask(&self, words: &str, meaning: &str) -> Vec<i64> {
        let mut q = SearchQuery::default();
        q.text = Some(words.into());
        q.sort.key = SortKey::Relevance;
        self.engine.search_hybrid(&q, &fake_text_vector(DIMS, meaning)).unwrap().to_vec()
    }
}

fn library(h: &H) {
    put(&h.media, "sunset.jpg", "topic=beach topic=evening");
    put(&h.media, "puppy.jpg", "topic=dog");
    put(&h.media, "pines.jpg", "topic=forest");
    h.add(&h.media);
    h.wait_scanned(3);
    h.drain_media();
}

#[test]
fn with_no_model_nothing_is_embedded_and_search_is_the_keyword_search() {
    let h = harness();
    library(&h);
    assert!(matches!(h.engine.next_embedding_batch(16).unwrap(), EmbeddingTasks::Empty));
    let status = h.engine.embedding_status().unwrap();
    assert_eq!((status.config, status.with_vectors, status.remaining), (None, 0, 0));
    // Same answer as the plain search, even with a vector supplied.
    let mut q = SearchQuery::default();
    q.text = Some("puppy".into());
    q.sort.key = SortKey::Relevance;
    let plain = h.engine.search(&q).unwrap();
    let hybrid = h.engine.search_hybrid(&q, &fake_text_vector(DIMS, "dog")).unwrap();
    assert_eq!(*plain, *hybrid);
    assert_eq!(plain.len(), 1);
}

#[test]
fn every_picture_gets_a_vector_and_a_question_finds_it_by_meaning() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    assert_eq!(h.drain_embeddings(), 3, "one vector job per picture");
    let status = h.engine.embedding_status().unwrap();
    assert_eq!((status.with_vectors, status.remaining), (3, 0));

    // "shoreline" is in no file name, tag or note: only the meaning can find the sunset.
    let found = h.ask("shoreline", "beach");
    assert_eq!(found, vec![h.id_of("sunset.jpg")], "the beach picture, and not the dog or the trees");
    // A question about nothing in the library finds nothing rather than the least-bad pictures.
    assert!(h.ask("spaceship", "rocket").is_empty());
}

#[test]
fn a_file_found_by_its_name_and_its_meaning_comes_before_one_found_by_meaning_alone() {
    let h = harness();
    put(&h.media, "other.jpg", "topic=beach");
    put(&h.media, "beach-day.jpg", "topic=beach");
    h.add(&h.media);
    h.wait_scanned(2);
    h.drain_media();
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let found = h.ask("beach", "beach");
    assert_eq!(found, vec![h.id_of("beach-day.jpg"), h.id_of("other.jpg")]);
}

#[test]
fn filters_still_decide_who_can_be_answered() {
    let h = harness();
    let (a, b) = (h.media.join("a"), h.media.join("b"));
    put(&a, "one.jpg", "topic=beach");
    put(&b, "two.jpg", "topic=beach");
    let folder_a = h.add(&a);
    h.add(&b);
    h.wait_scanned(2);
    h.drain_media();
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let mut q = SearchQuery::default();
    q.text = Some("shoreline".into());
    q.sort.key = SortKey::Relevance;
    q.filters.folder_ids = vec![folder_a.0];
    let found = h.engine.search_hybrid(&q, &fake_text_vector(DIMS, "beach")).unwrap();
    assert_eq!(*found, vec![h.id_of("one.jpg")], "only the folder that was asked for");
}

#[test]
fn another_sort_order_is_respected_and_vectors_do_not_reorder_it() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let mut q = SearchQuery::default();
    q.text = Some("puppy".into());
    q.sort.key = SortKey::Name;
    let plain = h.engine.search(&q).unwrap();
    let hybrid = h.engine.search_hybrid(&q, &fake_text_vector(DIMS, "beach")).unwrap();
    assert_eq!(*plain, *hybrid, "an explicit order is the keyword search in that order");
}

#[test]
fn an_edited_file_is_embedded_again_and_the_old_meaning_is_gone() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    assert_eq!(h.ask("shoreline", "beach"), vec![h.id_of("sunset.jpg")]);
    // Look at the index once so it is in memory, then change the file.
    put(&h.media, "sunset.jpg", "topic=hawk");
    h.engine.rescan(None).unwrap();
    wait_until("the change to be seen", Duration::from_secs(10), || {
        let p = h.engine.progress();
        !p.scanning && p.media_remaining > 0
    });
    h.drain_media();
    assert!(h.drain_embeddings() >= 1, "the changed file was queued again");
    assert!(h.ask("shoreline", "beach").is_empty(), "nothing looks like a beach any more");
    assert_eq!(h.ask("raptor", "hawk"), vec![h.id_of("sunset.jpg")], "the new meaning is what is found");
}

#[test]
fn a_bad_answer_fails_its_file_and_not_the_batch() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    let EmbeddingTasks::Batch(b) = h.engine.next_embedding_batch(16).unwrap() else { panic!("no batch") };
    assert_eq!(b.tasks.len(), 3);
    let good = FakeEmbeddingProvider::new(DIMS);
    let results = b
        .tasks
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let outcome = match i {
                0 => EmbeddingOutcome::Done { vectors: vec![vec![0.0; DIMS]], times_ms: vec![] },
                1 => EmbeddingOutcome::Done { vectors: vec![vec![f32::NAN; DIMS]], times_ms: vec![] },
                _ => good.process(t),
            };
            (t.job_id, outcome)
        })
        .collect();
    let report = h.engine.submit_embedding_results(b.batch_id, results).unwrap();
    assert_eq!(report.committed, 1, "the good file was stored");
    assert_eq!(report.failed + report.retried, 2, "the two bad ones failed alone: {report:?}");
    assert_eq!(h.engine.embedding_status().unwrap().with_vectors, 1);
}

#[test]
fn a_wrong_length_is_refused() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    let EmbeddingTasks::Batch(b) = h.engine.next_embedding_batch(16).unwrap() else { panic!("no batch") };
    let results = b.tasks.iter().map(|t| (t.job_id, EmbeddingOutcome::Done { vectors: vec![vec![1.0; DIMS + 1]], times_ms: vec![] })).collect();
    let report = h.engine.submit_embedding_results(b.batch_id, results).unwrap();
    assert_eq!(report.committed, 0);
    assert_eq!(h.engine.embedding_status().unwrap().with_vectors, 0);
}

#[test]
fn vectors_survive_a_restart_and_the_index_is_rebuilt_without_the_model() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let before = h.ask("shoreline", "beach");
    assert_eq!(before.len(), 1);
    h.engine.shutdown().unwrap();

    let (engine, info) = Engine::open(config(&h.data), Arc::new(Events::default())).unwrap();
    assert!(!info.unclean_exit);
    engine.start().unwrap();
    engine.set_embedding_config(model(), CAL).unwrap();
    // Nothing is asked of the model again: every picture already has its vector.
    assert!(matches!(engine.next_embedding_batch(16).unwrap(), EmbeddingTasks::Empty));
    let mut q = SearchQuery::default();
    q.text = Some("shoreline".into());
    q.sort.key = SortKey::Relevance;
    let after = engine.search_hybrid(&q, &fake_text_vector(DIMS, "beach")).unwrap();
    assert_eq!(*after, before);
}

#[test]
fn a_second_model_does_not_see_the_first_ones_vectors() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let mut other = model();
    other.id = "other-16-v1".into();
    other.model = "another model".into();
    h.engine.set_embedding_config(other, CAL).unwrap();
    assert!(h.ask("shoreline", "beach").is_empty(), "the new configuration has no vectors yet");
    assert_eq!(h.drain_embeddings(), 3, "every picture is embedded again for it");
    assert_eq!(h.ask("shoreline", "beach").len(), 1);
}

#[test]
fn removing_the_model_returns_to_keyword_search() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    h.engine.clear_embedding_config();
    assert!(h.ask("shoreline", "beach").is_empty());
    assert!(matches!(h.engine.next_embedding_batch(16).unwrap(), EmbeddingTasks::Empty));
}

#[test]
fn a_question_whose_best_match_is_below_the_models_minimum_is_not_answered_by_meaning() {
    let h = harness();
    library(&h);
    // "sunset" is about two things (beach and evening), so a question about the beach alone matches it at 0.71.
    h.engine.set_embedding_config(model(), Calibration { min_match: 0.9, band: 0.1, copy_match: None }).unwrap();
    h.drain_embeddings();
    assert!(h.ask("shoreline", "beach").is_empty(), "0.71 is below a minimum of 0.9");
    h.engine.set_embedding_config(model(), Calibration { min_match: 0.7, band: 0.1, copy_match: None }).unwrap();
    assert_eq!(h.ask("shoreline", "beach"), vec![h.id_of("sunset.jpg")], "and above a minimum of 0.7");
}

#[test]
fn files_within_the_band_of_the_best_match_are_kept_and_the_rest_are_left_out() {
    let h = harness();
    put(&h.media, "both.jpg", "topic=beach topic=dog");
    put(&h.media, "beach-only.jpg", "topic=beach");
    put(&h.media, "dog-only.jpg", "topic=dog");
    h.add(&h.media);
    h.wait_scanned(3);
    h.drain_media();
    h.engine.set_embedding_config(model(), Calibration { min_match: 0.5, band: 0.0, copy_match: None }).unwrap();
    h.drain_embeddings();
    assert_eq!(h.ask("shoreline", "beach"), vec![h.id_of("beach-only.jpg")], "a zero band keeps only the best (1.0), not the 0.71 one");
    h.engine.set_embedding_config(model(), Calibration { min_match: 0.5, band: 0.5, copy_match: None }).unwrap();
    let wide = h.ask("shoreline", "beach");
    assert_eq!(wide.len(), 2);
    assert_eq!(wide[0], h.id_of("beach-only.jpg"), "the best match comes first");
}

/// The same model with a new picture preparation (e.g. a larger picture budget): its questions still compare with the
/// old vectors, so search keeps finding every file while the library is described again, and the old vectors are
/// deleted once every file has a new one.
#[test]
fn while_the_library_is_described_again_search_still_finds_every_file() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let sunset = h.id_of("sunset.jpg");
    let puppy = h.id_of("puppy.jpg");
    assert_eq!(h.ask("shoreline", "beach"), vec![sunset]);

    let mut bigger = model();
    bigger.id = "fake-16-v2".into();
    bigger.preprocessing = "test, more detail".into();
    h.engine.set_embedding_config(bigger.clone(), CAL).unwrap();
    assert_eq!(h.ask("shoreline", "beach"), vec![sunset], "answered from the old vectors before any new one exists");
    assert_eq!(h.ask("kennel", "dog"), vec![puppy]);

    // One file at a time: every file stays findable, from whichever vectors describe it.
    let provider = FakeEmbeddingProvider::new(DIMS);
    let EmbeddingTasks::Batch(b) = h.engine.next_embedding_batch(1).unwrap() else { panic!("no batch") };
    assert_eq!(b.tasks.len(), 1);
    let results = b.tasks.iter().map(|t| (t.job_id, provider.process(t))).collect();
    h.engine.submit_embedding_results(b.batch_id, results).unwrap();
    assert_eq!(h.ask("shoreline", "beach"), vec![sunset]);
    assert_eq!(h.ask("kennel", "dog"), vec![puppy]);
    let raw = h.engine.semantic_hits(&fake_text_vector(DIMS, "dog"), 10).unwrap();
    assert_eq!(raw.count, 3, "each file is scored once, never from both configurations");
    // The re-described file's old vector is already gone; a fresh index (as after a restart) still finds everything.
    h.engine.set_embedding_config(model(), CAL).unwrap();
    assert_eq!(h.engine.embedding_status().unwrap().with_vectors, 2, "the old configuration lost the re-described file");
    h.engine.set_embedding_config(bigger.clone(), CAL).unwrap();
    assert_eq!(h.ask("shoreline", "beach"), vec![sunset]);
    assert_eq!(h.ask("kennel", "dog"), vec![puppy]);

    h.drain_embeddings();
    assert_eq!(h.engine.embedding_status().unwrap().with_vectors, 3);
    assert_eq!(h.ask("shoreline", "beach"), vec![sunset]);
    // Every file has a new vector, so the old configuration was deleted with its vectors.
    h.engine.set_embedding_config(model(), CAL).unwrap();
    assert_eq!(h.engine.embedding_status().unwrap().with_vectors, 0, "the replaced vectors were removed");
}

/// S7: a file's own description is the question. Pictures about the same thing come first, the file itself is left
/// out, filters still apply, and a file that has no description yet is not mistaken for one nothing resembles.
#[test]
fn more_like_this_finds_files_that_look_like_one_without_returning_it() {
    let h = harness();
    // (The fake model has 16 axes: these words land on different ones.)
    put(&h.media, "sunset.jpg", "topic=beach topic=night");
    put(&h.media, "shore.jpg", "topic=beach");
    put(&h.media, "puppy.jpg", "topic=dog");
    put(&h.media, "pines.jpg", "topic=forest");
    h.add(&h.media);
    h.wait_scanned(4);
    h.drain_media();
    let sunset = AssetId(h.id_of("sunset.jpg"));
    assert!(h.engine.search_similar(sunset, &SearchQuery::default(), 10).unwrap().is_none(), "no model, no answer");
    h.engine.set_embedding_config(model(), CAL).unwrap();
    assert!(h.engine.search_similar(sunset, &SearchQuery::default(), 10).unwrap().is_none(), "not described yet");
    h.drain_embeddings();
    let like = h.engine.search_similar(sunset, &SearchQuery::default(), 10).unwrap().unwrap();
    assert_eq!(like[0], h.id_of("shore.jpg"), "the other beach picture is the closest");
    assert!(!like.contains(&sunset.0), "the file is never its own answer");
    assert_eq!(like.len(), 3, "everything else, ranked, with no cut-off");
    // Only pictures from a filter's folder or kind may be answered: here an impossible filter leaves nothing.
    let mut videos = SearchQuery::default();
    videos.filters.kinds = vec![sa_core::MediaKind::Video];
    assert!(h.engine.search_similar(sunset, &videos, 10).unwrap().unwrap().is_empty());
}

/// A relevance-ordered search for these words.
fn asked(words: &str) -> SearchQuery {
    let mut q = SearchQuery::default();
    q.text = Some(words.into());
    q.sort.key = SortKey::Relevance;
    q
}

/// S11: a file search by meaning did not add (the question's best match is under the model's minimum) has no meaning to
/// explain, even though a vector of it exists.
#[test]
fn a_file_search_by_meaning_did_not_add_has_no_meaning_explained() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let sunset = AssetId(h.id_of("sunset.jpg"));
    // "river" is on an axis no picture is on: the best match is 0, under the minimum, so nothing is added by meaning.
    let why = h.engine.explain_match(sunset, &asked("sunset"), &fake_text_vector(DIMS, "river")).unwrap();
    assert!(why.meaning.is_none(), "{why:?}");
    assert_eq!(why.words.len(), 1, "the word in the name is still placed");
    // A question the library answers does add the file.
    assert!(h.engine.explain_match(sunset, &asked("sunset"), &fake_text_vector(DIMS, "beach")).unwrap().meaning.is_some());
}

/// S2: a video has one vector per scene and the engine knows where each is; the explanation names the closest one.
#[test]
fn a_videos_scenes_keep_their_places_and_the_best_one_is_named() {
    let h = harness();
    library(&h);
    h.engine.set_embedding_config(model(), CAL).unwrap();
    let EmbeddingTasks::Batch(b) = h.engine.next_embedding_batch(16).unwrap() else { panic!("no batch") };
    let clip = h.id_of("pines.jpg");
    let results = b
        .tasks
        .iter()
        .map(|t| {
            if t.asset_id == clip {
                // Three scenes: a forest, a beach, a dog, at 1.5 s, 12 s and 40 s.
                let vectors = ["forest", "beach", "dog"].iter().map(|w| fake_text_vector(DIMS, w)).collect();
                (t.job_id, EmbeddingOutcome::Done { vectors, times_ms: vec![1_500, 12_000, 40_000] })
            } else {
                (t.job_id, FakeEmbeddingProvider::new(DIMS).process(t))
            }
        })
        .collect();
    h.engine.submit_embedding_results(b.batch_id, results).unwrap();
    // A question about a dog finds the clip through its third scene; the moment is 40 s in.
    assert!(h.ask("anything", "dog").contains(&clip), "found through its third scene");
    let why = h.engine.explain_match(AssetId(clip), &asked("puppy"), &fake_text_vector(DIMS, "dog")).unwrap();
    let meaning = why.meaning.expect("meaning");
    assert_eq!(meaning.moment_ms, Some(40_000));
    assert_eq!(meaning.frames, 3);
    assert!(meaning.strong, "an exact match is strong: {meaning:?}");
    let beach = h.engine.explain_match(AssetId(clip), &asked("shore"), &fake_text_vector(DIMS, "beach")).unwrap();
    assert_eq!(beach.meaning.unwrap().moment_ms, Some(12_000));
    // A page of results: the clip has a moment, the picture none; and the scenes are listed in order.
    let page = vec![clip, h.id_of("puppy.jpg")];
    assert_eq!(h.engine.moments(&asked("anything"), &fake_text_vector(DIMS, "dog"), &page).unwrap(), vec![(clip, 40_000)]);
    assert_eq!(h.engine.scene_times(AssetId(clip)).unwrap(), vec![1_500, 12_000, 40_000]);
    assert!(h.engine.moments(&asked("anything"), &fake_text_vector(DIMS, "river"), &page).unwrap().is_empty(), "nothing added by meaning, no moments");
    // A picture has no place inside it.
    let picture = h.engine.explain_match(AssetId(h.id_of("puppy.jpg")), &asked("puppy"), &fake_text_vector(DIMS, "dog")).unwrap();
    assert_eq!(picture.meaning.unwrap().moment_ms, None);
}

/// S11: the words that matched are placed in the name, a tag, a note or the folder, and a word found nowhere is left out.
#[test]
fn the_explanation_places_each_typed_word() {
    let h = harness();
    put(&h.media, "sunset.jpg", "topic=beach");
    put(&h.media, "Iceland/aurora.jpg", "topic=dog");
    h.add(&h.media);
    h.wait_scanned(2);
    h.drain_media();
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    let id = h.id_of("sunset.jpg");
    h.engine.add_tags(&[AssetId(id)], &["Holiday".to_string()]).unwrap();
    h.engine.set_notes(AssetId(id), "Taken from the harbour wall just before dinner").unwrap();
    let why = h.engine.explain_match(AssetId(id), &asked("sunset holiday harbour"), &fake_text_vector(DIMS, "beach")).unwrap();
    let places: Vec<(&str, sa_search::Field)> = why.words.iter().map(|w| (w.word.as_str(), w.field)).collect();
    assert_eq!(
        places,
        vec![("sunset", sa_search::Field::Name), ("holiday", sa_search::Field::Tag), ("harbour", sa_search::Field::Note)]
    );
    // The keyword search needs every word: with one found nowhere the file was not found by words, so none is listed.
    let partial = h.engine.explain_match(AssetId(id), &asked("sunset holiday zzz"), &fake_text_vector(DIMS, "beach")).unwrap();
    assert!(partial.words.is_empty(), "{partial:?}");
    assert!(partial.meaning.is_some(), "it can still be found by meaning");
    assert_eq!(why.words[2].snippet.as_deref(), Some("Taken from the harbour wall just before dinner"));
    assert!(why.meaning.is_some());
    // A word only a folder name has.
    let aurora = h.engine.explain_match(AssetId(h.id_of("aurora.jpg")), &asked("iceland"), &[]).unwrap();
    assert_eq!(aurora.words.iter().map(|w| w.field).collect::<Vec<_>>(), vec![sa_search::Field::Folder]);
    // Words only: no model vector, no meaning.
    assert!(h.engine.explain_match(AssetId(id), &asked("sunset"), &[]).unwrap().meaning.is_none());
}

/// C1 and C2 through the engine: the labels a picture shows come from its own vector against the announced label words;
/// what kind of picture it is comes from facts (here its name), and nothing is claimed without one.
#[test]
fn a_picture_shows_the_labels_its_description_is_close_to() {
    let h = harness();
    library(&h);
    put(&h.media, "Screenshot 2026-11-09 at 10.12.03.png", "topic=city");
    h.engine.rescan(None).unwrap();
    h.wait_scanned(4);
    h.drain_media();
    let puppy = AssetId(h.id_of("puppy.jpg"));
    assert!(h.engine.labels_of(puppy).unwrap().is_empty(), "no model, no labels");
    h.engine.set_embedding_config(model(), CAL).unwrap();
    h.drain_embeddings();
    assert!(h.engine.labels_of(puppy).unwrap().is_empty(), "no label words announced yet");
    let words = ["dog", "beach", "hawk"].map(|w| (w.to_string(), fake_text_vector(DIMS, w))).to_vec();
    h.engine.set_labels(words, 0.5);
    let shown: Vec<String> = h.engine.labels_of(puppy).unwrap().into_iter().map(|l| l.name).collect();
    assert_eq!(shown, vec!["dog"]);
    assert_eq!(h.engine.picture_content(puppy).unwrap(), None, "no fact about the puppy picture");
    let shot = AssetId(h.id_of("Screenshot 2026-11-09 at 10.12.03.png"));
    assert_eq!(h.engine.picture_content(shot).unwrap(), Some(sa_engine::PictureContent::ScreenCapture));
}
