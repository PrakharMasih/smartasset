//! Maps rusqlite errors onto the engine error type (the orphan rule forbids a `From` impl).

use sa_core::Error;

/// `.db()?` turns a rusqlite result into an engine result.
pub trait DbResultExt<T> {
    fn db(self) -> sa_core::Result<T>;
}

impl<T> DbResultExt<T> for Result<T, rusqlite::Error> {
    fn db(self) -> sa_core::Result<T> {
        self.map_err(map_err)
    }
}

/// Takes the error by value so it can be passed straight to `Result::map_err`.
#[must_use]
#[allow(clippy::needless_pass_by_value)]
pub fn map_err(e: rusqlite::Error) -> Error {
    use rusqlite::ErrorCode;
    match &e {
        rusqlite::Error::SqliteFailure(f, _)
            if matches!(f.code, ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase) =>
        {
            Error::Corrupt(e.to_string())
        }
        rusqlite::Error::QueryReturnedNoRows => Error::NotFound("row".into()),
        _ => Error::Db(e.to_string()),
    }
}
