//! Types that cross the bridge.
//!
//! Query-side types come from `sa-core` and are declared "remote" so Swift gets them without a second copy.
//! Output types are flat records with plain `i64` ids. Nothing here carries media bytes (plan §6.3).

use sa_core::{
    AspectClass, ColorLabel, DateRange, ErrorClass, Filters, Flag, MediaKind, MissingFilter, Orientation,
    ResolutionClass, SearchQuery, Sort, SortKey,
};
use sa_jobs::{Conditions, MemoryPressure, PauseReason, Thermal};
use sa_store::model::{
    AssetDetail, AssetStatus, AssetSummary, CollectionRow, FolderInfo, ProbeResult, ProbeState, ScanState,
    SmartCollectionRow, Tag, VolumeRow,
};

// ---- remote declarations (the real types live in sa-core / sa-jobs) ----

#[uniffi::remote(Enum)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
}

#[uniffi::remote(Enum)]
pub enum Orientation {
    Horizontal,
    Vertical,
    Square,
}

#[uniffi::remote(Enum)]
pub enum AspectClass {
    Other,
    Square1x1,
    Wide16x9,
    Vertical9x16,
    Standard4x3,
    Portrait3x4,
    Photo3x2,
    Portrait2x3,
    Landscape5x4,
    Portrait4x5,
    Ultrawide21x9,
}

#[uniffi::remote(Enum)]
pub enum Flag {
    None,
    Pick,
    Reject,
}

#[uniffi::remote(Enum)]
pub enum ColorLabel {
    None,
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Gray,
}

#[uniffi::remote(Enum)]
pub enum ResolutionClass {
    Hd720,
    Fhd1080,
    Qhd1440,
    Uhd4k,
    Uhd8k,
}

#[uniffi::remote(Enum)]
pub enum MissingFilter {
    Hide,
    Include,
    Only,
}

#[uniffi::remote(Enum)]
pub enum SortKey {
    Relevance,
    Name,
    DateCaptured,
    DateAdded,
    DateModified,
    Size,
    Duration,
    Rating,
    Kind,
    Manual,
}

#[uniffi::remote(Record)]
pub struct DateRange {
    pub from: Option<i64>,
    pub to: Option<i64>,
}

#[uniffi::remote(Record)]
pub struct Sort {
    pub key: SortKey,
    pub descending: bool,
}

#[uniffi::remote(Record)]
pub struct Filters {
    pub kinds: Vec<MediaKind>,
    pub date: Option<DateRange>,
    pub min_duration_ms: Option<i64>,
    pub max_duration_ms: Option<i64>,
    pub min_resolution: Option<ResolutionClass>,
    pub orientations: Vec<Orientation>,
    pub tags_all: Vec<String>,
    pub tags_any: Vec<String>,
    pub min_rating: Option<u8>,
    pub unrated_only: bool,
    pub flag: Option<Flag>,
    pub color_labels: Vec<ColorLabel>,
    pub folder_ids: Vec<i64>,
    pub volume_ids: Vec<i64>,
    pub collection_id: Option<i64>,
    pub missing: MissingFilter,
}

#[uniffi::remote(Record)]
pub struct SearchQuery {
    pub text: Option<String>,
    pub filters: Filters,
    pub sort: Sort,
}

#[uniffi::remote(Enum)]
pub enum PauseReason {
    User,
    Battery,
    Thermal,
    Memory,
}

#[uniffi::remote(Enum)]
pub enum Thermal {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[uniffi::remote(Enum)]
pub enum MemoryPressure {
    Normal,
    Warning,
    Critical,
}

#[uniffi::remote(Record)]
pub struct Conditions {
    pub on_battery: bool,
    pub low_power_mode: bool,
    pub thermal: Thermal,
    pub memory: MemoryPressure,
    pub user_active: bool,
}

#[uniffi::remote(Enum)]
pub enum ErrorClass {
    Transient,
    FileCorrupt,
    Unsupported,
    ModelFailure,
    Permission,
}

// ---- errors ----

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{message}")]
    NotFound { message: String },
    #[error("{message}")]
    Invalid { message: String },
    #[error("{message}")]
    Database { message: String },
    #[error("{message}")]
    Io { message: String },
    #[error("cancelled")]
    Cancelled,
    /// The library was written by a newer version of SmartAsset.
    #[error("{message}")]
    SchemaTooNew { message: String },
    #[error("{message}")]
    Corrupt { message: String },
    /// A rule from plan §3 stopped the action.
    #[error("{message}")]
    Refused { message: String },
    /// A bug in the core. Nothing panics across the bridge; it arrives as this.
    #[error("{message}")]
    Internal { message: String },
}

