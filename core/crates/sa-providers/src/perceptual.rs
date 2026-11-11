//! The perceptual-hash contract (plan A2): look at a picture, or a few keyframes of a video, and describe it by two
//! 64-bit hashes that stay close when the picture is resized, re-encoded or lightly edited.
//!
//! The worker (Swift, ImageIO and AVFoundation) does the decoding. Rust only receives the hashes.

use sa_core::{ErrorClass, MediaKind};
use sa_store::dedupe::PerceptualHash;

/// How many keyframes of a video are hashed, and where (fractions of the duration), so two encodes of the same video
/// are always compared frame against frame.
pub const VIDEO_SAMPLE_POINTS: [f64; 3] = [0.2, 0.5, 0.8];

/// One picture or video for a worker to hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PerceptualTask {
    pub job_id: i64,
    pub asset_id: i64,
    /// Absolute path of the original (read-only).
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail, when one exists. For a picture it is much cheaper to read than the original and gives
    /// the same hash, so workers should prefer it.
    pub thumb_path: Option<String>,
    pub attempt: u32,
    /// Size and modification time when leased; results are discarded if the file changed since.
    pub size: i64,
    pub mtime: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PerceptualOutcome {
    /// One hash for a picture; one per sampled keyframe, in time order, for a video. Empty means the picture is too
    /// plain to describe (a black frame, a solid colour): it is never matched, and that is not a failure.
    Done(Vec<PerceptualHash>),
    Failed { class: ErrorClass, message: String },
}

pub trait PerceptualProvider: Send + Sync {
    fn process(&self, task: &PerceptualTask) -> PerceptualOutcome;
}

/// A stand-in for tests. A file whose text contains `p=<number> d=<number>` gets exactly those hashes; any other
/// file gets hashes derived from its bytes (so byte-identical files match and others do not).
#[derive(Debug, Default, Clone, Copy)]
pub struct FakePerceptualProvider;

impl PerceptualProvider for FakePerceptualProvider {
    fn process(&self, task: &PerceptualTask) -> PerceptualOutcome {
        let Ok(bytes) = std::fs::read(&task.path) else {
            return PerceptualOutcome::Failed { class: ErrorClass::Transient, message: "cannot read".into() };
        };
        let text = String::from_utf8_lossy(&bytes);
        let field = |key: &str| {
            text.split_whitespace().find_map(|w| w.strip_prefix(key)).and_then(|v| v.parse::<u64>().ok())
        };
        let hash = if let (Some(p), Some(d)) = (field("p="), field("d=")) {
            PerceptualHash { phash: p, dhash: d }
        } else {
            let digest = blake3::hash(&bytes);
            let word = |i: usize| u64::from_le_bytes(digest.as_bytes()[i..i + 8].try_into().unwrap_or([0; 8]));
            PerceptualHash { phash: word(0), dhash: word(8) }
        };
        let samples = if task.kind == MediaKind::Video { VIDEO_SAMPLE_POINTS.len() } else { 1 };
        PerceptualOutcome::Done(vec![hash; samples])
    }
}
