//! The bridge surface exported to Swift (plan §6.3, docs/BRIDGE.md).
//!
//! Rules this file keeps:
//! * The API is small and coarse: commands, queries, `next_media_batch`/`submit_media_results`, an event stream.
//! * Calls that touch storage are `async` and run on blocking threads, never on the caller's thread.
//! * Nothing panics across the bridge: a bug becomes [`BridgeError::Internal`].
//! * No media bytes cross; large data stays on disk and only paths travel.

mod logging;
mod types;

use sa_core::{AssetId, ColorLabel, Flag, FolderId, SearchQuery};
use sa_jobs::Conditions;
use sa_engine::{BatchTasks, Engine, EngineConfig, Event, EventSink};
use sa_engine::{EmbeddingTasks, PerceptualTasks, TextTasks};
use sa_providers::{EmbeddingOutcome, MediaOutcome, MediaProbe, PerceptualOutcome, TextOutcome};
use sa_store::dedupe::PerceptualHash;
use std::path::PathBuf;
use std::sync::Arc;

pub use types::*;

uniffi::setup_scaffolding!();

type BridgeResult<T> = Result<T, BridgeError>;

/// Runs blocking engine work on a blocking thread and maps every failure, including a panic, to a typed error.
async fn blocking<T, F>(f: F) -> BridgeResult<T>
where
    T: Send + 'static,
    F: FnOnce() -> sa_core::Result<T> + Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(result) => result.map_err(BridgeError::from),
        Err(join) => {
            tracing::error!(error = %join, "engine task panicked");
            Err(BridgeError::Internal { message: format!("internal error: {join}") })
        }
    }
}

struct ListenerAdapter(Arc<dyn EngineListener>);

impl EventSink for ListenerAdapter {
    fn on_event(&self, event: Event) {
        self.0.on_event((&event).into());
    }
}

fn ids(v: &[i64]) -> Vec<AssetId> {
    v.iter().copied().map(AssetId).collect()
}

fn path_string(p: &std::path::Path) -> String {
    p.to_string_lossy().into_owned()
}

fn volume_from(v: MountedVolumeDto) -> sa_engine::MountedVolume {
    sa_engine::MountedVolume {
        uuid: v.uuid,
        name: v.name,
        mount_path: PathBuf::from(v.mount_path),
        is_internal: v.is_internal,
    }
}

/// An empty search: the whole library, newest first. Start from this and change what you need.
#[uniffi::export]
#[must_use]
pub fn default_search_query() -> SearchQuery {
    SearchQuery::default()
}

/// The thresholds the app matches with, so a test can start from them: `[max DCT-hash distance, max difference-hash
/// distance]`, out of 64 bits.
#[uniffi::export]
#[must_use]
pub fn default_near_duplicate_limits() -> Vec<u32> {
    let c = sa_dedupe::Config::default();
    vec![c.max_p, c.max_d]
}

/// Groups pictures and videos that look alike, with the same code the engine uses. `max_p` and `max_d` override the
/// default limits; pass the defaults from [`default_near_duplicate_limits`] for what the app does.
#[uniffi::export]
#[must_use]
pub fn match_perceptual(items: Vec<PerceptualItemDto>, max_p: u32, max_d: u32) -> Vec<NearGroupDto> {
    let items: Vec<sa_dedupe::Item> = items
        .into_iter()
        .map(|i| sa_dedupe::Item {
            id: i.id,
            kind: if i.kind == sa_core::MediaKind::Video { sa_dedupe::Kind::Video } else { sa_dedupe::Kind::Image },
            duration_ms: i.duration_ms,
            exact_key: None,
            slots: i.hashes.iter().map(|h| sa_dedupe::Hash { d: h.dhash, p: h.phash }).collect(),
        })
        .collect();
    sa_dedupe::group(&items, sa_dedupe::Config { max_p, max_d })
        .into_iter()
        .map(|g| NearGroupDto {
            members: g.members.into_iter().map(|m| NearMemberDto { id: m.id, similarity: m.similarity }).collect(),
        })
        .collect()
}

