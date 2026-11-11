-- Schema v1: the library (milestone M1). SQLite is the single source of truth (plan §6.8).
-- Integers for enums are stable on-disk codes defined in sa-core; never renumber them.

CREATE TABLE volumes (
    id            INTEGER PRIMARY KEY,
    uuid          TEXT    NOT NULL UNIQUE,          -- volume UUID, supplied by macOS
    name          TEXT    NOT NULL,                 -- shown to name the drive to plug in (L4)
    mount_path    TEXT,                             -- NULL while unplugged
    is_internal   INTEGER NOT NULL DEFAULT 0,
    is_online     INTEGER NOT NULL DEFAULT 1,
    last_seen_at  INTEGER NOT NULL
);

CREATE TABLE folders (
    id            INTEGER PRIMARY KEY,
    volume_id     INTEGER NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    rel_path      TEXT    NOT NULL,                 -- relative to the volume mount, no leading slash
    display_name  TEXT    NOT NULL,
    bookmark      BLOB,                             -- security-scoped bookmark (L1b), opaque to Rust
    enabled       INTEGER NOT NULL DEFAULT 1,       -- L5: include / exclude the whole folder
    added_at      INTEGER NOT NULL,
    last_scan_at  INTEGER,
    scan_state    INTEGER NOT NULL DEFAULT 0,       -- 0 pending, 1 scanning, 2 idle, 3 error
    last_error    TEXT,
    UNIQUE (volume_id, rel_path)
);

CREATE TABLE folder_excludes (
    folder_id     INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    rel_path      TEXT    NOT NULL,                 -- subfolder, relative to the folder root
    PRIMARY KEY (folder_id, rel_path)
);

CREATE TABLE assets (
    id             INTEGER PRIMARY KEY,
    folder_id      INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    rel_path       TEXT    NOT NULL,                -- relative to the folder root
    name           TEXT    NOT NULL,
    ext            TEXT    NOT NULL,                -- lower-case, no dot
    kind           INTEGER NOT NULL,                -- 0 image, 1 video, 2 audio
    size           INTEGER NOT NULL,
    mtime          INTEGER NOT NULL,                -- ms since epoch
    quick_hash     BLOB    NOT NULL,                -- 16 bytes: size + head/middle/tail samples (move + change detection)
    content_hash   BLOB,                            -- 32-byte BLAKE3 of the full file; filled lazily
    status         INTEGER NOT NULL DEFAULT 0,      -- 0 present, 1 missing (file gone). Offline drives stay 0.
    missing_since  INTEGER,
    added_at       INTEGER NOT NULL,
    -- probe results, written by the media worker
    probe_state    INTEGER NOT NULL DEFAULT 0,      -- 0 pending, 1 ok, 2 failed
    width          INTEGER,
    height         INTEGER,
    orientation    INTEGER,                         -- sa-core Orientation
    aspect_class   INTEGER,                         -- sa-core AspectClass
    duration_ms    INTEGER,
    codec          TEXT,
    fps            REAL,
    sample_rate    INTEGER,
    channels       INTEGER,
    bitrate        INTEGER,
    capture_at     INTEGER,
    sort_date      INTEGER NOT NULL,                -- capture_at, else mtime
    camera_make    TEXT,
    camera_model   TEXT,
    lens           TEXT,
    gps_lat        REAL,
    gps_lon        REAL,
    exif_json      TEXT,                            -- long-tail metadata for the inspector
    thumb_rev      INTEGER NOT NULL DEFAULT 0,      -- 0 = no thumbnail yet; bumped on every regeneration
    -- user data (plan O1) lives with the asset so a move or rename keeps it (L3)
    rating         INTEGER NOT NULL DEFAULT 0,      -- 0..5
    flag           INTEGER NOT NULL DEFAULT 0,      -- 0 none, 1 pick, -1 reject
    color_label    INTEGER NOT NULL DEFAULT 0,      -- 0..7
    notes          TEXT    NOT NULL DEFAULT '',
    UNIQUE (folder_id, rel_path)
);
CREATE INDEX idx_assets_sort_date  ON assets (sort_date);
CREATE INDEX idx_assets_added_at   ON assets (added_at);
CREATE INDEX idx_assets_mtime      ON assets (mtime);
CREATE INDEX idx_assets_name       ON assets (name COLLATE NOCASE);
CREATE INDEX idx_assets_size       ON assets (size);
CREATE INDEX idx_assets_kind       ON assets (kind, sort_date);
CREATE INDEX idx_assets_rating     ON assets (rating) WHERE rating > 0;
CREATE INDEX idx_assets_relink     ON assets (size, quick_hash);
CREATE INDEX idx_assets_status     ON assets (status) WHERE status <> 0;
CREATE INDEX idx_assets_probe      ON assets (probe_state) WHERE probe_state = 0;

-- Keyword index (plan S12). rowid = assets.id. Transcript and OCR text get their own tables in later milestones
-- because they need per-segment timestamps.
CREATE VIRTUAL TABLE asset_fts USING fts5 (
    name, path, tags, notes,
    tokenize = 'unicode61 remove_diacritics 2',
    prefix = '2 3 4'
);

CREATE TABLE tags (
    id     INTEGER PRIMARY KEY,
    name   TEXT NOT NULL COLLATE NOCASE UNIQUE
);
CREATE TABLE asset_tags (
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    tag_id   INTEGER NOT NULL REFERENCES tags(id)   ON DELETE CASCADE,
    PRIMARY KEY (asset_id, tag_id)
) WITHOUT ROWID;
CREATE INDEX idx_asset_tags_tag ON asset_tags (tag_id, asset_id);

CREATE TABLE collections (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    created_at  INTEGER NOT NULL,
    position    INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE collection_items (
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    asset_id      INTEGER NOT NULL REFERENCES assets(id)      ON DELETE CASCADE,
    position      INTEGER NOT NULL,
    added_at      INTEGER NOT NULL,
    PRIMARY KEY (collection_id, asset_id)
) WITHOUT ROWID;
CREATE INDEX idx_collection_items_asset ON collection_items (asset_id);

CREATE TABLE smart_collections (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    definition  TEXT    NOT NULL,                   -- JSON of sa_core::SearchQuery
    created_at  INTEGER NOT NULL,
    position    INTEGER NOT NULL DEFAULT 0
);

-- Persistent job queue (plan §6.6). One row per unit of work; idempotent by (kind, asset_id, variant).
CREATE TABLE jobs (
    id             INTEGER PRIMARY KEY,
    kind           TEXT    NOT NULL,                -- 'media', later 'embed', 'transcribe', ...
    asset_id       INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    variant        TEXT    NOT NULL DEFAULT '',
    lane           INTEGER NOT NULL DEFAULT 4,      -- 1 visible .. 5 maintenance
    state          INTEGER NOT NULL DEFAULT 0,      -- 0 queued, 1 leased, 2 done, 3 failed, 4 cancelled
    attempts       INTEGER NOT NULL DEFAULT 0,
    max_attempts   INTEGER NOT NULL DEFAULT 3,
    not_before     INTEGER NOT NULL DEFAULT 0,      -- backoff: do not lease before this time
    lease_token    TEXT,
    lease_expires  INTEGER,
    checkpoint     TEXT,
    error_class    TEXT,
    error_message  TEXT,
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    UNIQUE (kind, asset_id, variant)
);
CREATE INDEX idx_jobs_ready  ON jobs (kind, state, lane, id);
CREATE INDEX idx_jobs_lease  ON jobs (lease_expires) WHERE state = 1;

CREATE TABLE settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
) WITHOUT ROWID;