impl From<sa_core::Error> for BridgeError {
    fn from(e: sa_core::Error) -> Self {
        // Refusals, bad input and "not found" are written as sentences for the person who sees them: pass them on
        // as they are, without the technical prefix the error type adds.
        let message = match &e {
            sa_core::Error::Refused(m) | sa_core::Error::Invalid(m) | sa_core::Error::NotFound(m) => m.clone(),
            _ => e.to_string(),
        };
        match e {
            sa_core::Error::NotFound(_) => Self::NotFound { message },
            sa_core::Error::Invalid(_) => Self::Invalid { message },
            sa_core::Error::Db(_) => Self::Database { message },
            sa_core::Error::Io { .. } => Self::Io { message },
            sa_core::Error::Cancelled => Self::Cancelled,
            sa_core::Error::SchemaTooNew { .. } => Self::SchemaTooNew { message },
            sa_core::Error::Corrupt(_) => Self::Corrupt { message },
            sa_core::Error::Refused(_) => Self::Refused { message },
        }
    }
}

// ---- engine setup ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineOptions {
    /// `~/Library/Application Support/SmartAsset/` (a temp folder in tests).
    pub data_dir: String,
    /// Parallel decodes the media worker may run at full speed.
    pub worker_parallelism: u32,
    /// Watch added folders for live updates (plan L2).
    pub watch: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct OpenInfoDto {
    pub schema_before: i64,
    pub schema_after: i64,
    pub unclean_exit: bool,
    pub database_problem: Option<String>,
    pub asset_count: i64,
}

