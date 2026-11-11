//! Work contracts (plan §6.3, §6.4): the typed requests and results exchanged with replaceable workers.
//!
//! A worker is anything that can fulfil a contract: a Swift worker over the bridge today, a Rust worker or a fake
//! in tests. Contracts carry **paths and parameters only, never media bytes**; a worker reads the file itself and
//! writes any large output (a thumbnail) to the path it was given.
//!
//! Milestone M1 defines the media contract; M2 adds embedding and text reading (OCR). Transcription arrives with M3.

#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod embedding;
pub mod media;
pub mod perceptual;
pub mod text;

pub use embedding::{
    EmbeddingOutcome, EmbeddingProvider, EmbeddingTask, FakeEmbeddingProvider, fake_text_vector,
};
pub use media::{FakeMediaProvider, MediaOutcome, MediaProbe, MediaProvider, MediaTask};
pub use perceptual::{
    FakePerceptualProvider, PerceptualOutcome, PerceptualProvider, PerceptualTask, VIDEO_SAMPLE_POINTS,
};
pub use text::{FakeTextProvider, TextOutcome, TextProvider, TextTask};
