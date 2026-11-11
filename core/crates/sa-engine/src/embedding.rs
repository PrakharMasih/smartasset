//! Search by meaning (Phase 4): the pull-based API for vectors, the in-memory index, and the blend with keywords.
//!
//! Same shape as the perceptual API: `next_embedding_batch` out, `submit_embedding_results` back. Nothing starts
//! until the Swift side announces a model configuration (`set_embedding_config`): with no model, no job exists, no
//! vector is stored and every search is the keyword search it always was.

use crate::engine::{EMBED, Engine, MEDIA};
use sa_core::time::now_ms;
use sa_core::{AssetId, ErrorClass, MediaKind, Result, SearchQuery, SortKey};
use sa_jobs::{LeaseOutcome, PauseReason, backoff_ms};
use sa_providers::{EmbeddingOutcome, EmbeddingTask};
use sa_store::embeddings::{self, ModelConfig};
use sa_store::{assets, jobs};
use sa_vector::Index;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

const MAX_ATTEMPTS: u32 = 3;

/// How many vector matches are considered before blending. A library of 250,000 still answers in a few
/// milliseconds; 200 is far more than anyone reads in a result list.
const SEMANTIC_DEPTH: usize = 200;
/// Reciprocal rank fusion constant (Cormack et al.): a match's blended score is the sum over lists of 1 / (K + rank).
const RRF_K: f32 = 60.0;

/// How a model's raw similarities are turned into "this file matches": numbers that belong to one model configuration
/// (they come from measuring that model), so the model announces them together with its configuration.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Calibration {
    /// The best match must be at least this similar (cosine) or the library is taken not to answer the question at all.
    /// Gibberish and questions about things the library does not hold have a best match below it; real questions above.
    pub min_match: f32,
    /// Files at most this much less similar than the best match are kept, so one-word questions that many files answer
    /// ("dog") return all of them, while the long tail is left out.
    pub band: f32,
    /// A2: a file in a group of similar copies must look at least this much like the group's first file (cosine of
    /// their pictures) or it leaves the group. `None`: not measured for this model, so groups are not confirmed.
    pub copy_match: Option<f32>,
}

impl Default for Calibration {
    /// Keeps everything the vector scan returns: for a configuration nobody has measured, search by meaning is
    /// permissive rather than silently empty, and copies are not confirmed. Real models announce measured values.
    fn default() -> Self {
        Self { min_match: -1.0, band: 2.0, copy_match: None }
    }
}

#[derive(Debug, Clone)]
pub struct EmbeddingBatch {
    pub batch_id: u64,
    pub tasks: Vec<EmbeddingTask>,
    pub parallelism: u32,
}

#[derive(Debug, Clone)]
pub enum EmbeddingTasks {
    Batch(EmbeddingBatch),
    Held(PauseReason),
    Empty,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EmbeddingReport {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

/// Where search by meaning stands, for the app to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddingStatus {
    /// The announced configuration, if a model is ready.
    pub config: Option<String>,
    /// Pictures and videos that have a vector.
    pub with_vectors: i64,
    /// Pictures and videos still waiting for one.
    pub remaining: i64,
}

/// What an explanation says about the meaning side of a match.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MeaningMatch {
    /// Cosine of the question and the file's closest vector.
    pub score: f32,
    /// True when `score` itself reaches the model's minimum best match; false when the file was added because it is
    /// within the band of a better match. A file search by meaning did not add has no `MeaningMatch` at all.
    pub strong: bool,
    /// For a video: where in it the closest scene is. `None` for a picture or when the place is not known.
    pub moment_ms: Option<i64>,
    /// How many vectors the file has (more than one for a video).
    pub frames: u32,
}

/// "Why this matched" (S11): where each typed word was found, and how close the file is by meaning.
#[derive(Debug, Clone, PartialEq)]
pub struct MatchExplanation {
    pub words: Vec<sa_search::WordHit>,
    pub meaning: Option<MeaningMatch>,
}

