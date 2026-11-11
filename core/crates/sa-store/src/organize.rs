//! Tags, ratings, flags, colour labels, notes, collections and smart collections (plan O1–O3).
//!
//! Every function that changes what the keyword index contains (tags, notes) keeps `asset_fts` in step inside the
//! same transaction.

use crate::error::DbResultExt;
use crate::model::{CollectionRow, SmartCollectionRow, Tag};
use crate::util::{ids_json, strings_json};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use sa_core::{ColorLabel, Error, Flag, Result, SearchQuery};

fn raw(ids: &[sa_core::AssetId]) -> String {
    ids_json(&ids.iter().map(|i| i.0).collect::<Vec<_>>())
}

pub fn set_rating(tx: &Transaction<'_>, ids: &[sa_core::AssetId], rating: u8) -> Result<usize> {
    if rating > 5 {
        return Err(Error::Invalid(format!("rating {rating} is not between 0 and 5")));
    }
    tx.execute(
        "UPDATE assets SET rating = ?2 WHERE id IN (SELECT value FROM json_each(?1))",
        params![raw(ids), rating],
    )
    .db()
}

pub fn set_flag(tx: &Transaction<'_>, ids: &[sa_core::AssetId], flag: Flag) -> Result<usize> {
    tx.execute(
        "UPDATE assets SET flag = ?2 WHERE id IN (SELECT value FROM json_each(?1))",
        params![raw(ids), flag.to_db()],
    )
    .db()
}

pub fn set_color_label(tx: &Transaction<'_>, ids: &[sa_core::AssetId], label: ColorLabel) -> Result<usize> {
    tx.execute(
        "UPDATE assets SET color_label = ?2 WHERE id IN (SELECT value FROM json_each(?1))",
        params![raw(ids), label.to_db()],
    )
    .db()
}

pub fn set_notes(tx: &Transaction<'_>, id: sa_core::AssetId, notes: &str) -> Result<()> {
    let n = tx
        .execute("UPDATE assets SET notes = ?2 WHERE id = ?1", params![id.0, notes])
        .db()?;
    if n == 0 {
        return Err(Error::NotFound(format!("asset {id}")));
    }
    tx.execute("UPDATE asset_fts SET notes = ?2 WHERE rowid = ?1", params![id.0, notes]).db()?;
    Ok(())
}

/// Tag names are trimmed, must be non-empty, and compare case-insensitively.
fn clean_tag(name: &str) -> Result<String> {
    let t = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        return Err(Error::Invalid("a tag needs a name".into()));
    }
    if t.chars().count() > 64 {
        return Err(Error::Invalid("a tag name can be at most 64 characters".into()));
    }
    Ok(t)
}

pub(crate) fn refresh_fts_tags(tx: &Transaction<'_>, ids_json: &str) -> Result<()> {
    tx.execute(
        "UPDATE asset_fts SET tags = COALESCE((
             SELECT group_concat(t.name, ' ') FROM asset_tags at JOIN tags t ON t.id = at.tag_id
             WHERE at.asset_id = asset_fts.rowid), '')
         WHERE rowid IN (SELECT value FROM json_each(?1))",
        [ids_json],
    )
    .db()?;
    Ok(())
}

/// Adds tags to assets, creating tags that do not exist yet.
pub fn add_tags(tx: &Transaction<'_>, ids: &[sa_core::AssetId], names: &[String]) -> Result<()> {
    let ids_j = raw(ids);
    for name in names {
        let name = clean_tag(name)?;
        tx.execute("INSERT INTO tags(name) VALUES (?1) ON CONFLICT(name) DO NOTHING", [&name]).db()?;
        let tag_id: i64 = tx.query_row("SELECT id FROM tags WHERE name = ?1", [&name], |r| r.get(0)).db()?;
        tx.execute(
            "INSERT OR IGNORE INTO asset_tags(asset_id, tag_id)
             SELECT a.id, ?2 FROM assets a WHERE a.id IN (SELECT value FROM json_each(?1))",
            params![ids_j, tag_id],
        )
        .db()?;
    }
    refresh_fts_tags(tx, &ids_j)
}

pub fn remove_tags(tx: &Transaction<'_>, ids: &[sa_core::AssetId], names: &[String]) -> Result<()> {
    let ids_j = raw(ids);
    let names_j = strings_json(names);
    tx.execute(
        "DELETE FROM asset_tags
         WHERE asset_id IN (SELECT value FROM json_each(?1))
           AND tag_id IN (SELECT id FROM tags WHERE name IN (SELECT value FROM json_each(?2)))",
        params![ids_j, names_j],
    )
    .db()?;
    refresh_fts_tags(tx, &ids_j)
}

