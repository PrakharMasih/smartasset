//! Query execution: keyword search (FTS5) plus metadata filters and sorting (plan S10, S12).
//!
//! Semantic and hybrid retrieval join this crate in milestone M2; the entry point and result shape stay the same
//! so nothing above it changes.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod explain;
mod fts;
mod sql;
mod stats;

pub use explain::{Field, WordHit, explain, words};
pub use fts::fts_match_expression;
pub use sql::{SearchPlan, plan, run};
pub use stats::{LibraryStats, stats};