/// The stored vectors of the active configuration, in memory, and while it is still being made for the library, the
/// vectors of the configuration it replaces (same model, so the same question can be asked of both).
#[derive(Debug)]
pub(crate) struct VectorCache {
    config: String,
    index: Index,
    seen: HashSet<i64>,
    fallback: Option<Fallback>,
}

/// The replaced configuration's vectors. They answer only for files the active configuration has not described yet,
/// so search keeps finding everything while the library is described again. Dropped, and deleted from the database,
/// once every one of its files has a new vector.
#[derive(Debug)]
struct Fallback {
    config: String,
    index: Index,
    /// Files it holds that the active configuration has not described yet.
    left: HashSet<i64>,
}

impl VectorCache {
    /// The `k` best files for `question` across the active vectors and, for files they do not cover yet, the replaced
    /// ones. One answer, as if a single index held every file.
    fn answer(&self, question: &[f32], k: usize, allow: Option<&(dyn Fn(i64) -> bool + Sync)>) -> sa_vector::Answer {
        let current = self.index.answer(question, k, allow);
        let Some(fallback) = &self.fallback else { return current };
        let not_covered = |id: i64| fallback.left.contains(&id) && allow.is_none_or(|f| f(id));
        current.merge(fallback.index.answer(question, k, Some(&not_covered)), k)
    }

    /// The replaced configuration, once nothing is left for it to answer: the caller deletes its vectors.
    fn take_finished_fallback(&mut self) -> Option<String> {
        if self.fallback.as_ref().is_some_and(|f| f.left.is_empty()) {
            return self.fallback.take().map(|f| f.config);
        }
        None
    }
}

impl Engine {
    /// Announces the model that is ready (and registers it). From now on pictures and videos get vectors made with it.
    /// Calling it again with the same configuration changes nothing. With another one of the same model (only the
    /// picture preparation differs) the old vectors keep answering for the files not yet described again, then are
    /// deleted; with another model they stay stored but are not used.
    pub fn set_embedding_config(&self, config: ModelConfig, calibration: Calibration) -> Result<()> {
        let inner = &self.inner;
        let c = config.clone();
        inner.db.write(move |tx| embeddings::register_config(tx, &c, now_ms()))?;
        *inner.embedding.lock() = Some(config);
        *inner.calibration.lock() = calibration;
        *inner.vectors.lock() = None;
        // Groups of similar copies are confirmed with this model's vectors and cut-off (A2).
        inner.touch_duplicates();
        inner.embed_dirty.store(true, std::sync::atomic::Ordering::Relaxed);
        inner.notifier.work_started();
        Ok(())
    }

    /// The model went away (removed, failed to load): no new vectors are made and searches are keyword only.
    pub fn clear_embedding_config(&self) {
        let inner = &self.inner;
        *inner.embedding.lock() = None;
        *inner.vectors.lock() = None;
        inner.touch_duplicates();
        let _ = inner.manager.revoke_all(EMBED);
    }

    #[must_use]
    pub fn embedding_config(&self) -> Option<ModelConfig> {
        self.inner.embedding.lock().clone()
    }

    pub fn embedding_status(&self) -> Result<EmbeddingStatus> {
        let inner = &self.inner;
        let Some(config) = inner.embedding.lock().clone() else {
            return Ok(EmbeddingStatus { config: None, with_vectors: 0, remaining: 0 });
        };
        let with_vectors = inner.db.read(|c| embeddings::assets_with_vectors(c, &config.id))?;
        Ok(EmbeddingStatus { config: Some(config.id), with_vectors, remaining: inner.manager.counts(EMBED)?.remaining() })
    }

