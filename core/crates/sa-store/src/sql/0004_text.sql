-- Schema v4: text in pictures (Phase 4, S4). Derived data only: the words macOS reads in a picture, or in a few
-- frames of a video, so a keyword search finds a screenshot, slide or title card by what it shows. Nothing here
-- changes a file.

-- One row per picture or video that has been read, including those with no text (empty), so they are not read again.
-- `reader` names how the text was read (e.g. 'vision-accurate-en-v1'); another reader reads the library again.
CREATE TABLE asset_text (
    asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    reader   TEXT NOT NULL,
    text     TEXT NOT NULL
);

-- The keyword index over that text, kept in step by the triggers below (also when a removed file or folder cascades
-- its rows away). Same tokenizer as asset_fts, so a typed word matches both the same way.
CREATE VIRTUAL TABLE asset_text_fts USING fts5 (
    text,
    content = 'asset_text',
    content_rowid = 'asset_id',
    tokenize = 'unicode61 remove_diacritics 2',
    prefix = '2 3 4'
);

CREATE TRIGGER asset_text_ai AFTER INSERT ON asset_text BEGIN
    INSERT INTO asset_text_fts(rowid, text) VALUES (new.asset_id, new.text);
END;
CREATE TRIGGER asset_text_ad AFTER DELETE ON asset_text BEGIN
    INSERT INTO asset_text_fts(asset_text_fts, rowid, text) VALUES ('delete', old.asset_id, old.text);
END;
CREATE TRIGGER asset_text_au AFTER UPDATE ON asset_text BEGIN
    INSERT INTO asset_text_fts(asset_text_fts, rowid, text) VALUES ('delete', old.asset_id, old.text);
    INSERT INTO asset_text_fts(rowid, text) VALUES (new.asset_id, new.text);
END;