/// Opens the library. Search and browsing work as soon as this returns; call `start()` to begin watching and
/// indexing.
#[uniffi::export(async_runtime = "tokio")]
pub async fn open_engine(
    options: EngineOptions,
    listener: Arc<dyn EngineListener>,
) -> BridgeResult<Arc<EngineHandle>> {
    let data_dir = PathBuf::from(&options.data_dir);
    logging::init(&data_dir.join("logs"));
    let (handle, info) = blocking(move || {
        let mut config = EngineConfig::new(&options.data_dir);
        config.worker_parallelism = options.worker_parallelism.max(1);
        config.watch = options.watch;
        let (engine, info) = Engine::open(config, Arc::new(ListenerAdapter(listener)))?;
        Ok((engine, info))
    })
    .await?;
    Ok(Arc::new(EngineHandle {
        engine: handle,
        info: OpenInfoDto {
            schema_before: info.schema_before,
            schema_after: info.schema_after,
            unclean_exit: info.unclean_exit,
            database_problem: info.database_problem,
            asset_count: info.asset_count,
        },
    }))
}

#[derive(uniffi::Object)]
pub struct EngineHandle {
    engine: Engine,
    info: OpenInfoDto,
}

/// A search result: every matching id in display order, held in Rust. The UI asks for pages by position, so a
/// 250,000-item grid never needs 250,000 objects in Swift.
#[derive(uniffi::Object)]
pub struct ResultSet {
    engine: Engine,
    ids: Arc<Vec<i64>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl ResultSet {
    #[must_use]
    pub fn count(&self) -> u64 {
        self.ids.len() as u64
    }

    #[must_use]
    pub fn id_at(&self, index: u64) -> Option<i64> {
        usize::try_from(index).ok().and_then(|i| self.ids.get(i)).copied()
    }

    /// Ids in `[offset, offset + limit)`, clamped to the result.
    #[must_use]
    pub fn ids_in(&self, offset: u64, limit: u64) -> Vec<i64> {
        let len = self.ids.len();
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(len);
        let end = start.saturating_add(usize::try_from(limit).unwrap_or(usize::MAX)).min(len);
        self.ids[start..end].to_vec()
    }

    /// Position of an asset in this result, to keep the selection when results are refreshed.
    #[must_use]
    pub fn index_of(&self, id: i64) -> Option<u64> {
        self.ids.iter().position(|v| *v == id).map(|i| i as u64)
    }

    #[must_use]
    pub fn all_ids(&self) -> Vec<i64> {
        self.ids.as_ref().clone()
    }

    /// Tile data for positions `[offset, offset + limit)`.
    pub async fn summaries(&self, offset: u64, limit: u64) -> BridgeResult<Vec<AssetSummaryDto>> {
        let page = self.ids_in(offset, limit);
        let engine = self.engine.clone();
        blocking(move || engine.summaries(&page).map(|v| v.iter().map(AssetSummaryDto::from).collect())).await
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl EngineHandle {
    #[must_use]
    pub fn open_info(&self) -> OpenInfoDto {
        self.info.clone()
    }

    pub async fn start(&self) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.start()).await
    }

    /// Stops all activity and marks the session as cleanly finished.
    pub async fn shutdown(&self) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.shutdown()).await
    }

    // ---- queries ----

    pub async fn search(&self, query: SearchQuery) -> BridgeResult<Arc<ResultSet>> {
        let e = self.engine.clone();
        let ids = blocking(move || e.search(&query)).await?;
        Ok(Arc::new(ResultSet { engine: self.engine.clone(), ids }))
    }

    /// The keyword search blended with search by meaning. `vector` is the query as the model embedded it; with no model,
    /// no vectors yet, no text, or an order other than relevance, this is exactly `search`.
    pub async fn search_hybrid(&self, query: SearchQuery, vector: Vec<f32>) -> BridgeResult<Arc<ResultSet>> {
        let e = self.engine.clone();
        let ids = blocking(move || e.search_hybrid(&query, &vector)).await?;
        Ok(Arc::new(ResultSet { engine: self.engine.clone(), ids }))
    }

    /// More Like This (S7): the files closest to this file's own description, best first, never the file itself.
    /// `query` supplies the filters; its words and order are ignored. `None` when the file has no description yet
    /// (it is waiting, or search by meaning is off): not the same as "nothing is like it".
    pub async fn search_similar(&self, asset_id: i64, query: SearchQuery) -> BridgeResult<Option<Arc<ResultSet>>> {
        let e = self.engine.clone();
        let ids = blocking(move || e.search_similar(AssetId(asset_id), &query, 200)).await?;
        Ok(ids.map(|ids| Arc::new(ResultSet { engine: self.engine.clone(), ids })))
    }

    /// Why a file came up for a search (S11): where each typed word was found, and how close the file is by meaning
    /// (only when search by meaning added it). `query` is the search as asked; `vector` is its words as the model
    /// embedded them (empty: words only).
    pub async fn explain_match(&self, asset_id: i64, query: SearchQuery, vector: Vec<f32>) -> BridgeResult<MatchExplanationDto> {
        let e = self.engine.clone();
        blocking(move || {
            let x = e.explain_match(AssetId(asset_id), &query, &vector)?;
            Ok(MatchExplanationDto {
                words: x
                    .words
                    .into_iter()
                    .map(|w| WordMatchDto {
                        word: w.word,
                        place: match w.field {
                            sa_engine::MatchField::Name => MatchPlace::Name,
                            sa_engine::MatchField::Tag => MatchPlace::Tag,
                            sa_engine::MatchField::Note => MatchPlace::Note,
                            sa_engine::MatchField::TextInPicture => MatchPlace::TextInPicture,
                            sa_engine::MatchField::Folder => MatchPlace::Folder,
                        },
                        snippet: w.snippet,
                    })
                    .collect(),
                meaning: x.meaning.map(|m| MeaningMatchDto { score: m.score, strong: m.strong, moment_ms: m.moment_ms, frames: m.frames }),
            })
        })
        .await
    }

    pub async fn summaries(&self, asset_ids: Vec<i64>) -> BridgeResult<Vec<AssetSummaryDto>> {
        let e = self.engine.clone();
        blocking(move || e.summaries(&asset_ids).map(|v| v.iter().map(AssetSummaryDto::from).collect())).await
    }

    pub async fn asset_detail(&self, asset_id: i64) -> BridgeResult<AssetDetailDto> {
        let e = self.engine.clone();
        blocking(move || e.asset_detail(AssetId(asset_id)).map(|d| (&d).into())).await
    }

    pub async fn paths(&self, asset_ids: Vec<i64>) -> BridgeResult<Vec<AssetPathDto>> {
        let e = self.engine.clone();
        blocking(move || {
            e.paths(&asset_ids).map(|v| {
                v.into_iter()
                    .map(|(id, p)| AssetPathDto { asset_id: id.0, path: p.as_deref().map(path_string) })
                    .collect()
            })
        })
        .await
    }

    pub async fn stats(&self) -> BridgeResult<LibraryStatsDto> {
        let e = self.engine.clone();
        blocking(move || {
            e.stats().map(|s| LibraryStatsDto {
                total: s.total,
                images: s.images,
                videos: s.videos,
                audio: s.audio,
                missing: s.missing,
                total_size: s.total_size,
            })
        })
        .await
    }

    /// Where the thumbnail with this revision lives. A pure computation, safe to call on the main thread.
    #[must_use]
    pub fn thumb_path(&self, asset_id: i64, rev: i64) -> String {
        path_string(&self.engine.thumb_path(asset_id, rev))
    }

    /// Where the hover-scrub filmstrip for a video lives.
    #[must_use]
    pub fn filmstrip_path(&self, asset_id: i64, rev: i64) -> String {
        path_string(&self.engine.data_dirs().filmstrip_path(asset_id, rev))
    }

    // ---- organizing ----

    pub async fn set_rating(&self, asset_ids: Vec<i64>, rating: u8) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_rating(&ids(&asset_ids), rating)).await
    }

    pub async fn set_flag(&self, asset_ids: Vec<i64>, flag: Flag) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_flag(&ids(&asset_ids), flag)).await
    }

    pub async fn set_color_label(&self, asset_ids: Vec<i64>, label: ColorLabel) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_color_label(&ids(&asset_ids), label)).await
    }

    pub async fn set_notes(&self, asset_id: i64, notes: String) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_notes(AssetId(asset_id), &notes)).await
    }

    pub async fn add_tags(&self, asset_ids: Vec<i64>, names: Vec<String>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.add_tags(&ids(&asset_ids), &names)).await
    }

    pub async fn remove_tags(&self, asset_ids: Vec<i64>, names: Vec<String>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.remove_tags(&ids(&asset_ids), &names)).await
    }

    pub async fn rename_tag(&self, from: String, to: String) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.rename_tag(&from, &to)).await
    }

    pub async fn delete_tag(&self, name: String) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.delete_tag(&name)).await
    }

    pub async fn tags(&self) -> BridgeResult<Vec<TagDto>> {
        let e = self.engine.clone();
        blocking(move || e.tags().map(|v| v.iter().map(TagDto::from).collect())).await
    }

    pub async fn create_collection(&self, name: String) -> BridgeResult<i64> {
        let e = self.engine.clone();
        blocking(move || e.create_collection(&name)).await
    }

    pub async fn rename_collection(&self, id: i64, name: String) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.rename_collection(id, &name)).await
    }

    pub async fn delete_collection(&self, id: i64) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.delete_collection(id)).await
    }

    pub async fn add_to_collection(&self, id: i64, asset_ids: Vec<i64>) -> BridgeResult<u64> {
        let e = self.engine.clone();
        blocking(move || e.add_to_collection(id, &ids(&asset_ids)).map(|n| n as u64)).await
    }

    pub async fn remove_from_collection(&self, id: i64, asset_ids: Vec<i64>) -> BridgeResult<u64> {
        let e = self.engine.clone();
        blocking(move || e.remove_from_collection(id, &ids(&asset_ids)).map(|n| n as u64)).await
    }

    pub async fn collections(&self) -> BridgeResult<Vec<CollectionDto>> {
        let e = self.engine.clone();
        blocking(move || e.collections().map(|v| v.iter().map(CollectionDto::from).collect())).await
    }

    pub async fn collections_of(&self, asset_id: i64) -> BridgeResult<Vec<i64>> {
        let e = self.engine.clone();
        blocking(move || e.collections_of(AssetId(asset_id))).await
    }

    pub async fn create_smart_collection(&self, name: String, query: SearchQuery) -> BridgeResult<i64> {
        let e = self.engine.clone();
        blocking(move || e.create_smart_collection(&name, &query)).await
    }

    pub async fn update_smart_collection(&self, id: i64, name: String, query: SearchQuery) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.update_smart_collection(id, &name, &query)).await
    }

    pub async fn delete_smart_collection(&self, id: i64) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.delete_smart_collection(id)).await
    }

    pub async fn smart_collections(&self) -> BridgeResult<Vec<SmartCollectionDto>> {
        let e = self.engine.clone();
        blocking(move || e.smart_collections().map(|v| v.iter().map(SmartCollectionDto::from).collect())).await
    }

    // ---- folders and volumes ----

    pub async fn add_folder(&self, request: AddFolderRequestDto) -> BridgeResult<AddFolderOutcomeDto> {
        let e = self.engine.clone();
        blocking(move || {
            let outcome = e.add_folder(sa_engine::AddFolderRequest {
                path: PathBuf::from(request.path),
                bookmark: request.bookmark,
                volume: volume_from(request.volume),
            })?;
            Ok(match outcome {
                sa_store::folders::AddFolderOutcome::Added { id, absorbed } => {
                    AddFolderOutcomeDto::Added { id: id.0, absorbed: absorbed.into_iter().map(|f| f.0).collect() }
                }
                sa_store::folders::AddFolderOutcome::AlreadyAdded(id) => AddFolderOutcomeDto::AlreadyAdded { id: id.0 },
                sa_store::folders::AddFolderOutcome::InsideExisting { folder, folder_name, excluded } => {
                    AddFolderOutcomeDto::InsideExisting { folder_id: folder.0, folder_name, excluded }
                }
            })
        })
        .await
    }

    /// Removes a folder from the index. The files on disk are never touched.
    pub async fn remove_folder(&self, folder_id: i64) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.remove_folder(FolderId(folder_id))).await
    }

    pub async fn set_folder_enabled(&self, folder_id: i64, enabled: bool) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_folder_enabled(FolderId(folder_id), enabled)).await
    }

    pub async fn set_excludes(&self, folder_id: i64, excludes: Vec<String>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_excludes(FolderId(folder_id), &excludes)).await
    }

    pub async fn relocate_folder(
        &self,
        folder_id: i64,
        new_path: String,
        bookmark: Option<Vec<u8>>,
        volume: MountedVolumeDto,
    ) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.relocate_folder(FolderId(folder_id), &PathBuf::from(new_path), bookmark, volume_from(volume)))
            .await
    }

    /// Removes files that are really gone from the library (never from disk). `None` removes every missing file.
    /// Present files are never removed, whatever ids are passed.
    pub async fn remove_missing(&self, asset_ids: Option<Vec<i64>>) -> BridgeResult<u64> {
        let e = self.engine.clone();
        blocking(move || e.remove_missing(asset_ids.as_deref().map(ids).as_deref()).map(|n| n as u64)).await
    }

    pub async fn update_bookmark(&self, folder_id: i64, bookmark: Vec<u8>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.update_bookmark(FolderId(folder_id), &bookmark)).await
    }

    pub async fn list_folders(&self) -> BridgeResult<Vec<FolderDto>> {
        let e = self.engine.clone();
        blocking(move || e.list_folders().map(|v| v.iter().map(FolderDto::from).collect())).await
    }

    pub async fn list_volumes(&self) -> BridgeResult<Vec<VolumeDto>> {
        let e = self.engine.clone();
        blocking(move || e.list_volumes().map(|v| v.iter().map(VolumeDto::from).collect())).await
    }

    /// Tells the engine exactly which volumes are mounted now. Call at launch, before `start()`.
    pub async fn sync_volumes(&self, mounted: Vec<MountedVolumeDto>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.sync_volumes(&mounted.into_iter().map(volume_from).collect::<Vec<_>>())).await
    }

    pub async fn volume_mounted(&self, volume: MountedVolumeDto) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.volume_mounted(&volume_from(volume))).await
    }

    pub async fn volume_unmounted(&self, uuid: String) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.volume_unmounted(&uuid)).await
    }

    pub async fn rescan(&self, folder_id: Option<i64>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.rescan(folder_id.map(FolderId))).await
    }

    // ---- indexing control ----

    pub fn pause_indexing(&self) {
        self.engine.pause_indexing();
    }

    pub fn resume_indexing(&self) {
        self.engine.resume_indexing();
    }

    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.engine.is_paused()
    }

    pub async fn cancel_indexing(&self, folder_id: Option<i64>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.cancel_indexing(folder_id.map(FolderId))).await
    }

    /// Queues everything still missing metadata or a thumbnail (after a cancel). Returns how many.
    pub async fn reindex_unfinished(&self) -> BridgeResult<u64> {
        let e = self.engine.clone();
        blocking(move || e.reindex_unfinished().map(|n| n as u64)).await
    }

    pub fn set_conditions(&self, conditions: Conditions) {
        self.engine.set_conditions(conditions);
    }

    pub async fn set_index_only_on_power(&self, on: bool) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.set_index_only_on_power(on)).await
    }

    #[must_use]
    pub fn index_only_on_power(&self) -> bool {
        self.engine.index_only_on_power()
    }

    /// The assets on screen jump to the front of the queue.
    pub async fn prioritize(&self, asset_ids: Vec<i64>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.prioritize(&ids(&asset_ids))).await
    }

    pub async fn progress(&self) -> ProgressDto {
        let e = self.engine.clone();
        tokio::task::spawn_blocking(move || ProgressDto::from(&e.progress()))
            .await
            .unwrap_or(ProgressDto {
                scanning: false,
                files_discovered: 0,
                media_total: 0,
                media_done: 0,
                media_failed: 0,
                media_remaining: 0,
                dedupe_remaining: 0,
                embed_remaining: 0,
                hold: None,
                eta_seconds: None,
            })
    }

    // ---- the worker contract: two calls per batch ----

    /// Leases up to `max_items` files for a media worker.
    pub async fn next_media_batch(&self, max_items: u32) -> BridgeResult<BatchResponse> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(match e.next_media_batch(max_items)? {
                BatchTasks::Empty => BatchResponse::Empty,
                BatchTasks::Held(reason) => BatchResponse::Held { reason },
                BatchTasks::Batch(b) => BatchResponse::Batch {
                    batch: MediaBatchDto {
                        batch_id: b.batch_id,
                        parallelism: b.parallelism,
                        tasks: b
                            .tasks
                            .into_iter()
                            .map(|t| MediaTaskDto {
                                job_id: t.job_id,
                                asset_id: t.asset_id,
                                path: t.path,
                                kind: t.kind,
                                ext: t.ext,
                                thumb_path: t.thumb_path,
                                thumb_rev: t.thumb_rev,
                                max_edge: t.max_edge,
                                attempt: t.attempt,
                            })
                            .collect(),
                    },
                },
            })
        })
        .await
    }

    /// Commits a batch of results in one transaction.
    pub async fn submit_media_results(
        &self,
        batch_id: u64,
        results: Vec<MediaResultDto>,
    ) -> BridgeResult<SubmitReportDto> {
        let e = self.engine.clone();
        blocking(move || {
            let converted = results
                .into_iter()
                .map(|r| {
                    let outcome = match r.outcome {
                        MediaOutcomeDto::Done { probe, thumb_written } => MediaOutcome::Done(Box::new(MediaProbe {
                            probe: probe.into(),
                            thumb_written,
                        })),
                        MediaOutcomeDto::Failed { class, message } => MediaOutcome::Failed { class, message },
                    };
                    (r.job_id, outcome)
                })
                .collect();
            e.submit_media_results(batch_id, converted).map(SubmitReportDto::from)
        })
        .await
    }

    /// Whether Rust revoked the batch (cancel, quit). Cheap; workers call it between items.
    #[must_use]
    pub fn is_batch_revoked(&self, batch_id: u64) -> bool {
        self.engine.is_batch_revoked(batch_id)
    }

    pub async fn heartbeat(&self, batch_id: u64) -> BridgeResult<bool> {
        let e = self.engine.clone();
        blocking(move || e.heartbeat(batch_id)).await
    }

    /// Gives a batch back without results (the worker is quitting).
    pub async fn release_batch(&self, batch_id: u64) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.release_batch(batch_id)).await
    }

    /// Asks for a fresh look at specific assets.
    pub async fn requeue_media(&self, asset_ids: Vec<i64>) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || e.requeue_media(&ids(&asset_ids))).await
    }

    // ---- duplicates and cleanup (plan A1–A3) ----

    /// Leases up to `max_items` pictures and videos for the perceptual-hash worker.
    pub async fn next_perceptual_batch(&self, max_items: u32) -> BridgeResult<PerceptualResponse> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(match e.next_perceptual_batch(max_items)? {
                PerceptualTasks::Empty => PerceptualResponse::Empty,
                PerceptualTasks::Held(reason) => PerceptualResponse::Held { reason },
                PerceptualTasks::Batch(b) => PerceptualResponse::Batch {
                    batch: PerceptualBatchDto {
                        batch_id: b.batch_id,
                        parallelism: b.parallelism,
                        tasks: b
                            .tasks
                            .into_iter()
                            .map(|t| PerceptualTaskDto {
                                job_id: t.job_id,
                                asset_id: t.asset_id,
                                path: t.path,
                                kind: t.kind,
                                ext: t.ext,
                                thumb_path: t.thumb_path,
                                attempt: t.attempt,
                            })
                            .collect(),
                    },
                },
            })
        })
        .await
    }

    /// Commits a batch of perceptual hashes in one transaction.
    pub async fn submit_perceptual_results(
        &self,
        batch_id: u64,
        results: Vec<PerceptualResultDto>,
    ) -> BridgeResult<PerceptualReportDto> {
        let e = self.engine.clone();
        blocking(move || {
            let converted = results
                .into_iter()
                .map(|r| {
                    let outcome = match r.outcome {
                        PerceptualOutcomeDto::Done { hashes } => PerceptualOutcome::Done(
                            hashes.into_iter().map(|h| PerceptualHash { dhash: h.dhash, phash: h.phash }).collect(),
                        ),
                        PerceptualOutcomeDto::Failed { class, message } => PerceptualOutcome::Failed { class, message },
                    };
                    (r.job_id, outcome)
                })
                .collect();
            let r = e.submit_perceptual_results(batch_id, converted)?;
            Ok(PerceptualReportDto {
                committed: r.committed,
                discarded: r.discarded,
                failed: r.failed,
                retried: r.retried,
                released: r.released,
            })
        })
        .await
    }

    // ---- search by meaning (Phase 4) ----

    /// Announces the model that is ready. From now on pictures and videos get vectors made with it.
    pub async fn set_embedding_config(&self, config: ModelConfigDto) -> BridgeResult<()> {
        let e = self.engine.clone();
        blocking(move || {
            e.set_embedding_config(
                sa_store::embeddings::ModelConfig {
                    id: config.id,
                    model: config.model,
                    version: config.version,
                    modality: config.modality,
                    dims: config.dims,
                    preprocessing: config.preprocessing,
                },
                sa_engine::Calibration { min_match: config.min_match, band: config.band, copy_match: config.copy_match },
            )
        })
        .await
    }

    /// The model went away: no new vectors, and every search is the keyword search.
    pub fn clear_embedding_config(&self) {
        self.engine.clear_embedding_config();
    }

    /// The raw closest files to a question vector, with similarity, and no cut-off (for measuring and "why this matched").
    pub async fn semantic_hits(&self, vector: Vec<f32>, limit: u32) -> BridgeResult<SemanticAnswerDto> {
        let e = self.engine.clone();
        blocking(move || {
            let a = e.semantic_hits(&vector, limit as usize)?;
            Ok(SemanticAnswerDto {
                hits: a.hits.into_iter().map(|h| SemanticHitDto { asset_id: h.asset_id, score: h.score }).collect(),
                mean: a.mean,
                std: a.std,
            })
        })
        .await
    }

    pub async fn embedding_status(&self) -> BridgeResult<EmbeddingStatusDto> {
        let e = self.engine.clone();
        blocking(move || {
            let s = e.embedding_status()?;
            Ok(EmbeddingStatusDto { config: s.config, with_vectors: s.with_vectors, remaining: s.remaining })
        })
        .await
    }

    /// Leases up to `max_items` pictures and videos for the embedding worker.
    pub async fn next_embedding_batch(&self, max_items: u32) -> BridgeResult<EmbeddingResponse> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(match e.next_embedding_batch(max_items)? {
                EmbeddingTasks::Empty => EmbeddingResponse::Empty,
                EmbeddingTasks::Held(reason) => EmbeddingResponse::Held { reason },
                EmbeddingTasks::Batch(b) => EmbeddingResponse::Batch {
                    batch: EmbeddingBatchDto {
                        batch_id: b.batch_id,
                        parallelism: b.parallelism,
                        tasks: b
                            .tasks
                            .into_iter()
                            .map(|t| EmbeddingTaskDto {
                                job_id: t.job_id,
                                asset_id: t.asset_id,
                                path: t.path,
                                kind: t.kind,
                                ext: t.ext,
                                thumb_path: t.thumb_path,
                                filmstrip_path: t.filmstrip_path,
                                attempt: t.attempt,
                            })
                            .collect(),
                    },
                },
            })
        })
        .await
    }

    /// Commits a batch of vectors in one transaction.
    pub async fn submit_embedding_results(
        &self,
        batch_id: u64,
        results: Vec<EmbeddingResultDto>,
    ) -> BridgeResult<EmbeddingReportDto> {
        let e = self.engine.clone();
        blocking(move || {
            let converted = results
                .into_iter()
                .map(|r| {
                    let outcome = match r.outcome {
                        EmbeddingOutcomeDto::Done { vectors, times_ms } => EmbeddingOutcome::Done { vectors, times_ms },
                        EmbeddingOutcomeDto::Failed { class, message } => EmbeddingOutcome::Failed { class, message },
                    };
                    (r.job_id, outcome)
                })
                .collect();
            let r = e.submit_embedding_results(batch_id, converted)?;
            Ok(EmbeddingReportDto {
                committed: r.committed,
                discarded: r.discarded,
                failed: r.failed,
                retried: r.retried,
                released: r.released,
            })
        })
        .await
    }

    /// S2: the closest scene's time for the files of `asset_ids` that search by meaning added to this search.
    pub async fn moments(&self, query: SearchQuery, vector: Vec<f32>, asset_ids: Vec<i64>) -> BridgeResult<Vec<MomentDto>> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(e.moments(&query, &vector, &asset_ids)?.into_iter().map(|(asset_id, moment_ms)| MomentDto { asset_id, moment_ms }).collect())
        })
        .await
    }

    /// S2: where a video's scenes start, in milliseconds.
    pub async fn scene_times(&self, asset_id: i64) -> BridgeResult<Vec<i64>> {
        let e = self.engine.clone();
        blocking(move || e.scene_times(AssetId(asset_id))).await
    }

    // ---- labels (Phase 4, C1 and C2) ----

    /// Announces the label words with the vectors the model made of them, and the model's measured cut-off.
    pub fn set_labels(&self, names: Vec<String>, vectors: Vec<Vec<f32>>, cut: f32) {
        self.engine.set_labels(names.into_iter().zip(vectors).collect(), cut);
    }

    /// The words a file shows, closest first (at most five); empty without a model or a description.
    pub async fn labels_of(&self, asset_id: i64) -> BridgeResult<Vec<LabelScoreDto>> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(e.labels_of(AssetId(asset_id))?.into_iter().map(|l| LabelScoreDto { name: l.name, score: l.score }).collect())
        })
        .await
    }

    /// What kind of picture a file is, from facts about it; None when no fact says.
    pub async fn picture_content(&self, asset_id: i64) -> BridgeResult<Option<PictureContentDto>> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(e.picture_content(AssetId(asset_id))?.map(|c| match c {
                sa_engine::PictureContent::Camera => PictureContentDto::Camera,
                sa_engine::PictureContent::ScreenCapture => PictureContentDto::ScreenCapture,
                sa_engine::PictureContent::TextDocument => PictureContentDto::TextDocument,
            }))
        })
        .await
    }

    // ---- text in pictures (Phase 4, S4) ----

    /// Announces the text reader that is ready (e.g. `vision-accurate-en-v1`). From now on pictures and videos are read.
    pub fn set_text_reader(&self, reader: String) {
        self.engine.set_text_reader(&reader);
    }

    /// The reader went away: no more text is read. Text already read stays searchable.
    pub fn clear_text_reader(&self) {
        self.engine.clear_text_reader();
    }

    pub async fn text_status(&self) -> BridgeResult<TextStatusDto> {
        let e = self.engine.clone();
        blocking(move || {
            let s = e.text_status()?;
            Ok(TextStatusDto { reader: s.reader, read: s.read, remaining: s.remaining })
        })
        .await
    }

    /// The words read in a file; `None` if it has not been read yet, empty if it shows none.
    pub async fn text_of(&self, asset_id: i64) -> BridgeResult<Option<String>> {
        let e = self.engine.clone();
        blocking(move || e.text_of(AssetId(asset_id))).await
    }

    /// Leases up to `max_items` pictures and videos for the text reader.
    pub async fn next_text_batch(&self, max_items: u32) -> BridgeResult<TextResponse> {
        let e = self.engine.clone();
        blocking(move || {
            Ok(match e.next_text_batch(max_items)? {
                TextTasks::Empty => TextResponse::Empty,
                TextTasks::Held(reason) => TextResponse::Held { reason },
                TextTasks::Batch(b) => TextResponse::Batch {
                    batch: TextBatchDto {
                        batch_id: b.batch_id,
                        parallelism: b.parallelism,
                        tasks: b
                            .tasks
                            .into_iter()
                            .map(|t| TextTaskDto {
                                job_id: t.job_id,
                                asset_id: t.asset_id,
                                path: t.path,
                                kind: t.kind,
                                ext: t.ext,
                                thumb_path: t.thumb_path,
                                attempt: t.attempt,
                            })
                            .collect(),
                    },
                },
            })
        })
        .await
    }

    /// Commits a batch of text in one transaction. Results about a file that changed are thrown away.
    pub async fn submit_text_results(&self, batch_id: u64, results: Vec<TextResultDto>) -> BridgeResult<TextReportDto> {
        let e = self.engine.clone();
        blocking(move || {
            let converted = results
                .into_iter()
                .map(|r| {
                    let outcome = match r.outcome {
                        TextOutcomeDto::Done { text } => TextOutcome::Done(text),
                        TextOutcomeDto::Failed { class, message } => TextOutcome::Failed { class, message },
                    };
                    (r.job_id, outcome)
                })
                .collect();
            let r = e.submit_text_results(batch_id, converted)?;
            Ok(TextReportDto {
                committed: r.committed,
                discarded: r.discarded,
                failed: r.failed,
                retried: r.retried,
                released: r.released,
            })
        })
        .await
    }

    /// Every group of exact and similar copies, and how much is still being compared. Read-only.
    pub async fn duplicates(&self) -> BridgeResult<DuplicatesDto> {
        let e = self.engine.clone();
        blocking(move || e.duplicates().map(|d| DuplicatesDto::from(&d))).await
    }

    /// Step 1 of cleanup: prepare the review for one group. Nothing is moved.
    pub async fn plan_cleanup(&self, group_key: String, remove_ids: Vec<i64>) -> BridgeResult<CleanupPlanDto> {
        let e = self.engine.clone();
        blocking(move || e.plan_cleanup(&group_key, &ids(&remove_ids)).map(|p| CleanupPlanDto::from(&p))).await
    }

    /// Step 2: the user confirmed. Returns the files that may be moved to the Trash, after checking each against the
    /// disk again. Anything not in the review is refused.
    pub async fn approve_cleanup(&self, token: String, confirmed_ids: Vec<i64>) -> BridgeResult<Vec<ApprovedTrashDto>> {
        let e = self.engine.clone();
        blocking(move || {
            e.approve_cleanup(&token, &ids(&confirmed_ids)).map(|list| {
                list.into_iter().map(|a| ApprovedTrashDto { asset_id: a.asset_id, path: path_string(&a.path) }).collect()
            })
        })
        .await
    }

    /// The user closed the review without confirming.
    pub fn cancel_cleanup(&self, token: String) {
        self.engine.cancel_cleanup(&token);
    }

    /// Step 3: these approved files were moved to the Trash. Their records leave the library; ratings, tags and
    /// collections move to the copy that stays.
    pub async fn cleanup_done(&self, token: String, trashed_ids: Vec<i64>) -> BridgeResult<CleanupSummaryDto> {
        let e = self.engine.clone();
        blocking(move || {
            e.cleanup_done(&token, &ids(&trashed_ids))
                .map(|s| CleanupSummaryDto { removed: s.removed as u64, bytes: s.bytes })
        })
        .await
    }
}
