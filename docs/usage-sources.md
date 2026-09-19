# Local Usage logs

The common collection ladder stays in [`provider-collection.md`](provider-collection.md).

Usage parsing is independent from subscription-quota authentication. It reads local agent-owned
JSONL files and emits normalized usage-bearing model output facts plus typed scan coverage; it never
reads provider tokens for this path. One fact represents one persisted assistant/output response
whose Usage is measurable. Aggregated managed-data rows retain the released `requests` field; the
local-v3 summary exposes their sum as `messages`. This is neither a conversation count nor a session
count, and sessions are intentionally not collected. In v3 summaries, `total_tokens` is
`input_tokens + output_tokens`; cache-read and cache-write input tokens are subsets of input, and
reasoning tokens are a subset of output.

Provider grouping is by the vendor whose model answered, resolved from the raw model name by the
model catalog's family rules ([ADR 0009](decisions/0009-versioned-model-catalog.md)); `client`
records which agent emitted the usage-bearing output, and neither the agent nor the billing channel
chooses the group. The billing channel stays on every fact, resolved as the sections below say,
because pricing and audit depend on it; it says who was paid, not who made the model, and is never
consulted for the group. Summaries are nested as `agents[].providers[].models[]`; a name no family
claims is the `unknown` provider within its originating client.

A provider id resolves a channel only when it is a registered id that authenticates against that
vendor's own endpoints. Gateway spellings that merely proxy a vendor, such as an `-oauth` suffix on a
registered id, are not registered and stay unknown. `kimi-for-coding` and `moonshotai` resolve
`moonshot_direct`, `deepseek` resolves `deepseek_direct`, and `google` / `gemini` resolve
`google_direct`, for every collector that reads an explicit provider id: OpenCode, Pi, and Cursor. Relay reports every channel it stores as stored;
[ADR 0018](decisions/0018-single-managed-data-contract.md) retired the narrowing that once rewrote
channels newer than a released client to `unknown`.

### Report-time model catalog

Collectors preserve every non-empty bounded `model` value exactly as reported, including punctuation,
case, and unknown provider strings. Model cleanup is applied only while building a report from the
stored facts. The shared catalog names a model's vendor by explicit lowercase `families` prefixes,
matched ASCII case-insensitively with the longest prefix winning, and matches an alias on an explicit
`reported_model` and that vendor, with optional exact agent `client` and
`[effective_from, effective_to)` UTC-date scope; it does not use regex, fuzzy matching, or inferred
aliases. Resolved model groups use the stable
canonical ID, while unresolved breakdowns retain the raw value. Updating the catalog regroups
historical rows on the next report without reparsing source files or modifying SQLite/Relay facts.
This view is independent of pricing: pricing sees the raw model first, and normalization does not
make an otherwise unpriced fact priced.

### Codex Usage

1. Discover rollout JSONL files below `$CODEX_HOME/sessions` and
   `$CODEX_HOME/archived_sessions`, defaulting `CODEX_HOME` to `~/.codex`.
2. Track model and service-tier settings in file order. Convert each `token_count` record to a
   request delta, preferring a provider-supplied last-request usage and otherwise subtracting the
   previous cumulative total.
3. Preserve input, cache-read, inferred cache-write, output, reasoning, model, tier, speed, and
   context bucket. Without an explicit provider value, use the Codex default `openai_direct` channel;
   when `payload.model_provider` is present, only `openai` maps to `openai_direct` with an explicit
   source. Observed values such as `custom` or `rightcode` remain the unknown channel; the collector
   never infers a billing channel from model text. Codex `total_tokens` is a context counter, not the
   sum used for billing facts. Codex logs do not supply source cost.
4. Duplicate cumulative totals do not emit another request. Leading subagent facts that inherit but
   initially omit the model are buffered until that rollout supplies its model context. Model
   identifiers are opaque provider text and are preserved as received, including punctuation such as
   `GPT-5.5[1m]`; only empty/control-text identifiers and malformed numeric or timestamp data are
   isolated. An isolated record or file makes only its own coverage partial and never suppresses
   valid facts from other files.

### Claude Code Usage

1. Discover JSONL files below `$CLAUDE_CONFIG_DIR/projects`, defaulting `CLAUDE_CONFIG_DIR` to
   `~/.claude`.
