//! Small key/value settings kept in the database (so they travel with it).

use crate::error::DbResultExt;
use rusqlite::{Connection, OptionalExtension, Transaction};
use sa_core::Result;

pub fn get(conn: &Connection, key: &str) -> Result<Option<String>> {
    conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0))
        .optional()
        .db()
}

pub fn set(tx: &Transaction<'_>, key: &str, value: &str) -> Result<()> {
    tx.execute(
        "INSERT INTO settings(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, value],
    )
    .db()?;
    Ok(())
}
