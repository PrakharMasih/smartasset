//! Builds and runs the SQL for a [`SearchQuery`].

use crate::fts::fts_match_expression;
use rusqlite::types::Value;
use rusqlite::{Connection, params_from_iter};
use sa_core::{Error, MissingFilter, Result, SearchQuery, SortKey};
use sa_store::DbResultExt;

/// The SQL and bound values for a query; exposed so tests and the query planner check can inspect it.
#[derive(Debug, Clone)]
pub struct SearchPlan {
    pub sql: String,
    pub params: Vec<Value>,
    /// The text had words but none were searchable: the result is empty by definition.
    pub empty: bool,
}

struct Builder {
    params: Vec<Value>,
}

impl Builder {
    fn bind(&mut self, v: impl Into<Value>) -> String {
        self.params.push(v.into());
        format!("?{}", self.params.len())
    }

    fn bind_list<T: Into<Value> + Clone>(&mut self, items: &[T]) -> String {
        let marks: Vec<String> = items.iter().cloned().map(|i| self.bind(i)).collect();
        marks.join(", ")
    }
}

/// Builds the query. Pure: touches no database.
#[must_use]
pub fn plan(q: &SearchQuery) -> SearchPlan {
    let mut b = Builder { params: Vec::new() };
    let mut with = String::new();
    let mut joins: Vec<String> = Vec::new();
    let mut conds: Vec<String> = Vec::new();
    let f = &q.filters;

    // Keyword text (plan S12).
    let mut has_hits = false;
    if let Some(text) = q.trimmed_text() {
        match fts_match_expression(text) {
            Some(expr) => {
                let p = b.bind(expr);
                // Column weights: name, path, tags, notes; text read in the picture (S4) counts like notes. Lower bm25
                // is better. A file found in both tables keeps its better rank.
                with = format!(
                    "WITH hits AS (SELECT id, MIN(rank) AS rank FROM ( \
                       SELECT rowid AS id, bm25(asset_fts, 10.0, 3.0, 8.0, 2.0) AS rank FROM asset_fts WHERE asset_fts MATCH {p} \
                       UNION ALL \
                       SELECT rowid AS id, 2.0 * bm25(asset_text_fts) AS rank FROM asset_text_fts WHERE asset_text_fts MATCH {p}) \
                     GROUP BY id) "
                );
                joins.push("JOIN hits h ON h.id = a.id".into());
                has_hits = true;
            }
            None => {
                return SearchPlan { sql: String::new(), params: Vec::new(), empty: true };
            }
        }
    }

    // Collection membership (plan O2), joined so a manual order can be used.
    let mut has_collection = false;
    if let Some(c) = f.collection_id {
        let p = b.bind(c);
        joins.push(format!("JOIN collection_items ci ON ci.asset_id = a.id AND ci.collection_id = {p}"));
        has_collection = true;
    }

    match f.missing {
        MissingFilter::Hide => conds.push("a.status = 0".into()),
        MissingFilter::Only => conds.push("a.status = 1".into()),
        MissingFilter::Include => {}
    }
    // Folders switched off (plan L5) disappear from every view.
    conds.push("a.folder_id NOT IN (SELECT id FROM folders WHERE enabled = 0)".into());

    if !f.kinds.is_empty() {
        let list = b.bind_list(&f.kinds.iter().map(|k| k.to_db()).collect::<Vec<_>>());
        conds.push(format!("a.kind IN ({list})"));
    }
    if let Some(d) = f.date {
        if let Some(from) = d.from {
            let p = b.bind(from);
            conds.push(format!("a.sort_date >= {p}"));
        }
        if let Some(to) = d.to {
            let p = b.bind(to);
            conds.push(format!("a.sort_date <= {p}"));
        }
    }
    if let Some(min) = f.min_duration_ms {
        let p = b.bind(min);
        conds.push(format!("a.duration_ms >= {p}"));
    }
    if let Some(max) = f.max_duration_ms {
        let p = b.bind(max);
        conds.push(format!("a.duration_ms <= {p}"));
    }
    if let Some(res) = f.min_resolution {
        let p = b.bind(res.min_long_edge());
        conds.push(format!("MAX(a.width, a.height) >= {p}"));
    }
    if !f.orientations.is_empty() {
        let list = b.bind_list(&f.orientations.iter().map(|o| o.to_db()).collect::<Vec<_>>());
        conds.push(format!("a.orientation IN ({list})"));
    }
    for tag in &f.tags_all {
        let p = b.bind(tag.trim().to_string());
        conds.push(format!(
            "EXISTS (SELECT 1 FROM asset_tags at JOIN tags t ON t.id = at.tag_id \
             WHERE at.asset_id = a.id AND t.name = {p})"
        ));
    }
    if !f.tags_any.is_empty() {
        let list = b.bind_list(&f.tags_any.iter().map(|t| t.trim().to_string()).collect::<Vec<_>>());
        conds.push(format!(
            "EXISTS (SELECT 1 FROM asset_tags at JOIN tags t ON t.id = at.tag_id \
             WHERE at.asset_id = a.id AND t.name IN ({list}))"
        ));
    }
    if f.unrated_only {
        conds.push("a.rating = 0".into());
    } else if let Some(min) = f.min_rating.filter(|m| *m > 0) {
        let p = b.bind(i64::from(min.min(5)));
        conds.push(format!("a.rating >= {p}"));
    }
    if let Some(flag) = f.flag {
        let p = b.bind(flag.to_db());
        conds.push(format!("a.flag = {p}"));
    }
    if !f.color_labels.is_empty() {
        let list = b.bind_list(&f.color_labels.iter().map(|c| c.to_db()).collect::<Vec<_>>());
        conds.push(format!("a.color_label IN ({list})"));
    }
    if !f.folder_ids.is_empty() {
        let list = b.bind_list(&f.folder_ids);
        conds.push(format!("a.folder_id IN ({list})"));
    }
    if !f.volume_ids.is_empty() {
        let list = b.bind_list(&f.volume_ids);
        conds.push(format!("a.folder_id IN (SELECT id FROM folders WHERE volume_id IN ({list}))"));
    }

    let dir = if q.sort.descending { "DESC" } else { "ASC" };
    let order = match q.sort.key {
        SortKey::Relevance if has_hits => format!("h.rank ASC, a.id {dir}"),
        SortKey::Manual if has_collection => format!("ci.position {dir}, a.id {dir}"),
        SortKey::Name => format!("a.name COLLATE NOCASE {dir}, a.id {dir}"),
        SortKey::DateAdded => format!("a.added_at {dir}, a.id {dir}"),
        SortKey::DateModified => format!("a.mtime {dir}, a.id {dir}"),
        SortKey::Size => format!("a.size {dir}, a.id {dir}"),
        SortKey::Duration => format!("a.duration_ms {dir}, a.id {dir}"),
        SortKey::Rating => format!("a.rating {dir}, a.sort_date DESC, a.id DESC"),
        SortKey::Kind => format!("a.kind {dir}, a.sort_date DESC, a.id DESC"),
        // Relevance without text, manual order without a collection: fall back to the newest-first default.
        SortKey::Relevance | SortKey::Manual | SortKey::DateCaptured => {
            format!("a.sort_date {dir}, a.id {dir}")
        }
    };

    let sql = format!(
        "{with}SELECT a.id FROM assets a {} WHERE {} ORDER BY {order}",
        joins.join(" "),
        conds.join(" AND ")
    );
    SearchPlan { sql, params: b.params, empty: false }
}

/// Runs a query and returns every matching asset id in display order.
pub fn run(conn: &Connection, q: &SearchQuery) -> Result<Vec<i64>> {
    let p = plan(q);
    if p.empty {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare_cached(&p.sql).db()?;
    let rows = stmt
        .query_map(params_from_iter(p.params.iter()), |r| r.get::<_, i64>(0))
        .map_err(|e| Error::Db(e.to_string()))?;
    let mut ids = Vec::new();
    for row in rows {
        ids.push(row.db()?);
    }
    Ok(ids)
}
