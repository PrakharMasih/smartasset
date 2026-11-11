//! Relative-path rules. Assets are stored relative to the folder the user added, so a drive that mounts
//! somewhere else, or a folder that moves, only needs the folder's root updated.

use crate::error::{Error, Result};
use std::path::{Component, Path, PathBuf};

/// Directory extensions that are bundles, not folders of media the user organised. Indexing inside them
/// would index render caches and library internals, so scans treat them as opaque.
const OPAQUE_BUNDLE_EXTS: &[&str] = &[
    "photoslibrary",
    "fcpbundle",
    "imovielibrary",
    "aplibrary",
    "lrdata",
    "lrlibrary",
    "app",
    "framework",
    "bundle",
    "xcassets",
    "sparsebundle",
    "sparseimage",
];

/// Hidden files and folders (leading dot) are never indexed. That also excludes `._*` AppleDouble files
/// and `.DS_Store`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`.
#[must_use]
pub fn is_hidden_name(name: &str) -> bool {
    name.starts_with('.')
}

/// Whether a directory name is an opaque bundle such as `Library.photoslibrary`.
#[must_use]
pub fn is_opaque_bundle_dir(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| OPAQUE_BUNDLE_EXTS.contains(&e.to_ascii_lowercase().as_str()))
}

/// Normalises a relative path to forward slashes with no empty, `.` or `..` components.
///
/// # Errors
/// Fails for absolute paths or any path that tries to leave its root.
pub fn normalize_rel(path: &str) -> Result<String> {
    let mut parts: Vec<&str> = Vec::new();
    for comp in Path::new(path).components() {
        match comp {
            Component::Normal(s) => parts.push(
                s.to_str()
                    .ok_or_else(|| Error::Invalid("path is not valid UTF-8".into()))?,
            ),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(Error::Invalid(format!("not a safe relative path: {path}")));
            }
        }
    }
    Ok(parts.join("/"))
}

/// Joins a stored relative path under a folder root. Refuses anything that would escape the root.
///
/// # Errors
/// Fails if `rel` is absolute or contains `..`.
pub fn join_under(root: &Path, rel: &str) -> Result<PathBuf> {
    let rel = normalize_rel(rel)?;
    if rel.is_empty() {
        return Ok(root.to_path_buf());
    }
    Ok(root.join(rel))
}

/// The parent directory of a relative path (`""` for top-level files).
#[must_use]
pub fn rel_parent(rel: &str) -> &str {
    rel.rsplit_once('/').map_or("", |(parent, _)| parent)
}

/// The file name part of a relative path.
#[must_use]
pub fn rel_name(rel: &str) -> &str {
    rel.rsplit_once('/').map_or(rel, |(_, name)| name)
}

/// Half-open range `[lo, hi)` of every stored path *below* directory `dir` (not `dir` itself).
/// `hi` replaces the trailing `/` with `0`, the next ASCII character, so it works with a plain index range scan.
#[must_use]
pub fn descendants_range(dir: &str) -> (String, String) {
    if dir.is_empty() {
        // Everything: the empty string sorts before every path, `\u{10FFFF}` after.
        return (String::new(), "\u{10FFFF}".to_string());
    }
    (format!("{dir}/"), format!("{dir}0"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_collapses_and_rejects() {
        assert_eq!(normalize_rel("a/./b//c").unwrap(), "a/b/c");
        assert_eq!(normalize_rel("").unwrap(), "");
        assert!(normalize_rel("../x").is_err());
        assert!(normalize_rel("a/../../x").is_err());
        assert!(normalize_rel("/etc/passwd").is_err());
    }

    #[test]
    fn join_cannot_escape() {
        let root = Path::new("/Volumes/Media/Shoots");
        assert_eq!(join_under(root, "a/b.mov").unwrap(), root.join("a/b.mov"));
        assert!(join_under(root, "../secret").is_err());
        assert_eq!(join_under(root, "").unwrap(), root);
    }

    #[test]
    fn parent_and_name() {
        assert_eq!(rel_parent("a/b/c.jpg"), "a/b");
        assert_eq!(rel_parent("c.jpg"), "");
        assert_eq!(rel_name("a/b/c.jpg"), "c.jpg");
        assert_eq!(rel_name("c.jpg"), "c.jpg");
    }

    #[test]
    fn hidden_and_bundles() {
        assert!(is_hidden_name(".DS_Store"));
        assert!(is_hidden_name("._IMG_0001.jpg"));
        assert!(!is_hidden_name("IMG_0001.jpg"));
        assert!(is_opaque_bundle_dir("Photos Library.photoslibrary"));
        assert!(is_opaque_bundle_dir("Edit.FCPBUNDLE"));
        assert!(!is_opaque_bundle_dir("Holiday 2024"));
    }

    #[test]
    fn descendants_range_excludes_siblings() {
        let (lo, hi) = descendants_range("a/b");
        let inside = "a/b/c.jpg";
        let sibling = "a/b2/c.jpg";
        let same_prefix_file = "a/b.jpg";
        assert!(inside >= lo.as_str() && inside < hi.as_str());
        assert!(!(sibling >= lo.as_str() && sibling < hi.as_str()));
        assert!(!(same_prefix_file >= lo.as_str() && same_prefix_file < hi.as_str()));
    }
}
