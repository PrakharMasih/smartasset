//! Turns what a person typed into a safe FTS5 expression.
//!
//! FTS5 has its own query language (`AND`, `NOT`, `NEAR`, quotes, columns, `*`). Passing user text straight
//! through makes `"` or `(` a syntax error and lets `name:` reach internal columns. Instead every run of letters
//! and digits becomes one quoted prefix term, so typing is forgiving and can never fail.

/// Splits on anything that is not a letter or digit, exactly like the `unicode61` tokenizer does.
fn tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty())
}

/// The FTS5 `MATCH` expression for user text: every word must match, each as a prefix (type-ahead).
/// `None` when the text contains no searchable word at all.
#[must_use]
pub fn fts_match_expression(text: &str) -> Option<String> {
    let terms: Vec<String> = tokens(text).map(|t| format!("\"{t}\"*")).collect();
    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_become_prefix_terms() {
        assert_eq!(fts_match_expression("golden hour").as_deref(), Some("\"golden\"* \"hour\"*"));
        assert_eq!(fts_match_expression("IMG_4471").as_deref(), Some("\"IMG\"* \"4471\"*"));
    }

    #[test]
    fn fts_syntax_is_neutralised() {
        for hostile in ["\"", "(", ")", "*", "a AND", "NOT", "NEAR(a b)", "name:secret", "a OR b", "^x", "x\"y", "--", "'"] {
            let expr = fts_match_expression(hostile);
            if let Some(e) = expr {
                // Only quoted terms and `*` survive; no operator can appear unquoted.
                assert!(
                    e.split(' ').all(|t| t.starts_with('"') && t.ends_with("\"*")),
                    "{hostile:?} -> {e}"
                );
            }
        }
    }

    #[test]
    fn nothing_searchable_is_none() {
        assert_eq!(fts_match_expression(""), None);
        assert_eq!(fts_match_expression("  ?!  "), None);
    }

    #[test]
    fn non_latin_words_are_kept() {
        assert_eq!(fts_match_expression("café 東京").as_deref(), Some("\"café\"* \"東京\"*"));
    }
}