2. Parse assistant usage records and retain the provider model plus input, cache-read,
   five-minute/one-hour cache-write, output, service tier, context bucket, and tool request counts
   that are explicitly represented. Empty optional dimension strings mean unknown. Claude's
   provider-owned `<synthetic>` model marker normalizes to `synthetic` only when the record contains
   tokens, billable tools, or nonzero source cost; an empty internal marker emits no Usage fact.
3. Resolve `anthropic_direct` only for a Claude model. Third-party models use the explicit unknown
   channel instead of being misclassified as Anthropic. Source-reported cost is retained only with its
   request-coverage count so an incomplete amount cannot be treated as a complete total.
4. Unknown usage-shaped records, malformed timestamps/dimensions, unreadable sources, oversized
   lines, and truncated tails make coverage partial.

### Grok Usage

1. Discover `updates.jsonl` below `$GROK_HOME/sessions`, defaulting `GROK_HOME` to `~/.grok`.
2. Parse `_x.ai/session/update` records whose nested `sessionUpdate` is `turn_completed` and Usage is
   present. Preserve the numeric Unix timestamp, exact reported model, inclusive input, cache
   read/creation, output, reasoning, exact source cost, and the `xai_direct` channel. Canceled turns
   with null Usage emit no fact.
3. Grok reports completed output turns as `numTurns`; use that value for `messages`, not the lower-level
   `modelCalls`. Current records contain one `modelUsage` entry. A multi-model record is partial until
   Grok exposes per-model output-turn counts, so the collector never invents message attribution.
4. `inputTokens` already includes cache-read and cache-creation tokens. Validate those fields as input
   subsets and do not add them again.

### OpenCode Usage

1. Prefer the read-only SQLite message store at `$XDG_DATA_HOME/opencode/opencode.db`, defaulting
   `XDG_DATA_HOME` to `~/.local/share`. If it is absent, read legacy message JSON below
   `storage/message`.
2. Parse assistant messages with nonzero tokens or source cost. Add cache-read and cache-write tokens
   to uncached input so protocol input remains the billable total. Resolve a billing channel only
   from an explicit recognized `providerID`; custom providers remain unknown. Gateway spellings such
   as `kimi-for-coding-oauth`, `right-code`, and `crabot-codex` are not registered ids and stay
   unknown.
3. Rust opens the SQLite database read-only and never mutates the agent-owned store.

### Pi Usage

1. Discover JSONL sessions below `$PI_CODING_AGENT_DIR/sessions` when configured; otherwise scan
   both `~/.pi/agent/sessions` and the older `~/.local/share/pi-coding-agent/sessions` location.
2. Parse persisted assistant messages and retain their provider, model, token/cache/reasoning usage,
   and nonzero source cost. Resolve only explicit recognized provider channels.

### Cursor Usage