    /// Leases the next batch of pictures and videos to embed. Returns nothing while thumbnails are still being made
    /// (the browse pass comes first) or while no model is ready.
    pub fn next_embedding_batch(&self, max_items: u32) -> Result<EmbeddingTasks> {
        let inner = &self.inner;
        let Some(config) = inner.embedding.lock().clone() else { return Ok(EmbeddingTasks::Empty) };
        if inner.manager.counts(MEDIA)?.remaining() > 0 || inner.scans_running.load(std::sync::atomic::Ordering::Relaxed) > 0 {
            return Ok(EmbeddingTasks::Empty);
        }
        if inner.embed_dirty.swap(false, std::sync::atomic::Ordering::Relaxed) {
            loop {
                let id = config.id.clone();
                match inner.db.write(move |tx| embeddings::enqueue_backlog(tx, &id, 5_000, now_ms())) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        }
        let batch = match inner.manager.lease_batch(EMBED, max_items)? {
            LeaseOutcome::Held(r) => return Ok(EmbeddingTasks::Held(r)),
            LeaseOutcome::Empty => return Ok(EmbeddingTasks::Empty),
            LeaseOutcome::Batch(b) => b,
        };
        let tasks = batch
            .items
            .iter()
            .map(|job| {
                let mut path = std::path::PathBuf::from(&job.mount_path);
                if !job.folder_rel.is_empty() {
                    path.push(&job.folder_rel);
                }
                path.push(&job.rel_path);
                let ext = job.rel_path.rsplit_once('.').map_or("", |(_, e)| e).to_ascii_lowercase();
                let kind = MediaKind::from_extension(&ext).unwrap_or(MediaKind::Image);
                let existing = |p: std::path::PathBuf| p.is_file().then(|| p.to_string_lossy().into_owned());
                let thumb = (job.thumb_rev > 0).then(|| inner.dirs.thumb_path(job.asset_id.0, job.thumb_rev)).and_then(existing);
                let strip = (kind == MediaKind::Video && job.thumb_rev > 0)
                    .then(|| inner.dirs.filmstrip_path(job.asset_id.0, job.thumb_rev))
                    .and_then(existing);
                EmbeddingTask {
                    job_id: job.job_id.0,
                    asset_id: job.asset_id.0,
                    path: path.to_string_lossy().into_owned(),
                    kind,
                    ext,
                    thumb_path: thumb,
                    filmstrip_path: strip,
                    attempt: job.attempt,
                    size: job.size,
                    mtime: job.mtime,
                }
            })
            .collect();
        inner.notifier.work_started();
        Ok(EmbeddingTasks::Batch(EmbeddingBatch { batch_id: batch.id, tasks, parallelism: batch.throttle.parallelism }))
    }

    /// Commits a batch of vectors in one transaction. Results about a file that changed are thrown away, and a vector
    /// that is not a finite, non-zero list of the configured length fails its file (never the batch).
    pub fn submit_embedding_results(&self, batch_id: u64, results: Vec<(i64, EmbeddingOutcome)>) -> Result<EmbeddingReport> {
        let inner = &self.inner;
        let Some(batch) = inner.manager.finish(batch_id) else {
            let discarded = u32::try_from(results.len()).unwrap_or(u32::MAX);
            return Ok(EmbeddingReport { discarded, ..EmbeddingReport::default() });
        };
        let Some(config) = inner.embedding.lock().clone() else {
            // The model went away while the worker was busy: put everything back.
            let b = batch.clone();
            inner.db.write(move |tx| {
                for item in &b.items {
                    jobs::release(tx, item.job_id, &b.token, now_ms())?;
                }
                Ok(())
            })?;
            return Ok(EmbeddingReport { released: u32::try_from(batch.items.len()).unwrap_or(u32::MAX), ..EmbeddingReport::default() });
        };
        let revoked = batch.is_revoked();
        let mut by_job: HashMap<i64, EmbeddingOutcome> = results.into_iter().collect();
        let b = batch.clone();
        let cfg = config.clone();
        let (report, stored) = inner.db.write(move |tx| {
            let now = now_ms();
            let mut report = EmbeddingReport::default();
            let mut stored: Vec<(i64, Vec<Vec<u8>>)> = Vec::new();
            for item in &b.items {
                let Some(outcome) = by_job.remove(&item.job_id.0) else {
                    if jobs::release(tx, item.job_id, &b.token, now)? {
                        report.released += 1;
                    }
                    continue;
                };
                let unchanged = assets::file_fingerprint(tx, item.asset_id)?
                    .is_some_and(|(size, mtime)| size == item.size && mtime == item.mtime);
                if revoked || !unchanged {
                    jobs::release(tx, item.job_id, &b.token, now)?;
                    report.discarded += 1;
                    continue;
                }
                let outcome = match outcome {
                    EmbeddingOutcome::Done { vectors, times_ms } => match prepare(vectors, cfg.dims as usize) {
                        Ok(encoded) => Ok((encoded, times_ms)),
                        Err(message) => Err((ErrorClass::ModelFailure, message)),
                    },
                    EmbeddingOutcome::Failed { class, message } => Err((class, message)),
                };
                match outcome {
                    Ok((encoded, times_ms)) => {
                        if embeddings::set_vectors(tx, item.asset_id, item.size, item.mtime, &cfg.id, cfg.dims, &encoded, &times_ms)?
                            && jobs::complete(tx, item.job_id, &b.token, now)?
                        {
                            embeddings::drop_superseded(tx, item.asset_id, &cfg)?;
                            report.committed += 1;
                            stored.push((item.asset_id.0, encoded));
                        } else {
                            report.discarded += 1;
                        }
                    }
                    Err((class, message)) => {
                        jobs::fail(tx, item.job_id, &b.token, class, &message, now + backoff_ms(item.attempt), now)?;
                        if class.is_retryable() && item.attempt < MAX_ATTEMPTS {
                            report.retried += 1;
                        } else {
                            report.failed += 1;
                        }
                    }
                }
            }
            Ok((report, stored))
        })?;
        let described: Vec<i64> = stored.iter().map(|(id, _)| *id).collect();
        self.add_to_index(&config.id, stored);
        // A2: a file in a group of similar copies just got its description, so the group can now be confirmed.
        if inner.calibration.lock().copy_match.is_some() && inner.in_similar_group(&described) {
            inner.touch_duplicates();
        }
        inner.notifier.work_started();
        Ok(report)
    }

    /// New vectors join the index in memory. A vector that replaces an old one drops the index instead (it is built
    /// again from the database on the next search), so a stale row is never answered. A file described for the first
    /// time by the active configuration stops being answered from the replaced one.
    fn add_to_index(&self, config: &str, stored: Vec<(i64, Vec<Vec<u8>>)>) {
        let finished = {
            let mut guard = self.inner.vectors.lock();
            let Some(cache) = guard.as_mut() else { return };
            if cache.config != config {
                return;
            }
            for (id, vectors) in stored {
                if cache.seen.contains(&id) {
                    *guard = None;
                    return;
                }
                for v in &vectors {
                    cache.index.push(id, v);
                }
                cache.seen.insert(id);
                if let Some(fallback) = cache.fallback.as_mut() {
                    fallback.left.remove(&id);
                }
            }
            cache.take_finished_fallback()
        };
        self.retire(finished);
    }

    /// Deletes a replaced configuration whose every file has a new vector (its rows go with it).
    fn retire(&self, config: Option<String>) {
        if let Some(old) = config {
            // Best effort: if it fails, the old rows stay unused and the next index build tries again.
            let _ = self.inner.db.write(move |tx| embeddings::remove_config(tx, &old));
        }
    }

    /// Runs `f` on the vectors of the active configuration, building them from the database if needed. `None` when no
    /// model is ready.
    fn with_index<R>(&self, f: impl FnOnce(&VectorCache) -> R) -> Result<Option<R>> {
        let inner = &self.inner;
        let Some(config) = inner.embedding.lock().clone() else { return Ok(None) };
        let (answer, finished) = {
            let mut guard = inner.vectors.lock();
            if guard.as_ref().is_none_or(|c| c.config != config.id) {
                let mut index = Index::new(config.dims as usize);
                let mut seen = HashSet::new();
                let previous = inner.db.read(|c| {
                    embeddings::for_each_vector(c, &config.id, |id, bytes| {
                        if index.push(id, bytes) {
                            seen.insert(id);
                        }
                    })?;
                    embeddings::compatible_previous(c, &config)
                })?;
                let fallback = match previous {
                    Some(old) => {
                        let mut index = Index::new(config.dims as usize);
                        let mut left = HashSet::new();
                        inner.db.read(|c| {
                            embeddings::for_each_vector(c, &old, |id, bytes| {
                                if !seen.contains(&id) && index.push(id, bytes) {
                                    left.insert(id);
                                }
                            })
                        })?;
                        Some(Fallback { config: old, index, left })
                    }
                    None => None,
                };
                *guard = Some(VectorCache { config: config.id.clone(), index, seen, fallback });
            }
            let Some(cache) = guard.as_mut() else { return Ok(None) };
            let finished = cache.take_finished_fallback();
            (f(cache), finished)
        };
        self.retire(finished);
        Ok(Some(answer))
    }

    /// The files whose vectors are closest to `vector` (the question as the model embedded it), best first, with their
    /// cosine similarity. No filters and no cut-off: this is the raw answer, for measuring and for showing why a file
    /// matched. Empty with no model or no vectors.
    pub fn semantic_hits(&self, vector: &[f32], limit: usize) -> Result<sa_vector::Answer> {
        let mut question = vector.to_vec();
        if !sa_vector::normalise(&mut question) {
            return Ok(sa_vector::Answer::empty());
        }
        Ok(self.with_index(|cache| cache.answer(&question, limit, None))?.unwrap_or_else(sa_vector::Answer::empty))
    }

    /// More Like This (S7): the files closest to a file's own description, best first, without the file itself.
    /// `query` supplies the filters (scope, kind, rating, …); its words and order are ignored. A video asks with every
    /// scene and each file counts at its best. `None` when the file has no vector yet (it is not described, or no model
    /// is ready): the caller says so, which is not the same as "nothing is like it".
    pub fn search_similar(&self, asset: AssetId, query: &SearchQuery, limit: usize) -> Result<Option<Arc<Vec<i64>>>> {
        let Some(config) = self.inner.embedding.lock().clone() else { return Ok(None) };
        let frames = self.inner.db.read(|c| embeddings::frames_of(c, asset, &config))?;
        let questions: Vec<Vec<f32>> = frames.iter().filter_map(|f| sa_vector::decode_f16(&f.vec)).collect();
        if questions.is_empty() {
            return Ok(None);
        }
        let mut filter_only = query.clone();
        filter_only.text = None;
        filter_only.sort = sa_core::Sort::default();
        let allowed: HashSet<i64> = self.search(&filter_only)?.iter().copied().collect();
        let allow = |id: i64| id != asset.0 && allowed.contains(&id);
        let best = self.with_index(|cache| {
            let mut best: HashMap<i64, f32> = HashMap::new();
            for question in &questions {
                for hit in cache.answer(question, limit, Some(&allow)).hits {
                    best.entry(hit.asset_id).and_modify(|s| *s = s.max(hit.score)).or_insert(hit.score);
                }
            }
            best
        })?;
        let Some(best) = best else { return Ok(None) };
        let mut ranked: Vec<(i64, f32)> = best.into_iter().collect();
        ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        ranked.truncate(limit);
        Ok(Some(Arc::new(ranked.into_iter().map(|(id, _)| id).collect())))
    }

    /// Why a file came up for a search (S11): the place of every typed word, and the closeness by meaning with the
    /// best scene of a video, **only if search by meaning really added the file** (the same rule `search_hybrid` uses:
    /// the question's best match reaches the minimum and the file is within the band of it). `query` is the search as
    /// asked (its words and filters); `vector` is the question as the model embedded it (empty: words only).
    pub fn explain_match(&self, asset: AssetId, query: &SearchQuery, vector: &[f32]) -> Result<MatchExplanation> {
        let found = self.inner.db.read(|c| sa_search::explain(c, asset.0, query.trimmed_text().unwrap_or("")))?;
        let mut question = vector.to_vec();
        let mut meaning = None;
        let config = self.inner.embedding.lock().clone();
        if let Some(config) = config.filter(|_| !question.is_empty() && sa_vector::normalise(&mut question)) {
            let added = self.meaning_kept(query, &question)?.is_some_and(|kept| kept.iter().any(|h| h.asset_id == asset.0));
            if added {
                let min_match = self.inner.calibration.lock().min_match;
                let frames = self.inner.db.read(|c| embeddings::frames_of(c, asset, &config))?;
                let mut best: Option<(f32, Option<i64>)> = None;
                for frame in &frames {
                    let Some(v) = sa_vector::decode_f16(&frame.vec).filter(|v| v.len() == question.len()) else { continue };
                    let score: f32 = v.iter().zip(&question).map(|(a, b)| a * b).sum();
                    if best.is_none_or(|(s, _)| score > s) {
                        best = Some((score, frame.t_ms));
                    }
                }
                meaning = best.map(|(score, moment_ms)| MeaningMatch {
                    score,
                    strong: score >= min_match,
                    moment_ms,
                    frames: u32::try_from(frames.len()).unwrap_or(u32::MAX),
                });
            }
        }
        Ok(MatchExplanation { words: found, meaning })
    }

    /// S2: for the files of `ids` that search by meaning added to this search (the rule `search_hybrid` uses), the time
    /// of their closest scene. Files with no time (pictures, or videos described before moments existed) are left out.
    /// One scan of the vectors for the whole list, so a page of results costs one call.
    pub fn moments(&self, query: &SearchQuery, vector: &[f32], ids: &[i64]) -> Result<Vec<(i64, i64)>> {
        let mut question = vector.to_vec();
        if ids.is_empty() || question.is_empty() || !sa_vector::normalise(&mut question) {
            return Ok(Vec::new());
        }
        let Some(config) = self.inner.embedding.lock().clone() else { return Ok(Vec::new()) };
        let Some(kept) = self.meaning_kept(query, &question)? else { return Ok(Vec::new()) };
        let added: HashSet<i64> = kept.iter().map(|h| h.asset_id).collect();
        let wanted: Vec<i64> = ids.iter().copied().filter(|id| added.contains(id)).collect();
        self.inner.db.read(|c| {
            let mut out = Vec::new();
            for id in wanted {
                let frames = embeddings::frames_of(c, AssetId(id), &config)?;
                let best = frames
                    .iter()
                    .filter_map(|f| Some((f.t_ms?, sa_vector::decode_f16(&f.vec)?)))
                    .filter(|(_, v)| v.len() == question.len())
                    .map(|(t, v)| (t, v.iter().zip(&question).map(|(a, b)| a * b).sum::<f32>()))
                    .max_by(|a, b| a.1.total_cmp(&b.1));
                if let Some((t, _)) = best {
                    out.push((id, t));
                }
            }
            Ok(out)
        })
    }

    /// S2: where a video's scenes start (milliseconds, in order); empty for a picture or a video not yet described.
    pub fn scene_times(&self, asset: AssetId) -> Result<Vec<i64>> {
        let Some(config) = self.inner.embedding.lock().clone() else { return Ok(Vec::new()) };
        Ok(self.inner.db.read(|c| embeddings::frames_of(c, asset, &config))?.iter().filter_map(|f| f.t_ms).collect())
    }

    /// The keyword search blended with search by meaning.
    ///
    /// `vector` is the query as the model embedded it. Keyword matches and vector matches (restricted to the files the
    /// filters allow) are merged by reciprocal rank fusion, so a file found by both rises and one found by either is
    /// kept. Without a model, without vectors yet, without text, or ordered by anything but relevance, this is exactly
    /// [`Engine::search`].
    pub fn search_hybrid(&self, query: &SearchQuery, vector: &[f32]) -> Result<Arc<Vec<i64>>> {
        let keyword = self.search(query)?;
        if query.trimmed_text().is_none() || query.sort.key != SortKey::Relevance || vector.is_empty() {
            return Ok(keyword);
        }
        let mut question = vector.to_vec();
        if !sa_vector::normalise(&mut question) {
            return Ok(keyword);
        }
        let Some(kept) = self.meaning_kept(query, &question)? else { return Ok(keyword) };
        let kept: Vec<i64> = kept.into_iter().map(|h| h.asset_id).collect();
        Ok(Arc::new(fuse(&keyword, &kept)))
    }

    /// The files search by meaning adds to a typed search: the closest files the filters allow, if the best of them is
    /// close enough to answer at all (the calibration's minimum), and those within its band of the best. `None` when no
    /// model is ready, the library has no vectors, or nothing is close enough. `question` must be normalised.
    fn meaning_kept(&self, query: &SearchQuery, question: &[f32]) -> Result<Option<Vec<sa_vector::Hit>>> {
        // Who may be answered: everything the filters allow, with the text taken away.
        let mut filter_only = query.clone();
        filter_only.text = None;
        filter_only.sort = sa_core::Sort::default();
        let allowed: HashSet<i64> = self.search(&filter_only)?.iter().copied().collect();
        let allow = |id: i64| allowed.contains(&id);
        let Some(hits) = self.with_index(|cache| cache.answer(question, SEMANTIC_DEPTH, Some(&allow)).hits)? else {
            return Ok(None);
        };
        let calibration = *self.inner.calibration.lock();
        // Nothing (within the filters) close enough to answer: the keyword answer stands alone.
        let Some(best) = hits.first().map(|h| h.score).filter(|best| *best >= calibration.min_match) else { return Ok(None) };
        Ok(Some(hits.into_iter().take_while(|h| h.score >= best - calibration.band).collect()))
    }
}

/// Normalises and stores-ready encodes each vector, or says why the answer cannot be used.
fn prepare(vectors: Vec<Vec<f32>>, dims: usize) -> std::result::Result<Vec<Vec<u8>>, String> {
    if vectors.is_empty() {
        return Err("the model returned no vector".into());
    }
    let mut out = Vec::with_capacity(vectors.len());
    for mut v in vectors {
        if v.len() != dims {
            return Err(format!("the model returned {} numbers, expected {dims}", v.len()));
        }
        if !sa_vector::normalise(&mut v) {
            return Err("the model returned a vector that is empty, zero or not a number".into());
        }
        out.push(sa_vector::encode_f16(&v));
    }
    Ok(out)
}

/// Reciprocal rank fusion of two ranked lists of asset ids. Ties go to the lower id so results are stable.
fn fuse(keyword: &[i64], semantic: &[i64]) -> Vec<i64> {
    let mut score: HashMap<i64, f32> = HashMap::new();
    for list in [keyword, semantic] {
        for (rank, id) in list.iter().enumerate() {
            #[allow(clippy::cast_precision_loss)]
            let s = 1.0 / (RRF_K + rank as f32 + 1.0);
            *score.entry(*id).or_insert(0.0) += s;
        }
    }
    let mut ids: Vec<i64> = score.keys().copied().collect();
    ids.sort_by(|a, b| score[b].total_cmp(&score[a]).then(a.cmp(b)));
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_found_by_both_lists_beats_one_found_by_one() {
        let fused = fuse(&[10, 20, 30], &[40, 20, 50]);
        assert_eq!(fused[0], 20, "20 is in both lists");
        assert_eq!(fused.len(), 5, "every file from either list is kept, once");
    }

    #[test]
    fn fusion_is_stable_for_equal_scores() {
        assert_eq!(fuse(&[2], &[1]), vec![1, 2]);
    }

    #[test]
    fn bad_vectors_are_refused_with_a_reason() {
        assert!(prepare(vec![], 4).is_err());
        assert!(prepare(vec![vec![1.0, 2.0]], 4).is_err(), "wrong length");
        assert!(prepare(vec![vec![0.0; 4]], 4).is_err(), "all zero");
        assert!(prepare(vec![vec![f32::NAN, 1.0, 0.0, 0.0]], 4).is_err(), "not a number");
        let ok = prepare(vec![vec![3.0, 4.0, 0.0, 0.0]], 4).unwrap();
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].len(), 8, "4 numbers, 2 bytes each");
    }
}
