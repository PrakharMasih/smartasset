//! Row types returned by the repositories.

use sa_core::{AspectClass, AssetId, ColorLabel, FolderId, Flag, MediaKind, VolumeId};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeRow {
    pub id: VolumeId,
    pub uuid: String,
    pub name: String,
    pub mount_path: Option<String>,
    pub is_internal: bool,
    pub is_online: bool,
    pub last_seen_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanState {
    Pending = 0,
    Scanning = 1,
    Idle = 2,
    Error = 3,
}

impl ScanState {
    #[must_use]
    pub const fn from_db(v: i64) -> Self {
        match v {
            1 => Self::Scanning,
            2 => Self::Idle,
            3 => Self::Error,
            _ => Self::Pending,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderRow {
    pub id: FolderId,
    pub volume_id: VolumeId,
    /// Relative to the volume mount point.
    pub rel_path: String,
    pub display_name: String,
    pub bookmark: Option<Vec<u8>>,
    pub enabled: bool,
    pub added_at: i64,
    pub last_scan_at: Option<i64>,
    pub scan_state: ScanState,
    pub last_error: Option<String>,
}

impl FolderRow {
    /// Absolute path of the folder root, or `None` while its drive is unplugged.
    #[must_use]
    pub fn root(&self, volume: &VolumeRow) -> Option<PathBuf> {
        if !volume.is_online {
            return None;
        }
        let mount = volume.mount_path.as_deref()?;
        Some(if self.rel_path.is_empty() {
            PathBuf::from(mount)
        } else {
            PathBuf::from(mount).join(&self.rel_path)
        })
    }
}

/// A folder with the figures the folder list shows (plan L1a).
#[derive(Debug, Clone)]
pub struct FolderInfo {
    pub folder: FolderRow,
    pub volume: VolumeRow,
    pub asset_count: i64,
    pub missing_count: i64,
    pub total_size: i64,
    /// Assets still waiting for metadata and a thumbnail.
    pub pending_count: i64,
    pub excludes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssetStatus {
    Present = 0,
    Missing = 1,
}

impl AssetStatus {
    #[must_use]
    pub const fn from_db(v: i64) -> Self {
        if v == 1 { Self::Missing } else { Self::Present }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeState {
    Pending = 0,
    Ok = 1,
    Failed = 2,
}

impl ProbeState {
    #[must_use]
    pub const fn from_db(v: i64) -> Self {
        match v {
            1 => Self::Ok,
            2 => Self::Failed,
            _ => Self::Pending,
        }
    }
}

/// A file found on disk by a scan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannedFile {
    /// Relative to the folder root, forward slashes.
    pub rel_path: String,
    pub kind: MediaKind,
    pub size: i64,
    pub mtime: i64,
    pub quick_hash: [u8; 16],
}

/// What the scanner needs to know about an asset it already has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssetFileRow {
    pub id: AssetId,
    pub rel_path: String,
    pub size: i64,
    pub mtime: i64,
    pub quick_hash: [u8; 16],
    pub status: AssetStatus,
}

/// A missing asset that a newly found file might be the moved copy of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelinkCandidate {
    pub id: AssetId,
    pub folder_id: FolderId,
    pub rel_path: String,
    pub mtime: i64,
    pub content_hash: Option<Vec<u8>>,
}

/// One tile in the grid or row in the list (plan V1, V6).
#[derive(Debug, Clone, PartialEq)]
pub struct AssetSummary {
    pub id: AssetId,
    pub folder_id: FolderId,
    pub name: String,
    pub ext: String,
    pub kind: MediaKind,
    pub size: i64,
    pub mtime: i64,
    pub added_at: i64,
    pub sort_date: i64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub aspect_class: Option<AspectClass>,
    pub duration_ms: Option<i64>,
    pub thumb_rev: i64,
    pub rating: u8,
    pub flag: Flag,
    pub color_label: ColorLabel,
    pub status: AssetStatus,
    pub probe_state: ProbeState,
    /// False while the drive holding the file is unplugged (plan L4).
    pub volume_online: bool,
    pub volume_name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AssetDetail {
    pub summary: AssetSummary,
    pub rel_path: String,
    pub folder_name: String,
    /// Absolute path, or `None` while the drive is unplugged.
    pub path: Option<PathBuf>,
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

/// What a media worker found out about a file.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProbeResult {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    pub id: i64,
    pub name: String,
    pub asset_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionRow {
    pub id: i64,
    pub name: String,
    pub asset_count: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SmartCollectionRow {
    pub id: i64,
    pub name: String,
    pub query: sa_core::SearchQuery,
}

/// A thumbnail file that belongs to a deleted asset and should be removed from disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThumbKey {
    pub asset_id: i64,
    pub rev: i64,
}
