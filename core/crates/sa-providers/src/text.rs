//! The text-reading contract (Phase 4, S4): find the words shown in a picture, or in a few frames of a video, so a
//! keyword search finds a screenshot, slide or title card by what it says.
//!
//! The worker (Swift, Vision) decodes and reads. Rust only receives the text, tidies it and stores it. No media bytes
//! cross the bridge: the task carries paths.

use sa_core::{ErrorClass, MediaKind};

/// One picture or video for a worker to read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextTask {
    pub job_id: i64,
    pub asset_id: i64,
    /// Absolute path of the original (read-only). Small print needs more pixels than the grid thumbnail has.
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail, for a picture whose original cannot be decoded by the reader.
    pub thumb_path: Option<String>,
    pub attempt: u32,
    /// Size and modification time when leased; results are discarded if the file changed since.
    pub size: i64,
    pub mtime: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextOutcome {
    /// The words found, in reading order (empty when the picture shows none: that is not a failure).
    Done(String),
    Failed { class: ErrorClass, message: String },
}

pub trait TextProvider: Send + Sync {
    fn process(&self, task: &TextTask) -> TextOutcome;
}

/// A stand-in for tests. The file's bytes are read as text; every word that follows `says=` is "shown" in it.
#[derive(Debug, Default, Clone, Copy)]
pub struct FakeTextProvider;

impl TextProvider for FakeTextProvider {
    fn process(&self, task: &TextTask) -> TextOutcome {
        let Ok(bytes) = std::fs::read(&task.path) else {
            return TextOutcome::Failed { class: ErrorClass::Transient, message: "cannot read".into() };
        };
        let text = String::from_utf8_lossy(&bytes);
        let words: Vec<&str> = text.split_whitespace().filter_map(|w| w.strip_prefix("says=")).collect();
        TextOutcome::Done(words.join(" "))
    }
}
