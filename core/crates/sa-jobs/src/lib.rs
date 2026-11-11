//! The job manager (plan §6.6): who may run now, how much, and what happens when workers come and go.
//!
//! Persistence lives in `sa-store`; this crate is policy. Workers **pull** batches (plan §6.3), every batch holds
//! leases that expire if the worker dies, can be revoked, and its results commit in one transaction.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod manager;
mod policy;

pub use manager::{BatchInfo, LeaseOutcome, Manager};
pub use policy::{
    Conditions, Gate, MemoryPressure, PauseReason, Settings, Thermal, Throttle, backoff_ms, gate,
};
