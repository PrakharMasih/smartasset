//! The media contract: read a file's metadata and write its thumbnail (plan §6.6 browse pass).

use sa_core::{ErrorClass, MediaKind};
use sa_store::model::ProbeResult;
use std::path::Path;

/// Longest edge of a grid thumbnail in pixels. Big enough for a 200 pt tile on a Retina display.
pub const THUMB_MAX_EDGE: u32 = 512;

/// One file for a worker to look at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaTask {
    pub job_id: i64,
    pub asset_id: i64,
    /// Absolute path of the original (read-only).
    pub path: String,
    pub kind: MediaKind,
    /// Lower-case extension without the dot.
    pub ext: String,
    /// Where to write the JPEG thumbnail. The parent directory already exists.
    pub thumb_path: String,
    /// Revision the thumbnail will have once committed.
    pub thumb_rev: i64,
    pub max_edge: u32,
    pub attempt: u32,
    /// Size and modification time when the job was leased; results are discarded if the file changed since.
    pub size: i64,
    pub mtime: i64,
}

/// What a worker found. `thumb_written` is true when the file at `thumb_path` is complete and valid.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MediaProbe {
    pub probe: ProbeResult,
    pub thumb_written: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MediaOutcome {
    Done(Box<MediaProbe>),
    Failed { class: ErrorClass, message: String },
}

pub trait MediaProvider: Send + Sync {
    fn process(&self, task: &MediaTask) -> MediaOutcome;
}

/// Deterministic stand-in for a real worker, used to test the whole pipeline without a decoder.
/// File names decide the outcome: `corrupt*` fails permanently, `flaky*` fails transiently on the first attempt,
/// `unsupported*` reports an unsupported format, `locked*` reports a permission error.
#[derive(Debug, Default, Clone, Copy)]
pub struct FakeMediaProvider;

impl MediaProvider for FakeMediaProvider {
    fn process(&self, task: &MediaTask) -> MediaOutcome {
        let name = Path::new(&task.path).file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.starts_with("corrupt") {
            return MediaOutcome::Failed { class: ErrorClass::FileCorrupt, message: "bad header".into() };
        }
        if name.starts_with("unsupported") {
            return MediaOutcome::Failed { class: ErrorClass::Unsupported, message: "no decoder".into() };
        }
        if name.starts_with("locked") {
            return MediaOutcome::Failed { class: ErrorClass::Permission, message: "access denied".into() };
        }
        if name.starts_with("flaky") && task.attempt < 2 {
            return MediaOutcome::Failed { class: ErrorClass::Transient, message: "disk busy".into() };
        }
        let mut probe = ProbeResult::default();
        match task.kind {
            MediaKind::Image => {
                probe.width = Some(4000);
                probe.height = Some(3000);
            }
            MediaKind::Video => {
                probe.width = Some(1920);
                probe.height = Some(1080);
                probe.duration_ms = Some(12_000);
                probe.fps = Some(25.0);
                probe.codec = Some("avc1".into());
            }
            MediaKind::Audio => {
                probe.duration_ms = Some(180_000);
                probe.sample_rate = Some(48_000);
                probe.channels = Some(2);
            }
        }
        let wrote = std::fs::write(&task.thumb_path, b"\xFF\xD8fake-thumbnail\xFF\xD9").is_ok();
        MediaOutcome::Done(Box::new(MediaProbe { probe, thumb_written: wrote }))
    }
}
