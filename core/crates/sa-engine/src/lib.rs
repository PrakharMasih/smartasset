//! The composition root of the Rust core: wires storage, scanning, watching, jobs and search into one API.
//!
//! No FFI lives here, so the whole pipeline is tested in plain Rust with fake workers. `sa-ffi` is a thin skin
//! over [`Engine`].

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod cleanup;
mod config;
mod duplicates;
mod embedding;
mod engine;
mod events;
mod folders;
mod hasher;
mod labels;
mod notifier;
mod perceptual;
mod scanner;
mod text;
mod workers;

pub use cleanup::{ApprovedTrash, CleanupFile, CleanupPlan, CleanupSummary};
pub use config::EngineConfig;
pub use duplicates::{DuplicateGroup, DuplicateKind, DuplicateMember, Duplicates, GroupSets};
pub use embedding::{
    Calibration, EmbeddingBatch, EmbeddingReport, EmbeddingStatus, EmbeddingTasks, MatchExplanation, MeaningMatch,
};
pub use engine::{Engine, OpenInfo};
pub use events::{Event, EventSink, Notice, Progress};
pub use folders::{AddFolderRequest, MountedVolume};
pub use labels::{LabelScore, MAX_LABELS, PictureContent, TEXT_DOCUMENT_CHARS, content_from};
pub use perceptual::{PerceptualBatch, PerceptualReport, PerceptualTasks};
pub use text::{TextBatch, TextReport, TextStatus, TextTasks};
pub use workers::{BatchTasks, MediaBatch, SubmitReport};

pub use sa_search::{Field as MatchField, WordHit};
pub use sa_jobs::{Conditions, MemoryPressure, PauseReason, Thermal};
