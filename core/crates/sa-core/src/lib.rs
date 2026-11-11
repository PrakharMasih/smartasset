//! Domain types shared by every SmartAsset crate: ids, errors, media kinds and the search query model.
//!
//! Nothing here touches the disk, the database or a model runtime.

#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod error;
pub mod ids;
pub mod media;
pub mod paths;
pub mod query;
pub mod time;

pub use error::{Error, ErrorClass, Result};
pub use ids::{AssetId, CollectionId, FolderId, JobId, SmartCollectionId, TagId, VolumeId};
pub use media::{AspectClass, MediaKind, Orientation};
pub use query::{
    ColorLabel, DateRange, Filters, Flag, MissingFilter, ResolutionClass, SearchQuery, Sort,
    SortKey,
};
