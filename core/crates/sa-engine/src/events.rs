//! What the engine tells the app about (plan §6.3: an event stream; coalesced, never one item at a time).

use sa_jobs::PauseReason;

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Something that can change search results happened. `structural` means files were added, removed or moved;
    /// otherwise only details such as dates or ratings changed, and the app may refresh less eagerly.
    LibraryChanged { structural: bool },
    /// These assets now have a new thumbnail.
    ThumbnailsReady { asset_ids: Vec<i64> },
    /// Folders were added, removed or their status changed.
    FoldersChanged,
    /// Files were compared or removed: the Duplicates page may show something different.
    DuplicatesChanged,
    /// Indexing progress, at most a few times per second while work is running.
    Progress(Progress),
    /// A one-off problem worth telling the user about.
    Notice(Notice),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    /// Everything in a folder seemed to vanish at once, so nothing was marked missing (drive dropped?).
    FolderLooksEmpty { folder_id: i64, folder_name: String },
    /// A folder could not be read.
    FolderUnreadable { folder_id: i64, folder_name: String, message: String },
    /// Files stored only in iCloud were left alone.
    CloudFilesSkipped { folder_id: i64, folder_name: String, count: u64 },
    /// The database failed a health check after an unclean exit.
    DatabaseProblem { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Progress {
    /// A folder scan (the browse pass) is running.
    pub scanning: bool,
    /// Files found by scans in this session.
    pub files_discovered: u64,
    /// Media (metadata + thumbnail) work.
    pub media_total: i64,
    pub media_done: i64,
    pub media_failed: i64,
    pub media_remaining: i64,
    /// Files still waiting to be compared for duplicates (full hash or picture hash).
    pub dedupe_remaining: i64,
    /// Files still waiting for their vector (search by meaning).
    pub embed_remaining: i64,
    /// Why background work is held right now, if it is.
    pub hold: Option<PauseReason>,
    /// Estimated seconds until the media work is done, once a rate is known.
    pub eta_seconds: Option<u64>,
}

impl Progress {
    #[must_use]
    pub const fn is_idle(&self) -> bool {
        !self.scanning && self.media_remaining == 0 && self.dedupe_remaining == 0 && self.embed_remaining == 0
    }
}

/// Receives events on an engine thread. Must return quickly.
pub trait EventSink: Send + Sync {
    fn on_event(&self, event: Event);
}
