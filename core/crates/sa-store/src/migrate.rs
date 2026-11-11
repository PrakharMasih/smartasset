//! Forward-only schema migrations. Every older version must upgrade to the latest (plan §11).

use crate::error::DbResultExt;
use rusqlite::Connection;
use sa_core::{Error, Result};

/// `(version, sql)` in ascending order. A migration never edits an earlier one; it adds a new entry.
const MIGRATIONS: &[(i64, &str)] = &[
    (1, include_str!("sql/0001_library.sql")),
    (2, include_str!("sql/0002_duplicates.sql")),
    (3, include_str!("sql/0003_embeddings.sql")),
    (4, include_str!("sql/0004_text.sql")),
    (5, include_str!("sql/0005_moments.sql")),
];

pub const LATEST_VERSION: i64 = MIGRATIONS[MIGRATIONS.len() - 1].0;

/// The schema version stored in the database.
pub fn current_version(conn: &Connection) -> Result<i64> {
    conn.query_row("PRAGMA user_version", [], |r| r.get(0)).db()
}

/// Brings the database to [`LATEST_VERSION`]. Returns the version it started from.
///
/// # Errors
/// [`Error::SchemaTooNew`] if the database was written by a newer app. The database is left untouched.
pub fn migrate(conn: &mut Connection) -> Result<i64> {
    let start = current_version(conn)?;
    if start > LATEST_VERSION {
        return Err(Error::SchemaTooNew { found: start, supported: LATEST_VERSION });
    }
    for &(version, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > start) {
        let tx = conn.transaction().db()?;
        tx.execute_batch(sql).db()?;
        // `PRAGMA user_version` takes no bound parameters; `version` is a trusted constant.
        tx.execute_batch(&format!("PRAGMA user_version = {version}")).db()?;
        tx.commit().db()?;
        tracing::info!(version, "applied schema migration");
    }
    Ok(start)
}

/// Every migration, for tests that upgrade from each historic version.
#[must_use]
pub fn all_migrations() -> &'static [(i64, &'static str)] {
    MIGRATIONS
}
