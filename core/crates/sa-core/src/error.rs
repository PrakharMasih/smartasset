//! One error type for the whole engine. Nothing panics across the bridge; every failure is one of these.

use std::fmt;

/// How a failed job should be treated (plan §6.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorClass {
    /// Worth retrying with backoff: busy disk, momentary I/O failure.
    Transient,
    /// This file is damaged. Retrying will not help; the file fails alone.
    FileCorrupt,
    /// The format or codec is not supported by any available worker.
    Unsupported,
    /// A model failed. The batch fails, the app does not.
    ModelFailure,
    /// The file cannot be read because access was not granted.
    Permission,
}

impl ErrorClass {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Transient => "transient",
            Self::FileCorrupt => "file_corrupt",
            Self::Unsupported => "unsupported",
            Self::ModelFailure => "model_failure",
            Self::Permission => "permission",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "transient" => Self::Transient,
            "file_corrupt" => Self::FileCorrupt,
            "unsupported" => Self::Unsupported,
            "model_failure" => Self::ModelFailure,
            "permission" => Self::Permission,
            _ => return None,
        })
    }

    /// Whether a job that failed this way is worth another attempt.
    #[must_use]
    pub const fn is_retryable(self) -> bool {
        matches!(self, Self::Transient | Self::ModelFailure)
    }
}

impl fmt::Display for ErrorClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// SQLite or the storage layer failed.
    #[error("database error: {0}")]
    Db(String),

    /// A file-system operation failed.
    #[error("{op} {path}: {message}")]
    Io {
        op: &'static str,
        path: String,
        message: String,
    },

    /// The thing asked for does not exist (any more).
    #[error("not found: {0}")]
    NotFound(String),

    /// The caller passed something that makes no sense.
    #[error("invalid input: {0}")]
    Invalid(String),

    /// The operation was cancelled before it finished.
    #[error("cancelled")]
    Cancelled,

    /// The database was written by a newer version of SmartAsset.
    #[error("database schema {found} is newer than this app understands ({supported})")]
    SchemaTooNew { found: i64, supported: i64 },

    /// The database failed an integrity check.
    #[error("database is corrupt: {0}")]
    Corrupt(String),

    /// A rule from plan §3 stopped an action (for example touching an original file).
    #[error("refused: {0}")]
    Refused(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    #[must_use]
    pub fn io(op: &'static str, path: impl AsRef<std::path::Path>, e: &std::io::Error) -> Self {
        Self::Io {
            op,
            path: path.as_ref().display().to_string(),
            message: e.to_string(),
        }
    }

    /// Classifies an I/O error for the job retry policy.
    #[must_use]
    pub fn io_class(e: &std::io::Error) -> ErrorClass {
        use std::io::ErrorKind as K;
        match e.kind() {
            K::PermissionDenied => ErrorClass::Permission,
            K::NotFound | K::InvalidData | K::UnexpectedEof => ErrorClass::FileCorrupt,
            _ => ErrorClass::Transient,
        }
    }
}
