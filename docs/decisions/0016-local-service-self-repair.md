# ADR 0016: Local service self-repair

- Status: Superseded by [ADR 0021](./0021-identity-store-and-disposable-cache.md) on 2026-08-25
- Date: 2026-08-17

One owner-only `state.sqlite` held both identity and derived data, so a damaged image was a
judgement call and the service owned one control plane to make it: detect, classify, repair, record,
re-evaluate. Eight classes decided the disposition — a durable-image corruption could be salvaged, a
process residue cleared at open, stale health evidence refused, a rebuildable Usage index dropped and
recreated — while a 401, an expired token, a network error, or a malformed Usage record was
explicitly excluded so nothing salvaged an image over a provider problem. Six sites (Open,
RefreshStart, RefreshWorker, WriteFailure, DiagnoseRead, PostRefresh) each had an ordered action list
and a bound: open work had to finish inside QuotaBar's fifteen-second helper deadline, so it used a
metadata heartbeat write as its persist probe and was forbidden to `quick_check` or count the live
image. Salvage parked the live file as `state.sqlite.broken`, built `state.sqlite.salvage` from an
allowlist of small durable tables, verified that the copied installation id and session matched the
parked file, promoted, restored on failure, refused to run without `2 × live_size + 64 MiB` free, and
was capped at one attempt per call and one automatic attempt per UTC day. `get_state` carried a
required `repair` object — status, severity, phase, title, guidance, activity, a two-second heartbeat
and progress — which QuotaBar rendered as a repair page that blocked quit, with a 45-second stuck
watchdog on each side. Identity was never minted: an installation id was copied from the parked image
or the service failed closed asking for a reinstall.

It was replaced because the whole apparatus existed to decide something that stops being a question
once the two kinds of row live in different files —
[ADR 0021](./0021-identity-store-and-disposable-cache.md) makes the cache disposable and deletes
salvage, the repair session, and the watchdogs with it.
