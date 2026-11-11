//! Counts for the sidebar (All / Images / Videos / Audio, Missing).

use rusqlite::Connection;
use sa_core::Result;
use sa_store::DbResultExt;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LibraryStats {
    pub total: i64,
    pub images: i64,
    pub videos: i64,
    pub audio: i64,
    /// Files that have disappeared from disk (not offline drives).
    pub missing: i64,
    pub total_size: i64,
}

pub fn stats(conn: &Connection) -> Result<LibraryStats> {
    let mut s = LibraryStats::default();
    let mut stmt = conn
        .prepare_cached(
            "SELECT a.kind, a.status, COUNT(*), COALESCE(SUM(a.size), 0) FROM assets a
             WHERE a.folder_id NOT IN (SELECT id FROM folders WHERE enabled = 0)
             GROUP BY a.kind, a.status",
        )
        .db()?;
    let rows = stmt
        .query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?))
        })
        .db()?;
    for row in rows {
        let (kind, status, n, size) = row.db()?;
        if status == 1 {
            s.missing += n;
            continue;
        }
        s.total += n;
        s.total_size += size;
        match kind {
            0 => s.images += n,
            1 => s.videos += n,
            2 => s.audio += n,
            _ => {}
        }
    }
    Ok(s)
}
