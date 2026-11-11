-- Schema v3: embeddings (Phase 4, search by meaning). Derived data only: every row can be made again from the files,
-- and nothing here changes a file.

-- One row per way of making vectors. The id names everything that decides what a vector means (model, weights,
-- what was fed to it, how long it is), so vectors of two configurations are never compared with each other.
CREATE TABLE model_configs (
    id            TEXT PRIMARY KEY,
    model         TEXT NOT NULL,
    version       TEXT NOT NULL,
    modality      TEXT NOT NULL,
    dims          INTEGER NOT NULL,
    preprocessing TEXT NOT NULL,
    created_at    INTEGER NOT NULL
);

-- L2-normalised vectors stored as f16 (2 bytes per number, little endian). A picture has one row (slot 0); a video
-- has one per keyframe. Written by the Swift worker through the 'embed' job; the in-memory index is built from here.
CREATE TABLE embeddings (
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    config   TEXT NOT NULL REFERENCES model_configs(id) ON DELETE CASCADE,
    slot     INTEGER NOT NULL,
    vec      BLOB NOT NULL,
    PRIMARY KEY (asset_id, config, slot)
) WITHOUT ROWID;
