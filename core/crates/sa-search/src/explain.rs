//! "Why this matched" for the keyword side (plan S11): for each word of a search, where in the file it was found.
//!
//! Asks the same keyword index the search used (`asset_fts`, `asset_text_fts`), one word and one column at a time, so
//! the answer can never disagree with the search about what matches.

use crate::fts::fts_match_expression;
use rusqlite::{Connection, OptionalExtension};
use sa_core::Result;
use sa_store::DbResultExt;

/// Where a word was found, in the order the explanation prefers when a word is in several places.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    Name,
    Tag,
    Note,
    /// Words the text reader found in the picture or video (S4).
    TextInPicture,
    /// The folder names above the file.
    Folder,
}

/// One typed word and where it was found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordHit {
    pub word: String,
    pub field: Field,
    /// For a note or text in the picture: the few words around the match.
    pub snippet: Option<String>,
}

/// The words of `text`, as the keyword search splits them (letters and digits).
#[must_use]
pub fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).map(str::to_string).collect()
}

/// For every word of `text`, the first place it is found in file `id`. The keyword search needs every word to match, so
/// when any word is found nowhere the file was not found by words and the answer is empty (a file that came up by
/// meaning is not explained with the few words that happen to be in it).
pub fn explain(conn: &Connection, id: i64, text: &str) -> Result<Vec<WordHit>> {
    let all = words(text);
    let mut out = Vec::new();
    for word in all.iter().cloned() {
        let Some(term) = fts_match_expression(&word) else { continue };
        let mut found = None;
        for (column, field) in [("name", Field::Name), ("tags", Field::Tag), ("notes", Field::Note)] {
            if in_column(conn, id, &format!("{column} : ({term})"))? {
                found = Some(field);
                break;
            }
        }
        if found.is_none() && in_text(conn, id, &term)? {
            found = Some(Field::TextInPicture);
        }
        if found.is_none() && in_column(conn, id, &format!("path : ({term})"))? {
            found = Some(Field::Folder);
        }
        let Some(field) = found else { continue };
        let snippet = match field {
            Field::Note => stored(conn, "SELECT notes FROM asset_fts WHERE rowid = ?1", id)?.and_then(|t| around(&t, &word)),
            Field::TextInPicture => stored(conn, "SELECT text FROM asset_text WHERE asset_id = ?1", id)?.and_then(|t| around(&t, &word)),
            _ => None,
        };
        out.push(WordHit { word, field, snippet });
    }
    if out.len() == all.len() { Ok(out) } else { Ok(Vec::new()) }
}

fn in_column(conn: &Connection, id: i64, expr: &str) -> Result<bool> {
    conn.query_row("SELECT 1 FROM asset_fts WHERE asset_fts MATCH ?1 AND rowid = ?2", rusqlite::params![expr, id], |_| Ok(()))
        .optional()
        .db()
        .map(|r| r.is_some())
}

fn in_text(conn: &Connection, id: i64, term: &str) -> Result<bool> {
    conn.query_row("SELECT 1 FROM asset_text_fts WHERE asset_text_fts MATCH ?1 AND rowid = ?2", rusqlite::params![term, id], |_| Ok(()))
        .optional()
        .db()
        .map(|r| r.is_some())
}

fn stored(conn: &Connection, sql: &str, id: i64) -> Result<Option<String>> {
    conn.query_row(sql, [id], |r| r.get(0)).optional().db()
}

/// Up to five words either side of the first word that starts with `word` (case-insensitive), with "…" where cut.
fn around(text: &str, word: &str) -> Option<String> {
    let want = word.to_lowercase();
    let all: Vec<&str> = text.split_whitespace().collect();
    let at = all.iter().position(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase().starts_with(&want))?;
    let (from, to) = (at.saturating_sub(5), (at + 6).min(all.len()));
    let mut s = all[from..to].join(" ");
    if from > 0 {
        s.insert(0, '…');
    }
    if to < all.len() {
        s.push('…');
    }
    Some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_like_the_search() {
        assert_eq!(words("golden hour, IMG_4471"), vec!["golden", "hour", "IMG", "4471"]);
        assert_eq!(words("  ?! "), Vec::<String>::new());
    }

    #[test]
    fn a_snippet_is_the_words_around_the_match() {
        let text = "Summer Sale this weekend only fifty percent off every single thing in store";
        assert_eq!(around(text, "weekend").as_deref(), Some("Summer Sale this weekend only fifty percent off every…"));
        assert_eq!(around(text, "summer").as_deref(), Some("Summer Sale this weekend only fifty…"));
        assert_eq!(around(text, "STORE").as_deref(), Some("…off every single thing in store"));
        assert_eq!(around(text, "absent"), None);
    }
}
