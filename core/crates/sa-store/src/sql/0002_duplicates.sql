-- Schema v2: duplicates (milestone M4: A1 exact, A2 near). Nothing here changes a file; it only records what was read.

-- Exact duplicates group by (size, content_hash). Only files that share a size and quick hash with another file are
-- ever hashed in full (they are the only ones that can be copies), so this index stays small.
CREATE INDEX idx_assets_content_hash ON assets (content_hash) WHERE content_hash IS NOT NULL;

-- Near duplicates: 64-bit difference hash and DCT hash, stored as the signed bit pattern. Images have one row
-- (slot 0), videos one per sampled keyframe (slots 0..2 at 20 %, 50 % and 80 % of the duration).
-- Written by the Swift worker through the 'phash' job; derived data, rebuilt whenever the file changes.
CREATE TABLE perceptual (
    asset_id  INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    slot      INTEGER NOT NULL,
    dhash     INTEGER NOT NULL,
    phash     INTEGER NOT NULL,
    PRIMARY KEY (asset_id, slot)
) WITHOUT ROWID;
