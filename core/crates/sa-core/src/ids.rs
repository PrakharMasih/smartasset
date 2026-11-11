//! Typed row ids. Plain `i64` at the SQLite and bridge boundary, distinct types everywhere else.

use serde::{Deserialize, Serialize};
use std::fmt;

macro_rules! id_type {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub i64);

        impl $name {
            #[must_use]
            pub const fn get(self) -> i64 {
                self.0
            }
        }

        impl From<i64> for $name {
            fn from(v: i64) -> Self {
                Self(v)
            }
        }

        impl From<$name> for i64 {
            fn from(v: $name) -> Self {
                v.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}", self.0)
            }
        }
    };
}

id_type!(
    /// A mounted or unplugged disk, identified by its volume UUID.
    VolumeId
);
id_type!(
    /// A folder the user explicitly added.
    FolderId
);
id_type!(
    /// One indexed media file. Survives moves and renames.
    AssetId
);
id_type!(
    /// A user tag.
    TagId
);
id_type!(
    /// A manual collection.
    CollectionId
);
id_type!(
    /// A saved search.
    SmartCollectionId
);
id_type!(
    /// A persistent background job.
    JobId
);
