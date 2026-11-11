//! Small SQL helpers.

use sa_core::paths;

/// A JSON array of ids, bound as one parameter and expanded with `json_each`. Avoids chunking `IN (...)` lists
/// and the bound-variable limit, however many assets a bulk action touches.
#[must_use]
pub fn ids_json(ids: &[i64]) -> String {
    let mut s = String::with_capacity(ids.len() * 8 + 2);
    s.push('[');
    for (i, id) in ids.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&id.to_string());
    }
    s.push(']');
    s
}

/// A JSON array of strings, for the same purpose.
#[must_use]
pub fn strings_json<S: AsRef<str>>(items: &[S]) -> String {
    serde_json::to_string(&items.iter().map(AsRef::as_ref).collect::<Vec<_>>())
        .unwrap_or_else(|_| "[]".into())
}

/// True when `child` is a strict descendant of `parent` (both relative to the same root, `""` = the root).
#[must_use]
pub fn is_within(child: &str, parent: &str) -> bool {
    if child == parent {
        return false;
    }
    parent.is_empty() || child.strip_prefix(parent).is_some_and(|rest| rest.starts_with('/'))
}

/// Path of `child` below `parent` (`child` must be within `parent`).
#[must_use]
pub fn strip_parent<'a>(child: &'a str, parent: &str) -> &'a str {
    if parent.is_empty() {
        child
    } else {
        child
            .strip_prefix(parent)
            .map_or(child, |rest| rest.trim_start_matches('/'))
    }
}

/// `true` if `rel` equals `exclude` or lies below it.
#[must_use]
pub fn is_excluded(rel: &str, exclude: &str) -> bool {
    rel == exclude || is_within(rel, exclude)
}

/// The SQL range that matches every path below `dir`.
#[must_use]
pub fn below(dir: &str) -> (String, String) {
    paths::descendants_range(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_ids() {
        assert_eq!(ids_json(&[]), "[]");
        assert_eq!(ids_json(&[1, -2, 3]), "[1,-2,3]");
    }

    #[test]
    fn json_strings_escape() {
        assert_eq!(strings_json(&["a", "b\"c"]), r#"["a","b\"c"]"#);
    }

    #[test]
    fn within() {
        assert!(is_within("a/b", "a"));
        assert!(is_within("a", ""));
        assert!(!is_within("a", "a"));
        assert!(!is_within("ab", "a"));
        assert!(!is_within("", ""));
        assert_eq!(strip_parent("a/b/c", "a"), "b/c");
        assert_eq!(strip_parent("a/b", ""), "a/b");
        assert!(is_excluded("a/b", "a/b"));
        assert!(is_excluded("a/b/c", "a/b"));
        assert!(!is_excluded("a/bc", "a/b"));
    }
}
