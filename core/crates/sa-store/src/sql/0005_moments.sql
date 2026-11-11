-- Schema v5: moments in videos (Phase 4, S2). A video has one vector per scene it was described at; `t_ms` says where
-- in the video that scene is, so a result can open the video at the moment that matched. NULL for pictures and for
-- vectors made before moments existed (their place in the video is unknown).
ALTER TABLE embeddings ADD COLUMN t_ms INTEGER;

-- Videos are described again, at scene changes instead of three fixed points. Dropping their finished jobs lets the
-- backlog queue them; their earlier vectors keep answering until the new ones replace them.
DELETE FROM jobs WHERE kind = 'embed' AND state = 2 AND asset_id IN (SELECT id FROM assets WHERE kind = 1);
