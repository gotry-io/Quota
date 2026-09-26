-- A signed-in client may ask this Account's Macs to collect now
-- (docs/decisions/0063-collection-follows-demand-and-activity.md). The request is one
-- timestamp on the Account: the newest instant a request was accepted, NULL when none ever
-- was. It is not `updated_at`, which the activity read's ETag follows, and it names no
-- provider, device, or requester. Delete Account removes it with the row.
ALTER TABLE accounts ADD COLUMN collection_requested_at TEXT;