// ---- folders and volumes ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct MountedVolumeDto {
    pub uuid: String,
    pub name: String,
    pub mount_path: String,
    pub is_internal: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AddFolderRequestDto {
    pub path: String,
    pub bookmark: Option<Vec<u8>>,
    pub volume: MountedVolumeDto,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AddFolderOutcomeDto {
    Added { id: i64, absorbed: Vec<i64> },
    AlreadyAdded { id: i64 },
    InsideExisting { folder_id: i64, folder_name: String, excluded: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanStateDto {
    Pending,
    Scanning,
    Idle,
    Error,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FolderDto {
    pub id: i64,
    pub volume_id: i64,
    pub volume_uuid: String,
    pub volume_name: String,
    pub volume_online: bool,
    /// Absolute path while the drive is plugged in.
    pub path: Option<String>,
    pub rel_path: String,
    pub display_name: String,
    pub bookmark: Option<Vec<u8>>,
    pub enabled: bool,
    pub asset_count: i64,
    pub missing_count: i64,
    pub pending_count: i64,
    pub total_size: i64,
    pub scan_state: ScanStateDto,
    pub last_error: Option<String>,
    pub last_scan_at: Option<i64>,
    pub excludes: Vec<String>,
}

impl From<&FolderInfo> for FolderDto {
    fn from(i: &FolderInfo) -> Self {
        Self {
            id: i.folder.id.0,
            volume_id: i.volume.id.0,
            volume_uuid: i.volume.uuid.clone(),
            volume_name: i.volume.name.clone(),
            volume_online: i.volume.is_online,
            path: i.folder.root(&i.volume).map(|p| p.to_string_lossy().into_owned()),
            rel_path: i.folder.rel_path.clone(),
            display_name: i.folder.display_name.clone(),
            bookmark: i.folder.bookmark.clone(),
            enabled: i.folder.enabled,
            asset_count: i.asset_count,
            missing_count: i.missing_count,
            pending_count: i.pending_count,
            total_size: i.total_size,
            scan_state: match i.folder.scan_state {
                ScanState::Pending => ScanStateDto::Pending,
                ScanState::Scanning => ScanStateDto::Scanning,
                ScanState::Idle => ScanStateDto::Idle,
                ScanState::Error => ScanStateDto::Error,
            },
            last_error: i.folder.last_error.clone(),
            last_scan_at: i.folder.last_scan_at,
            excludes: i.excludes.clone(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct VolumeDto {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    pub mount_path: Option<String>,
    pub is_internal: bool,
    pub is_online: bool,
}

impl From<&VolumeRow> for VolumeDto {
    fn from(v: &VolumeRow) -> Self {
        Self {
            id: v.id.0,
            uuid: v.uuid.clone(),
            name: v.name.clone(),
            mount_path: v.mount_path.clone(),
            is_internal: v.is_internal,
            is_online: v.is_online,
        }
    }
}

// ---- assets ----

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProbeStateDto {
    Pending,
    Ok,
    Failed,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetSummaryDto {
    pub id: i64,
    pub folder_id: i64,
    pub name: String,
    pub ext: String,
    pub kind: MediaKind,
    pub size: i64,
    pub mtime: i64,
    pub added_at: i64,
    pub sort_date: i64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub aspect: Option<AspectClass>,
    pub duration_ms: Option<i64>,
    /// 0 until a thumbnail exists; part of the thumbnail's file name, so it is also a cache key.
    pub thumb_rev: i64,
    pub rating: u8,
    pub flag: Flag,
    pub color_label: ColorLabel,
    /// The file has disappeared from disk.
    pub missing: bool,
    pub probe_state: ProbeStateDto,
    /// False while the drive holding the file is unplugged (plan L4).
    pub volume_online: bool,
    pub volume_name: String,
}

impl From<&AssetSummary> for AssetSummaryDto {
    fn from(a: &AssetSummary) -> Self {
        Self {
            id: a.id.0,
            folder_id: a.folder_id.0,
            name: a.name.clone(),
            ext: a.ext.clone(),
            kind: a.kind,
            size: a.size,
            mtime: a.mtime,
            added_at: a.added_at,
            sort_date: a.sort_date,
            width: a.width,
            height: a.height,
            aspect: a.aspect_class,
            duration_ms: a.duration_ms,
            thumb_rev: a.thumb_rev,
            rating: a.rating,
            flag: a.flag,
            color_label: a.color_label,
            missing: a.status == AssetStatus::Missing,
            probe_state: match a.probe_state {
                ProbeState::Pending => ProbeStateDto::Pending,
                ProbeState::Ok => ProbeStateDto::Ok,
                ProbeState::Failed => ProbeStateDto::Failed,
            },
            volume_online: a.volume_online,
            volume_name: a.volume_name.clone(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetDetailDto {
    pub summary: AssetSummaryDto,
    pub rel_path: String,
    pub folder_name: String,
    pub path: Option<String>,
    pub codec: Option<String>,
    pub fps: Option<f64>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub bitrate: Option<i64>,
    pub capture_at: Option<i64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub lens: Option<String>,
    pub gps_lat: Option<f64>,
    pub gps_lon: Option<f64>,
    pub exif_json: Option<String>,
    pub notes: String,
    pub tags: Vec<String>,
    pub content_hash_hex: Option<String>,
}

impl From<&AssetDetail> for AssetDetailDto {
    fn from(d: &AssetDetail) -> Self {
        Self {
            summary: (&d.summary).into(),
            rel_path: d.rel_path.clone(),
            folder_name: d.folder_name.clone(),
            path: d.path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            codec: d.codec.clone(),
            fps: d.fps,
            sample_rate: d.sample_rate,
            channels: d.channels,
            bitrate: d.bitrate,
            capture_at: d.capture_at,
            camera_make: d.camera_make.clone(),
            camera_model: d.camera_model.clone(),
            lens: d.lens.clone(),
            gps_lat: d.gps_lat,
            gps_lon: d.gps_lon,
            exif_json: d.exif_json.clone(),
            notes: d.notes.clone(),
            tags: d.tags.clone(),
            content_hash_hex: d.content_hash_hex.clone(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetPathDto {
    pub asset_id: i64,
    /// `None` while the drive is unplugged.
    pub path: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LibraryStatsDto {
    pub total: i64,
    pub images: i64,
    pub videos: i64,
    pub audio: i64,
    pub missing: i64,
    pub total_size: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TagDto {
    pub id: i64,
    pub name: String,
    pub asset_count: i64,
}

impl From<&Tag> for TagDto {
    fn from(t: &Tag) -> Self {
        Self { id: t.id, name: t.name.clone(), asset_count: t.asset_count }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CollectionDto {
    pub id: i64,
    pub name: String,
    pub asset_count: i64,
}

impl From<&CollectionRow> for CollectionDto {
    fn from(c: &CollectionRow) -> Self {
        Self { id: c.id, name: c.name.clone(), asset_count: c.asset_count }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SmartCollectionDto {
    pub id: i64,
    pub name: String,
    pub query: SearchQuery,
}

impl From<&SmartCollectionRow> for SmartCollectionDto {
    fn from(c: &SmartCollectionRow) -> Self {
        Self { id: c.id, name: c.name.clone(), query: c.query.clone() }
    }
}

// ---- events and progress ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProgressDto {
    pub scanning: bool,
    pub files_discovered: u64,
    pub media_total: i64,
    pub media_done: i64,
    pub media_failed: i64,
    pub media_remaining: i64,
    /// Files still waiting to be compared for duplicates.
    pub dedupe_remaining: i64,
    /// Files still waiting for their vector (search by meaning).
    pub embed_remaining: i64,
    pub hold: Option<PauseReason>,
    pub eta_seconds: Option<u64>,
}

impl From<&sa_engine::Progress> for ProgressDto {
    fn from(p: &sa_engine::Progress) -> Self {
        Self {
            scanning: p.scanning,
            files_discovered: p.files_discovered,
            media_total: p.media_total,
            media_done: p.media_done,
            media_failed: p.media_failed,
            media_remaining: p.media_remaining,
            dedupe_remaining: p.dedupe_remaining,
            embed_remaining: p.embed_remaining,
            hold: p.hold,
            eta_seconds: p.eta_seconds,
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum NoticeDto {
    FolderLooksEmpty { folder_id: i64, folder_name: String },
    FolderUnreadable { folder_id: i64, folder_name: String, message: String },
    CloudFilesSkipped { folder_id: i64, folder_name: String, count: u64 },
    DatabaseProblem { message: String },
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum EngineEvent {
    LibraryChanged { structural: bool },
    ThumbnailsReady { asset_ids: Vec<i64> },
    FoldersChanged,
    /// Files were compared or removed; the Duplicates page may have something new.
    DuplicatesChanged,
    Progress { progress: ProgressDto },
    Notice { notice: NoticeDto },
}

impl From<&sa_engine::Event> for EngineEvent {
    fn from(e: &sa_engine::Event) -> Self {
        use sa_engine::{Event, Notice};
        match e {
            Event::LibraryChanged { structural } => Self::LibraryChanged { structural: *structural },
            Event::ThumbnailsReady { asset_ids } => Self::ThumbnailsReady { asset_ids: asset_ids.clone() },
            Event::FoldersChanged => Self::FoldersChanged,
            Event::DuplicatesChanged => Self::DuplicatesChanged,
            Event::Progress(p) => Self::Progress { progress: p.into() },
            Event::Notice(n) => Self::Notice {
                notice: match n {
                    Notice::FolderLooksEmpty { folder_id, folder_name } => {
                        NoticeDto::FolderLooksEmpty { folder_id: *folder_id, folder_name: folder_name.clone() }
                    }
                    Notice::FolderUnreadable { folder_id, folder_name, message } => NoticeDto::FolderUnreadable {
                        folder_id: *folder_id,
                        folder_name: folder_name.clone(),
                        message: message.clone(),
                    },
                    Notice::CloudFilesSkipped { folder_id, folder_name, count } => NoticeDto::CloudFilesSkipped {
                        folder_id: *folder_id,
                        folder_name: folder_name.clone(),
                        count: *count,
                    },
                    Notice::DatabaseProblem { message } => NoticeDto::DatabaseProblem { message: message.clone() },
                },
            },
        }
    }
}

/// Implemented in Swift. Called on an engine thread; must return quickly.
#[uniffi::export(with_foreign)]
pub trait EngineListener: Send + Sync {
    fn on_event(&self, event: EngineEvent);
}

// ---- the worker contract (plan §6.3) ----

/// One file for a worker. Paths and parameters only, never bytes.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaTaskDto {
    pub job_id: i64,
    pub asset_id: i64,
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// Write the JPEG thumbnail here. The folder exists.
    pub thumb_path: String,
    pub thumb_rev: i64,
    pub max_edge: u32,
    pub attempt: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaBatchDto {
    pub batch_id: u64,
    pub tasks: Vec<MediaTaskDto>,
    /// How many items to process at once right now.
    pub parallelism: u32,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum BatchResponse {
    Batch { batch: MediaBatchDto },
    /// Work exists but must not run right now.
    Held { reason: PauseReason },
    Empty,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ProbeDto {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<i64>,
    pub codec: Option<String>,
    pub fps: Option<f64>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub bitrate: Option<i64>,
    pub capture_at: Option<i64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub lens: Option<String>,
    pub gps_lat: Option<f64>,
    pub gps_lon: Option<f64>,
    pub exif_json: Option<String>,
}

impl From<ProbeDto> for ProbeResult {
    fn from(p: ProbeDto) -> Self {
        Self {
            width: p.width,
            height: p.height,
            duration_ms: p.duration_ms,
            codec: p.codec,
            fps: p.fps,
            sample_rate: p.sample_rate,
            channels: p.channels,
            bitrate: p.bitrate,
            capture_at: p.capture_at,
            camera_make: p.camera_make,
            camera_model: p.camera_model,
            lens: p.lens,
            gps_lat: p.gps_lat,
            gps_lon: p.gps_lon,
            exif_json: p.exif_json,
        }
    }
}

// A short-lived bridge value; boxing the probe would change the generated Swift API for no gain.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, uniffi::Enum)]
pub enum MediaOutcomeDto {
    Done { probe: ProbeDto, thumb_written: bool },
    Failed { class: ErrorClass, message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaResultDto {
    pub job_id: i64,
    pub outcome: MediaOutcomeDto,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct SubmitReportDto {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

impl From<sa_engine::SubmitReport> for SubmitReportDto {
    fn from(r: sa_engine::SubmitReport) -> Self {
        Self { committed: r.committed, discarded: r.discarded, failed: r.failed, retried: r.retried, released: r.released }
    }
}

// ---- perceptual hashes: the second worker contract (plan A2) ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct PerceptualTaskDto {
    pub job_id: i64,
    pub asset_id: i64,
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail, when there is one. For a picture, hash this instead of the original.
    pub thumb_path: Option<String>,
    pub attempt: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PerceptualBatchDto {
    pub batch_id: u64,
    pub tasks: Vec<PerceptualTaskDto>,
    pub parallelism: u32,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum PerceptualResponse {
    Batch { batch: PerceptualBatchDto },
    Held { reason: PauseReason },
    Empty,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PerceptualHashDto {
    pub dhash: u64,
    pub phash: u64,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum PerceptualOutcomeDto {
    /// One hash per sampled picture. Empty: too plain to describe (not a failure).
    Done { hashes: Vec<PerceptualHashDto> },
    Failed { class: ErrorClass, message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PerceptualResultDto {
    pub job_id: i64,
    pub outcome: PerceptualOutcomeDto,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PerceptualReportDto {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

/// S2: a result's closest scene.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct MomentDto {
    pub asset_id: i64,
    pub moment_ms: i64,
}

// ---- labels (Phase 4, C1 and C2) ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct LabelScoreDto {
    pub name: String,
    pub score: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PictureContentDto {
    Camera,
    ScreenCapture,
    TextDocument,
}

// ---- text in pictures: the fourth worker contract (Phase 4, S4) ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct TextTaskDto {
    pub job_id: i64,
    pub asset_id: i64,
    /// The original (read-only): small print needs its pixels.
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail, for a picture the reader cannot decode itself.
    pub thumb_path: Option<String>,
    pub attempt: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TextBatchDto {
    pub batch_id: u64,
    pub tasks: Vec<TextTaskDto>,
    pub parallelism: u32,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum TextResponse {
    Batch { batch: TextBatchDto },
    Held { reason: PauseReason },
    Empty,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum TextOutcomeDto {
    /// The words found, in reading order. Empty: the picture shows none (not a failure).
    Done { text: String },
    Failed { class: ErrorClass, message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TextResultDto {
    pub job_id: i64,
    pub outcome: TextOutcomeDto,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TextReportDto {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TextStatusDto {
    /// The announced reader, if one is ready.
    pub reader: Option<String>,
    /// Pictures and videos read (with or without text).
    pub read: i64,
    pub remaining: i64,
}

// ---- embeddings: the third worker contract (Phase 4, search by meaning) ----

/// Everything that decides what a vector means. Two configurations never share vectors.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelConfigDto {
    /// Names the other fields, e.g. `embeddinggemma2-mlx-q8-768-thumb512-v1`.
    pub id: String,
    pub model: String,
    pub version: String,
    pub modality: String,
    pub dims: u32,
    pub preprocessing: String,
    /// The best match must be at least this similar (cosine) for the library to count as answering the question.
    /// Measured for this configuration; see `docs/research/phase4-semantic-search.md`.
    pub min_match: f32,
    /// Files within this much of the best match are kept.
    pub band: f32,
    /// A2: the cosine a file must reach against the first file of a group of similar copies to stay in it; None when
    /// this model's cut-off was never measured (groups are then not confirmed).
    pub copy_match: Option<f32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EmbeddingTaskDto {
    pub job_id: i64,
    pub asset_id: i64,
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail: embed this instead of the original.
    pub thumb_path: Option<String>,
    /// A video's hover-scrub strip: a row of frames in time order, when it has been made.
    pub filmstrip_path: Option<String>,
    pub attempt: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EmbeddingBatchDto {
    pub batch_id: u64,
    pub tasks: Vec<EmbeddingTaskDto>,
    pub parallelism: u32,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum EmbeddingResponse {
    Batch { batch: EmbeddingBatchDto },
    Held { reason: PauseReason },
    Empty,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum EmbeddingOutcomeDto {
    /// One vector for a picture; one per scene used, in time order, for a video. Raw model output. `times_ms` is
    /// where in the video each vector is (same length), empty for a picture.
    Done { vectors: Vec<Vec<f32>>, times_ms: Vec<i64> },
    Failed { class: ErrorClass, message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EmbeddingResultDto {
    pub job_id: i64,
    pub outcome: EmbeddingOutcomeDto,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct EmbeddingReportDto {
    pub committed: u32,
    pub discarded: u32,
    pub failed: u32,
    pub retried: u32,
    pub released: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EmbeddingStatusDto {
    /// The announced model configuration, if a model is ready.
    pub config: Option<String>,
    pub with_vectors: i64,
    pub remaining: i64,
}

/// One raw answer of search by meaning: a file and how close its vector is to the question's (cosine, -1 to 1).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct SemanticHitDto {
    pub asset_id: i64,
    pub score: f32,
}

/// The raw answer of search by meaning with the shape of the scores behind it (see `sa_vector::Answer`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SemanticAnswerDto {
    pub hits: Vec<SemanticHitDto>,
    /// Mean and spread of every file's score for this question.
    pub mean: f32,
    pub std: f32,
}

/// Where a typed word was found in a file (S11).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MatchPlace {
    Name,
    Tag,
    Note,
    TextInPicture,
    Folder,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WordMatchDto {
    pub word: String,
    pub place: MatchPlace,
    /// For a note or text in the picture: the few words around the match.
    pub snippet: Option<String>,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct MeaningMatchDto {
    /// Cosine of the question and the file's closest vector.
    pub score: f32,
    /// The score reaches the model's minimum best match.
    pub strong: bool,
    /// For a video: where the closest scene is. None for a picture or when the place is unknown.
    pub moment_ms: Option<i64>,
    pub frames: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MatchExplanationDto {
    pub words: Vec<WordMatchDto>,
    pub meaning: Option<MeaningMatchDto>,
}

// ---- duplicates and cleanup (plan A1–A3) ----

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DuplicateKindDto {
    Exact,
    Similar,
}

impl From<sa_engine::DuplicateKind> for DuplicateKindDto {
    fn from(k: sa_engine::DuplicateKind) -> Self {
        match k {
            sa_engine::DuplicateKind::Exact => Self::Exact,
            sa_engine::DuplicateKind::Similar => Self::Similar,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DuplicateMemberDto {
    pub asset_id: i64,
    pub similarity: u8,
    pub suggested_keep: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DuplicateGroupDto {
    pub key: String,
    pub kind: DuplicateKindDto,
    /// The copy to keep, as suggested, first.
    pub members: Vec<DuplicateMemberDto>,
    pub wasted_bytes: i64,
}

impl From<&sa_engine::DuplicateGroup> for DuplicateGroupDto {
    fn from(g: &sa_engine::DuplicateGroup) -> Self {
        Self {
            key: g.key.clone(),
            kind: g.kind.into(),
            members: g
                .members
                .iter()
                .map(|m| DuplicateMemberDto {
                    asset_id: m.asset_id,
                    similarity: m.similarity,
                    suggested_keep: m.suggested_keep,
                })
                .collect(),
            wasted_bytes: g.wasted_bytes,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DuplicatesDto {
    pub exact: Vec<DuplicateGroupDto>,
    pub similar: Vec<DuplicateGroupDto>,
    pub exact_wasted: i64,
    pub similar_wasted: i64,
    /// Suspected copies still being read in full.
    pub hash_remaining: i64,
    /// Pictures and videos still being described.
    pub perceptual_remaining: i64,
}

impl From<&sa_engine::Duplicates> for DuplicatesDto {
    fn from(d: &sa_engine::Duplicates) -> Self {
        Self {
            exact: d.sets.exact.iter().map(Into::into).collect(),
            similar: d.sets.similar.iter().map(Into::into).collect(),
            exact_wasted: d.sets.exact_wasted,
            similar_wasted: d.sets.similar_wasted,
            hash_remaining: d.hash_remaining,
            perceptual_remaining: d.perceptual_remaining,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CleanupFileDto {
    pub asset_id: i64,
    pub name: String,
    pub path: String,
    pub volume_name: String,
    pub size: i64,
    pub modified_ms: i64,
    pub match_percent: u8,
}

impl From<&sa_engine::CleanupFile> for CleanupFileDto {
    fn from(f: &sa_engine::CleanupFile) -> Self {
        Self {
            asset_id: f.asset_id,
            name: f.name.clone(),
            path: f.path.clone(),
            volume_name: f.volume_name.clone(),
            size: f.size,
            modified_ms: f.modified_ms,
            match_percent: f.match_percent,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CleanupPlanDto {
    pub token: String,
    pub kind: DuplicateKindDto,
    pub remove: Vec<CleanupFileDto>,
    pub keep: Vec<CleanupFileDto>,
    pub bytes: i64,
}

impl From<&sa_engine::CleanupPlan> for CleanupPlanDto {
    fn from(p: &sa_engine::CleanupPlan) -> Self {
        Self {
            token: p.token.clone(),
            kind: p.kind.into(),
            remove: p.remove.iter().map(Into::into).collect(),
            keep: p.keep.iter().map(Into::into).collect(),
            bytes: p.bytes,
        }
    }
}

/// A file Rust agrees may go to the Trash. The Swift side moves these and nothing else.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ApprovedTrashDto {
    pub asset_id: i64,
    pub path: String,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct CleanupSummaryDto {
    pub removed: u64,
    pub bytes: i64,
}

// ---- the matcher, exposed as a pure function so the labeled-set evaluation runs the code the engine runs ----

#[derive(Debug, Clone, uniffi::Record)]
pub struct PerceptualItemDto {
    pub id: i64,
    pub kind: MediaKind,
    pub duration_ms: Option<i64>,
    /// One hash for a picture, one per sampled keyframe for a video.
    pub hashes: Vec<PerceptualHashDto>,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct NearMemberDto {
    pub id: i64,
    pub similarity: u8,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NearGroupDto {
    /// The anchor first.
    pub members: Vec<NearMemberDto>,
}
