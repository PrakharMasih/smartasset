//! SQLite storage: the single source of truth for SmartAsset (plan §6.8).
//!
//! Everything else on disk (thumbnails, vector indexes) can be rebuilt from this database.

#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod assets;
pub mod db;
pub mod dedupe;
pub mod embeddings;
pub mod error;
pub mod folders;
pub mod jobs;
pub mod layout;
pub mod migrate;
pub mod model;
pub mod organize;
pub mod settings;
pub mod text;
pub mod util;

pub use db::{Db, OpenReport};
pub use error::DbResultExt;
pub use layout::DataDirs;
