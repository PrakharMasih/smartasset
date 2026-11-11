//! Where SmartAsset keeps its own files: `~/Library/Application Support/SmartAsset/` (plan §6.8).
//! Media files are never stored here.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct DataDirs {
    pub root: PathBuf,
}

impl DataDirs {
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    #[must_use]
    pub fn database(&self) -> PathBuf {
        self.root.join("library.sqlite")
    }

    #[must_use]
    pub fn thumbs(&self) -> PathBuf {
        self.root.join("thumbs")
    }

    #[must_use]
    pub fn vectors(&self) -> PathBuf {
        self.root.join("vectors")
    }

    #[must_use]
    pub fn models(&self) -> PathBuf {
        self.root.join("models")
    }

    #[must_use]
    pub fn logs(&self) -> PathBuf {
        self.root.join("logs")
    }

    #[must_use]
    pub fn backups(&self) -> PathBuf {
        self.root.join("backups")
    }

    /// Temporary files (for example trimmed clips dragged out as moments). Cleaned automatically.
    #[must_use]
    pub fn scratch(&self) -> PathBuf {
        self.root.join("scratch")
    }

    /// Creates every directory. Idempotent.
    pub fn ensure(&self) -> std::io::Result<()> {
        for dir in [
            self.root.clone(),
            self.thumbs(),
            self.vectors(),
            self.models(),
            self.logs(),
            self.backups(),
            self.scratch(),
        ] {
            std::fs::create_dir_all(dir)?;
        }
        Ok(())
    }

    /// Path of a thumbnail: `thumbs/<shard>/<asset>_<rev>.jpg`. Sharded so no directory holds more than a few
    /// thousand files at 250k assets. A new revision gets a new file name, so caches never serve a stale image.
    #[must_use]
    pub fn thumb_path(&self, asset_id: i64, rev: i64) -> PathBuf {
        thumb_path_in(&self.thumbs(), asset_id, rev)
    }

    /// Path of the hover-scrub filmstrip for a video (one image holding evenly spaced frames).
    #[must_use]
    pub fn filmstrip_path(&self, asset_id: i64, rev: i64) -> PathBuf {
        let shard = format!("{:02x}", asset_id.rem_euclid(256));
        self.thumbs().join(shard).join(format!("{asset_id}_{rev}.strip.jpg"))
    }
}

#[must_use]
pub fn thumb_path_in(thumbs_dir: &Path, asset_id: i64, rev: i64) -> PathBuf {
    let shard = format!("{:02x}", asset_id.rem_euclid(256));
    thumbs_dir.join(shard).join(format!("{asset_id}_{rev}.jpg"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbs_are_sharded_and_versioned() {
        let d = DataDirs::new("/data");
        assert_eq!(d.thumb_path(0x1234, 3), Path::new("/data/thumbs/34/4660_3.jpg"));
        assert_ne!(d.thumb_path(7, 1), d.thumb_path(7, 2));
        assert_eq!(d.thumb_path(-1, 1).parent(), Some(Path::new("/data/thumbs/ff")));
    }
}
