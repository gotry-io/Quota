# quota-service

Private QuotaBar helper. The public `quota` command only reads. The operations and the history
producer are stated in [docs/architecture.md](../../docs/architecture.md).

## IPC 5

The helper speaks newline-delimited JSON at `ipc_version` 5. After it opens local state it emits
`{"type":"event","event":"ready","ipc_version":5}`. QuotaBar must speak the same version; the Swift
client moves with that in the same ship.

`get_state.history_sync` is present while signed in and absent when signed out (the key is
omitted, not null):

```json
{ "enabled": false, "last_upload_at": null, "last_error": null }
```

`enabled` is the cached Account document's `history.sync` (absent is false). `last_upload_at` is
the last successful quota-history upload, or null. `last_error` is null, or one of
`history_sync_off`, `quota_history_full`, `network`, `invalid_response`,
`authentication_required`.

`quota_history` reads one range. `source` defaults to `local` (`cache.sqlite`, no network).
`account` reads one global-scope subscription from
`GET /api/v6/account/quota-history` and answers the same `samples_by_subscription` shape, with
`observed_at` set to the bucket start:

```json
{
  "since": "2026-08-22T00:00:00Z",
  "source": "account",
  "provider": "codex",
  "fingerprint": "account_test"
}
```

`set_account_settings` writes `alerts` and `budget`. `history` is included only when the write
names the switch:

```json
{ "history": { "sync": true } }
```

While `history.sync` is on, each collection uploads new global-scope buckets past the watermark
(`PUT /api/v6/device/quota-history`, at most 2 000 points and 256 KiB, oldest first). A
`false → true` transition backfills each window's span once. Watermarks and that fact live in
`identity.sqlite` `preferences`, keyed by Account, and are cleared on sign-out and on
`409 history_sync_off`. `413 quota_history_full` stops the upload until the next collection.
