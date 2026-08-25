-- A reading names what it measured and when. The stamp that said how long it stayed current
-- and the name of the collector that produced it are both derived or unread now, so neither
-- is part of a snapshot and a stored row carrying either no longer parses. One pass removes
-- both.
UPDATE quota_snapshots
SET snapshot_json = json_remove(snapshot_json, '$.valid_until', '$.source')
WHERE json_extract(snapshot_json, '$.valid_until') IS NOT NULL
   OR json_extract(snapshot_json, '$.source') IS NOT NULL;