/// Renames a tag everywhere. Renaming onto an existing tag merges the two.
pub fn rename_tag(tx: &Transaction<'_>, from: &str, to: &str) -> Result<()> {
    let to = clean_tag(to)?;
    let from_id: i64 = tx
        .query_row("SELECT id FROM tags WHERE name = ?1", [from], |r| r.get(0))
        .optional()
        .db()?
        .ok_or_else(|| Error::NotFound(format!("tag {from}")))?;
    let affected = affected_assets(tx, from_id)?;
    let existing: Option<i64> = tx.query_row("SELECT id FROM tags WHERE name = ?1", [&to], |r| r.get(0)).optional().db()?;
    match existing {
        Some(other) if other != from_id => {
            tx.execute(
                "INSERT OR IGNORE INTO asset_tags(asset_id, tag_id) SELECT asset_id, ?2 FROM asset_tags WHERE tag_id = ?1",
                params![from_id, other],
            )
            .db()?;
            tx.execute("DELETE FROM tags WHERE id = ?1", [from_id]).db()?;
        }
        _ => {
            tx.execute("UPDATE tags SET name = ?2 WHERE id = ?1", params![from_id, to]).db()?;
        }
    }
    refresh_fts_tags(tx, &ids_json(&affected))
}

/// Deletes a tag and removes it from every asset.
pub fn delete_tag(tx: &Transaction<'_>, name: &str) -> Result<()> {
    let Some(id) = tx
        .query_row("SELECT id FROM tags WHERE name = ?1", [name], |r| r.get::<_, i64>(0))
        .optional()
        .db()?
    else {
        return Ok(());
    };
    let affected = affected_assets(tx, id)?;
    tx.execute("DELETE FROM tags WHERE id = ?1", [id]).db()?;
    refresh_fts_tags(tx, &ids_json(&affected))
}

