//! The embedding contract (Phase 4): look at a picture, or the frames of a video, and describe each by a vector that
//! lies near the vector of a sentence about it.
//!
//! The worker (Swift, running the model) reads the thumbnail and does the work. Rust only receives the numbers, which
//! it normalises and stores. As everywhere in the contracts, no media bytes cross the bridge: the task carries paths.

use sa_core::{ErrorClass, MediaKind};

/// One picture or video for a worker to embed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddingTask {
    pub job_id: i64,
    pub asset_id: i64,
    /// Absolute path of the original (read-only).
    pub path: String,
    pub kind: MediaKind,
    pub ext: String,
    /// The grid thumbnail. Every task has one: files without a thumbnail are not queued.
    pub thumb_path: Option<String>,
    /// The hover-scrub filmstrip of a video, when one has been made: a row of frames in time order.
    pub filmstrip_path: Option<String>,
    pub attempt: u32,
    /// Size and modification time when leased; results are discarded if the file changed since.
    pub size: i64,
    pub mtime: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EmbeddingOutcome {
    /// One vector for a picture; one per scene used, in time order, for a video. Raw model output: Rust normalises
    /// it and refuses anything that is not a finite, non-zero vector of the configured length. `times_ms` is where in
    /// the video each vector is (same order and length); empty for a picture. A list of another length is ignored
    /// (the places are then unknown), never an error.
    Done { vectors: Vec<Vec<f32>>, times_ms: Vec<i64> },
    Failed { class: ErrorClass, message: String },
}

pub trait EmbeddingProvider: Send + Sync {
    fn process(&self, task: &EmbeddingTask) -> EmbeddingOutcome;
}

/// A stand-in for tests. The file's bytes are read as text; every word that follows `topic=` switches on one axis of
/// the vector (axis = a small number derived from the word), so a query made with [`fake_text_vector`] from the same
/// word lies exactly on it. A file with no `topic=` word gets a vector from a hash of its bytes (it matches nothing
/// in particular).
#[derive(Debug, Clone, Copy)]
pub struct FakeEmbeddingProvider {
    pub dims: usize,
}

impl FakeEmbeddingProvider {
    #[must_use]
    pub fn new(dims: usize) -> Self {
        Self { dims }
    }
}

/// The vector a query for `words` would have under the fake model.
#[must_use]
pub fn fake_text_vector(dims: usize, words: &str) -> Vec<f32> {
    let mut v = vec![0.0_f32; dims];
    for w in words.split_whitespace() {
        v[axis(w, dims)] += 1.0;
    }
    v
}

fn axis(word: &str, dims: usize) -> usize {
    let h = blake3::hash(word.to_lowercase().as_bytes());
    let n = u64::from_le_bytes(h.as_bytes()[..8].try_into().unwrap_or([0; 8]));
    usize::try_from(n % dims as u64).unwrap_or(0)
}

impl EmbeddingProvider for FakeEmbeddingProvider {
    fn process(&self, task: &EmbeddingTask) -> EmbeddingOutcome {
        let Ok(bytes) = std::fs::read(&task.path) else {
            return EmbeddingOutcome::Failed { class: ErrorClass::Transient, message: "cannot read".into() };
        };
        let text = String::from_utf8_lossy(&bytes);
        let topics: Vec<&str> = text.split_whitespace().filter_map(|w| w.strip_prefix("topic=")).collect();
        let vector = if topics.is_empty() {
            let digest = blake3::hash(&bytes);
            let mut v = vec![0.0_f32; self.dims];
            for (i, b) in digest.as_bytes().iter().enumerate() {
                v[i % self.dims] += f32::from(*b) - 127.5;
            }
            v
        } else {
            fake_text_vector(self.dims, &topics.join(" "))
        };
        EmbeddingOutcome::Done { vectors: vec![vector], times_ms: Vec::new() }
    }
}
