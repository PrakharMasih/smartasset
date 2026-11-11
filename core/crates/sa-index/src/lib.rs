//! Discovery and fingerprinting: turns the folders the user added into asset rows (plan L1, L2, L3, §6.6 browse pass).
//!
//! Reads files only to take a few small samples for the quick hash. It never writes, renames, moves or deletes
//! anything it scans (plan §3.2).

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod fingerprint;
mod scan;

pub use fingerprint::{CONTENT_HASH_LEN, HashStop, QUICK_HASH_LEN, content_hash, is_dataless_flags, quick_hash};
pub use scan::{ScanOutcome, ScanProgress, ScanReport, ScanTarget, ScannerPool, scan};
