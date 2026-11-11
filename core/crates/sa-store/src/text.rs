//! Text in pictures (Phase 4, S4): the jobs that read it and the rows that keep it.
//!
//! The Swift worker reads the words (Vision) from a picture or a few frames of a video; Rust only stores them. The
//! keyword index over them (`asset_text_fts`) is kept in step by triggers, so removing a file or a folder needs nothing
//! extra here. Nothing here touches a file.

use crate::error::DbResultExt;
use crate::jobs::lane;
use rusqlite::{Connection, Transaction, params};
use sa_core::{AssetId, Result};

/// Job kind for "read the text in this picture or video". The variant is the reader's id, so another reader (another
/// language, another engine) gets its own jobs.
pub const TEXT_JOB: &str = "text";

/// Text longer than this is cut: enough for any slide or screenshot, and it keeps one odd file from bloating the index.
pub const MAX_TEXT_CHARS: usize = 20_000;

/// Queues a job for every present picture or video that has a thumbnail and has not been read by `reader` (and has no
/// job for it). Returns how many were queued. A cancelled job (the file went missing and came back) is revived.
pub fn enqueue_backlog(tx: &Transaction<'_>, reader: &str, limit: i64, now: i64) -> Result<usize> {
    tx.execute(
        "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
         SELECT ?1, a.id, ?2, ?3, 0, ?4, ?4 FROM assets a
         WHERE a.status = 0 AND a.probe_state = 1 AND a.kind IN (0, 1) AND a.thumb_rev > 0
           AND NOT EXISTS (SELECT 1 FROM asset_text t WHERE t.asset_id = a.id AND t.reader = ?2)
           AND NOT EXISTS (SELECT 1 FROM jobs j
                           WHERE j.kind = ?1 AND j.asset_id = a.id AND j.variant = ?2 AND j.state <> 4)
         LIMIT ?5
         ON CONFLICT(kind, asset_id, variant) DO UPDATE
            SET state = 0, attempts = 0, not_before = 0, lane = excluded.lane, updated_at = excluded.updated_at
            WHERE jobs.state = 4",
        params![TEXT_JOB, reader, lane::MAINTENANCE, now, limit],
    )
    .db()
}

/// The file changed: its text describes old content. The text and the finished or failed jobs for it are dropped so
/// it is read again. A running job is left alone; its result is discarded because the size or time no longer match.
pub fn clear_derived(tx: &Transaction<'_>, id: AssetId) -> Result<()> {
    tx.execute("DELETE FROM asset_text WHERE asset_id = ?1", [id.0]).db()?;
    tx.execute("DELETE FROM jobs WHERE asset_id = ?1 AND kind = ?2 AND state <> 1", params![id.0, TEXT_JOB]).db()?;
    Ok(())
}

/// Tidies what a reader returned: one space between words, at most [`MAX_TEXT_CHARS`] characters.
#[must_use]
pub fn tidy(text: &str) -> String {
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ");
    match joined.char_indices().nth(MAX_TEXT_CHARS) {
        Some((cut, _)) => joined[..cut].to_string(),
        None => joined,
    }
}

/// Stores the text of a file, replacing earlier text, if the file is still the one that was read. Returns `false`
/// (and stores nothing) when the record changed in the meantime.
pub fn set_text(tx: &Transaction<'_>, id: AssetId, size: i64, mtime: i64, reader: &str, text: &str) -> Result<bool> {
    let current: Option<(i64, i64)> = tx
        .query_row("SELECT size, mtime FROM assets WHERE id = ?1", [id.0], |r| Ok((r.get(0)?, r.get(1)?)))
        .ok();
    if current != Some((size, mtime)) {
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO asset_text(asset_id, reader, text) VALUES (?1, ?2, ?3)
         ON CONFLICT(asset_id) DO UPDATE SET reader = excluded.reader, text = excluded.text",
        params![id.0, reader, tidy(text)],
    )
    .db()?;
    Ok(true)
}

/// The text read in a file, if it has been read (empty when it has none).
pub fn text_of(conn: &Connection, id: AssetId) -> Result<Option<String>> {
    use rusqlite::OptionalExtension;
    conn.query_row("SELECT text FROM asset_text WHERE asset_id = ?1", [id.0], |r| r.get(0)).optional().db()
}

/// How many files have been read by `reader`.
pub fn assets_read(conn: &Connection, reader: &str) -> Result<i64> {
    conn.query_row("SELECT COUNT(*) FROM asset_text WHERE reader = ?1", [reader], |r| r.get(0)).db()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tidy_joins_lines_and_caps_length() {
        assert_eq!(tidy("  SUMMER\n\nSALE  50%\toff "), "SUMMER SALE 50% off");
        let long = "é".repeat(MAX_TEXT_CHARS + 10);
        assert_eq!(tidy(&long).chars().count(), MAX_TEXT_CHARS, "cut on a character, never inside one");
    }
}