fn affected_assets(tx: &Transaction<'_>, tag_id: i64) -> Result<Vec<i64>> {
    let mut stmt = tx.prepare("SELECT asset_id FROM asset_tags WHERE tag_id = ?1").db()?;
    let rows = stmt.query_map([tag_id], |r| r.get::<_, i64>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

pub fn list_tags(conn: &Connection) -> Result<Vec<Tag>> {
    let mut stmt = conn
        .prepare(
            "SELECT t.id, t.name, COUNT(at.asset_id) FROM tags t
             LEFT JOIN asset_tags at ON at.tag_id = t.id
             GROUP BY t.id ORDER BY t.name COLLATE NOCASE",
        )
        .db()?;
    let rows = stmt
        .query_map([], |r| Ok(Tag { id: r.get(0)?, name: r.get(1)?, asset_count: r.get(2)? }))
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

// ---- manual collections (O2) ----

pub fn create_collection(tx: &Transaction<'_>, name: &str, now: i64) -> Result<i64> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error::Invalid("a collection needs a name".into()));
    }
    tx.execute(
        "INSERT INTO collections(name, created_at, position)
         VALUES (?1, ?2, COALESCE((SELECT MAX(position) + 1 FROM collections), 0))",
        params![name, now],
    )
    .db()?;
    Ok(tx.last_insert_rowid())
}

pub fn rename_collection(tx: &Transaction<'_>, id: i64, name: &str) -> Result<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error::Invalid("a collection needs a name".into()));
    }
    let n = tx.execute("UPDATE collections SET name = ?2 WHERE id = ?1", params![id, name]).db()?;
    if n == 0 {
        return Err(Error::NotFound(format!("collection {id}")));
    }
    Ok(())
}

/// Deletes the collection only. Its assets are untouched.
pub fn delete_collection(tx: &Transaction<'_>, id: i64) -> Result<()> {
    tx.execute("DELETE FROM collections WHERE id = ?1", [id]).db()?;
    Ok(())
}

/// Appends assets to a collection in the order given; assets already in it keep their place.
pub fn add_to_collection(tx: &Transaction<'_>, collection: i64, ids: &[sa_core::AssetId], now: i64) -> Result<usize> {
    let exists: bool = tx
        .query_row("SELECT 1 FROM collections WHERE id = ?1", [collection], |_| Ok(true))
        .optional()
        .db()?
        .unwrap_or(false);
    if !exists {
        return Err(Error::NotFound(format!("collection {collection}")));
    }
    let mut next: i64 = tx
        .query_row(
            "SELECT COALESCE(MAX(position) + 1, 0) FROM collection_items WHERE collection_id = ?1",
            [collection],
            |r| r.get(0),
        )
        .db()?;
    let mut added = 0;
    let mut stmt = tx
        .prepare_cached(
            "INSERT OR IGNORE INTO collection_items(collection_id, asset_id, position, added_at)
             SELECT ?1, id, ?3, ?4 FROM assets WHERE id = ?2",
        )
        .db()?;
    for id in ids {
        let n = stmt.execute(params![collection, id.0, next, now]).db()?;
        if n > 0 {
            next += 1;
            added += 1;
        }
    }
    Ok(added)
}

pub fn remove_from_collection(tx: &Transaction<'_>, collection: i64, ids: &[sa_core::AssetId]) -> Result<usize> {
    tx.execute(
        "DELETE FROM collection_items WHERE collection_id = ?1 AND asset_id IN (SELECT value FROM json_each(?2))",
        params![collection, raw(ids)],
    )
    .db()
}

pub fn list_collections(conn: &Connection) -> Result<Vec<CollectionRow>> {
    let mut stmt = conn
        .prepare(
            "SELECT c.id, c.name, COUNT(ci.asset_id) FROM collections c
             LEFT JOIN collection_items ci ON ci.collection_id = c.id
             GROUP BY c.id ORDER BY c.position, c.id",
        )
        .db()?;
    let rows = stmt
        .query_map([], |r| Ok(CollectionRow { id: r.get(0)?, name: r.get(1)?, asset_count: r.get(2)? }))
        .db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

/// Collections that contain an asset, for the inspector.
pub fn collections_of(conn: &Connection, asset: sa_core::AssetId) -> Result<Vec<i64>> {
    let mut stmt = conn.prepare("SELECT collection_id FROM collection_items WHERE asset_id = ?1").db()?;
    let rows = stmt.query_map([asset.0], |r| r.get::<_, i64>(0)).db()?;
    rows.collect::<std::result::Result<_, _>>().db()
}

// ---- smart collections (O3) ----

pub fn create_smart_collection(tx: &Transaction<'_>, name: &str, query: &SearchQuery, now: i64) -> Result<i64> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error::Invalid("a smart collection needs a name".into()));
    }
    let definition = serde_json::to_string(query).map_err(|e| Error::Invalid(e.to_string()))?;
    tx.execute(
        "INSERT INTO smart_collections(name, definition, created_at, position)
         VALUES (?1, ?2, ?3, COALESCE((SELECT MAX(position) + 1 FROM smart_collections), 0))",
        params![name, definition, now],
    )
    .db()?;
    Ok(tx.last_insert_rowid())
}

pub fn update_smart_collection(tx: &Transaction<'_>, id: i64, name: &str, query: &SearchQuery) -> Result<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error::Invalid("a smart collection needs a name".into()));
    }
    let definition = serde_json::to_string(query).map_err(|e| Error::Invalid(e.to_string()))?;
    let n = tx
        .execute(
            "UPDATE smart_collections SET name = ?2, definition = ?3 WHERE id = ?1",
            params![id, name, definition],
        )
        .db()?;
    if n == 0 {
        return Err(Error::NotFound(format!("smart collection {id}")));
    }
    Ok(())
}

pub fn delete_smart_collection(tx: &Transaction<'_>, id: i64) -> Result<()> {
    tx.execute("DELETE FROM smart_collections WHERE id = ?1", [id]).db()?;
    Ok(())
}

pub fn list_smart_collections(conn: &Connection) -> Result<Vec<SmartCollectionRow>> {
    let mut stmt = conn
        .prepare("SELECT id, name, definition FROM smart_collections ORDER BY position, id")
        .db()?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))
        .db()?;
    let mut out = Vec::new();
    for row in rows {
        let (id, name, definition) = row.db()?;
        // A definition that no longer parses must not hide the collection: fall back to "everything".
        let query = serde_json::from_str(&definition).unwrap_or_else(|e| {
            tracing::warn!(id, error = %e, "smart collection definition unreadable");
            SearchQuery::default()
        });
        out.push(SmartCollectionRow { id, name, query });
    }
    Ok(out)
}