1. Discover Composer JSONL under `projects/*/agent-transcripts` and CLI `store.db` files under
   `chats`, both inside `$CURSOR_HOME` or `~/.cursor`. Those two subtrees are the discovery roots;
   the Cursor home itself is not walked, because its `extensions/` tree alone exceeds the
   discovery bounds and would end the scan before it reached `projects/`. Also open the desktop
   `state.vscdb` at
   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` on macOS and
   `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb` on Linux, defaulting `XDG_CONFIG_HOME`
   to `~/.config`. Rust opens those SQLite files read-only and never mutates Cursor-owned stores.
2. Emit a fact only from an explicit usage-shaped record: JSONL `tokenCount` / `usage` /
   `message.usage`, desktop `cursorDiskKV` `bubbleId:` rows with `tokenCount`, or CLI `blobs` JSON
   that carries the same fields. Ignore zero-token/tool/cost records. Do not estimate tokens from
   transcript text, and do not treat `composerData.promptTokenBreakdown.totalUsedTokens` or
   `contextTokensUsed` as billing facts; those are conversation context meters, like Codex
   `total_tokens`.
3. Prefer per-bubble `tokenCount.inputTokens` / `outputTokens`. When an assistant bubble omits
   input, attach the preceding same-composer user bubble's tokens so one output response stays one
   fact. Preserve cache and reasoning fields only when the source reports them. Model identifiers
   stay opaque provider text (`modelInfo.modelName`, `model`, or `message.model`). Resolve a billing
   channel only from an explicit recognized provider field; never infer one from the model string.
   Cursor house models remain the unknown channel inside the `cursor` client.
4. Agent-transcript JSONL often has role/message text and no usage; that is complete empty coverage,
   not a malformed source. Binary or protobuf blobs are skipped. An unreadable database, invalid
   timestamp/model/usage field, or truncated source makes only that file partial.

### Gemini CLI Usage

1. Discover `session-*.json` and `session-*.jsonl` below `$GEMINI_HOME/tmp` or `~/.gemini/tmp`,
   which is `~/.gemini/tmp/<projectHash>/chats/` as the CLI's `Storage.getProjectTempDir()` writes.
2. A JSON conversation record is a `messages[]` array; JSONL is one object per line. Emit a fact
   from each `type: "gemini"` message that carries `tokens` (`input` / `output` / `cached` /
   `thoughts`). `input` already includes cached tokens. `thoughts` is added to output when it is
   not already a subset, so protocol output remains inclusive and reasoning stays a subset.
   Preserve the reported `model`. The session does not name a billing channel; store `unknown`.
3. Empty token objects emit no fact. Malformed timestamps or usage make only that file partial.

### Kilo Usage

1. Discover `kilo.db` below `$KILO_DATA_DIR` or `~/.local/share/kilo`. This is the Kilo CLI
   session store; Rust opens it read-only.
2. Parse assistant `message.data` JSON with the same token object OpenCode writes (`tokens.input` /
   `output` / `reasoning` / `cache.read` / `cache.write`, `time.created`, `modelID`, `providerID`,
   `cost`). Add cache-read and cache-write to uncached input. Resolve a billing channel only from an
   explicit recognized `providerID`. `directory` / `cwd` on the record, or `session.directory` when
   that table exists, becomes `project_key` as a basename ([ADR 0039](decisions/0039-project-attribution-stays-local.md)).
3. Empty token objects emit no fact. An unreadable database makes only that file partial.

### Antigravity Usage

1. Discover `*.db` conversation files under `$ANTIGRAVITY_DATA_DIR` (a data root or its
   `conversations/` folder) or, by default, `~/.gemini/antigravity`, `antigravity-cli`,
   `antigravity-ide`, `antigravity-backup`, and `~/.config/antigravity`, preferring a nested
   `conversations/` directory when it exists.
2. Read `gen_metadata.data` and, when present, `steps.metadata` protobuf blobs. Emit a fact from
   each token-bearing usage message: input, cache read/write, output, reasoning, and the model
   string the blob carries. Input is uncached plus cache. Reasoning is a subset of output. The log
   does not name a billing channel; store `unknown`. There is no cwd field; `project_key` stays
   empty on the fact. Duplicate identities (`response:`, `provider:`, `message:`) in one file are
   kept once.
3. An unreadable database or undecodable blob makes only that file partial.

### GitHub Copilot Usage

1. Discover `events.jsonl` below `$COPILOT_HOME/session-state` or `~/.copilot/session-state`, one
   file per session id. This is the Copilot CLI session log; it does contain token counts.
2. Prefer `assistant.usage` events (`data.model`, `inputTokens`, `outputTokens`,
   `cacheReadTokens`, `cacheWriteTokens`, `reasoningTokens`) as one fact per call. When a file has
   none, `session.shutdown` `data.modelMetrics.<model>.usage` is a cumulative rollup: emit the
   delta from the previous shutdown in that file so a resumed session is not counted twice.
   `inputTokens` that already include cache are kept; an exclusive input has cache added so
   protocol input remains the billable total. The log does not name a billing channel; store
   `unknown`. Shutdown `requests.cost` is a premium-request weight, not USD, and is not stored as
   source cost.
3. OpenTelemetry JSONL under `~/.copilot/otel` and `~/.copilot/session-store.db` are not read.

Cursor, Gemini CLI, GitHub Copilot, Kilo, and Antigravity are part of the single BillingAgent set
every managed contract carries.

All scanners preserve non-empty bounded model identifiers as opaque provider text, ignore zero-
token/tool/cost internal records, and use canonical `[start_at, end_at)` UTC-hour boundaries,
bounded directory traversal, a two-million-record scan ceiling, bounded line sizes, cancellation,
and source-change checks. SQLite records an opaque file identity, size, modification time, and
parser revision. Unchanged files are skipped; a changed file's normalized rows are replaced
transactionally. Paths and file-index metadata never enter a protocol submission or IPC state. Only
complete coverage is eligible for authoritative remote replacement; empty complete coverage is valid.
Discovery always covers every canonical local source. Local reports cover indexed history, while
remote replacement remains split losslessly into bounded protocol ranges. Record/file skips and
upload partitions are summarized by the QuotaBar diagnostics report.
