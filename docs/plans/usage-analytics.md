# Quota Usage 采集、同步与成本分析技术方案

- Status: proposed
- Canonical: no
- Updated: 2026-08-09
- Baseline: `f6e9047187f81519ad4b9008e53ef22b3eb93f5f`

> 本文描述账号版 Quota 的目标实现，不代表当前已发布行为。产品边界见
> [`account-usage-requirements.md`](./account-usage-requirements.md)，身份、设备和删除事务见
> [`account-system.md`](./account-system.md)。实现时必须同步更新 canonical architecture、security、
> provider collection、protocol、migration 与 app 文档。

## 1. 最终结论

```text
Codex / Claude Code local logs
             |
             v
QuotaCLI collectors -> normalized request facts -> sparse hourly facts
             |                       |                    |
             |                  local report          JSON outbox
             |                       |                    |
             |              cached price catalog         v
             |                       |          QuotaRelay -> D1
             |                       |              |         |
             +-----------------------+              |         +-- device facts
                                                    |         +-- coverage/control
                                                    v
                                      account summary + cost calculation
                                                    |
                                      Web / QuotaCLI / QuotaBar UI
```

1. QuotaCLI 是唯一 collector、normalizer、local cache/outbox owner 和 native account client；QuotaBar
   只调 bundled CLI 并渲染 typed JSON。
2. 本地解析 Codex 与 Claude Code 日志。不上报原始日志、prompt、completion、tool 参数、路径、
   provider credential 或 session ID。
3. 上报单位是非空的 **sparse hourly facts**，不是 raw events，也不是不可逆的 daily-only totals。
4. D1 事实直接属于 `device_id`；account 授权和聚合通过 `devices.account_id` 完成，Usage row 不重复
   保存 `account_id`。
5. 断网、服务端失败或退出登录不丢数据。QuotaCLI 保留 durable outbox；再次登录会补传仍可从本地
   日志读取、且未被 deletion watermark 排除的历史。
6. 完整扫描区间才可权威替换远端事实。权限错误、超时、未知 record 或 parser partial 不得删除旧行。
7. 成本是首发能力。D1 保存可重算 billing facts 与可选 source-reported cost，不保存计算结果。
8. QuotaRelay 随部署维护唯一的 versioned/effective-dated price catalog，并以 ETag API 发布。QuotaCLI
   缓存目录；本地和 Relay 共用同一 runtime-neutral calculator。
9. `agent` 与 `billing_channel` 分离。同一个 model 在 OpenAI direct、Azure、Anthropic direct、Bedrock、
   Vertex、OpenRouter 等渠道可以有不同价格，不跨渠道猜测。
10. 默认 `calculate` 只使用 Quota 官方目录；未知价格显示 unpriced，不计为 `$0`。`auto` 和
    `reported` 是显式选择。
11. 首版只有一张 hourly fact 表；日报、月报和 all-time 由 D1 `GROUP BY` 得到。没有第二张 daily
    materialized table，只有实测查询/存储瓶颈后才增加。
12. 最终 runtime 只有 managed QuotaRelay/D1；不实现 self-hosted、SQLite Relay、pairing 或 owner 路径。

## 2. 与参考项目的对齐

| 项目 | 已验证做法 | Quota 采用/改进 |
| --- | --- | --- |
| [tokens schema](https://github.com/missuo/tokens/blob/main/web/src/lib/db/schema.ts) / [aggregator](https://github.com/missuo/tokens/blob/main/cli/tokens-core/src/aggregator.rs) | 服务端以 submission/device/date 保存 `daily_breakdown`；成本由客户端先计算并上传 | 保留设备和长期历史，但上传原始 billing facts，按小时保存，并把 billing channel 留在事实键中，支持服务端统一重算 |
| [ccusage](https://github.com/ccusage/ccusage) | 调用时读取本地日志，支持 daily/weekly/monthly/session 报告并缓存价格 | 复用 parser fixture、token/cost breakdown 与离线报告思路；增加可靠 outbox、账号多设备和长期远端存储 |
| [openusage](https://github.com/janekbaraniewski/openusage/blob/main/docs/site/docs/daemon/storage.md) | 本地 SQLite 保存短期完整 events，长期保存 daily rollup | 保留近期趋势和 burn-rate 所需时间信息，但远端只存 privacy-preserving sparse hourly facts，不上传 events，也不引入 daemon/SQLite |

Quota 与三者的能力对齐包括：input/output/cache/reasoning、模型和 agent breakdown、日/月/总计、
成本、未知价格提示、离线本地查看和历史补传。Quota 额外提供 account 多设备、渠道定价、服务端统一
重算和 Web Delete Device 的可证明删除。

不复制的实现：tokens 的客户端权威成本、ccusage 的每次全量读取、openusage 的 event DB/daemon，
以及任何运行时 LiteLLM/models.dev/OpenRouter price-service 依赖。

## 3. 数据语义

### 3.1 Token facts

每条 normalized request 至少包含：

```ts
interface NormalizedUsageEvent {
  occurred_at: string; // RFC 3339 instant
  agent: "codex" | "claude_code";
  model: string;
  billing_channel: BillingChannel;
  channel_source: "explicit" | "agent_default" | "unknown";

  input_tokens: number;
  cache_read_tokens: number;
  cache_write_5m_tokens: number;
  cache_write_1h_tokens: number;
  cache_write_inferred_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  requests: number;

  context_bucket: ContextBucket;
  service_tier: string;
  speed: string;
  inference_geo: string;
  billable_tools: Partial<Record<"web_search" | "web_fetch", number>>;

  source_cost_microusd?: bigint;
  source_cost_covered_requests: number;
}
```

统一定义：

- `input_tokens` 是总输入；cache read/write 都是其子集。
- `output_tokens` 是总输出；`reasoning_tokens` 是其子集，计价时不能再次相加。
- `cache_write_5m + cache_write_1h + cache_write_inferred` 是总 cache write；无法区分 TTL 时进入
  inferred bucket，并在成本结果中暴露 assumption。
- `uncached_input = input - cache_read - cache_write_*`，任一子集超过 total 时整条 record 无效。
- 所有 count 都是非负 safe integer；aggregate 也必须检查溢出。
- billable tool 仅接受固定 allowlist 和非负次数，不接收任意 tool name 或内容。

### 3.2 Request-level context bucket

长上下文价格阈值必须在单个 request 上判断，不能从小时/日 token 总量反推。先把 normalized request
放入固定 bucket，再聚合：

```text
le_128k
gt_128k_le_200k
gt_200k_le_256k
gt_256k_le_272k
gt_272k
```

这些 bucket 是计价 contract，不表示所有 provider 都使用每个阈值。目录 entry 只声明适用项。

### 3.3 Agent、渠道与模型

- `agent` 表示日志来源/客户端：`codex`、`claude_code`。
- `billing_channel` 表示价格来源：首版 bounded catalog 至少支持 `openai_direct`、`azure_openai`、
  `anthropic_direct`、`aws_bedrock`、`google_vertex`、`openrouter`、`unknown`。
- 当前 Codex/Claude Code 日志没有可靠显式渠道时，分别写入 API-equivalent direct channel，并标记
  `channel_source=agent_default`；UI 必须把它作为估算假设，而不是声称识别了真实付款渠道。
- 明确记录的渠道使用 `explicit`；无法判断且没有安全默认时使用 `unknown` 并保持 unpriced。
- model ID 经过长度/字符/alias allowlist 规范化，但只有 price catalog 中声明的 alias 可解析。禁止
  fuzzy match 或跨 channel fallback。

### 3.4 小时与 timezone

每个 event 同时投影为：

- `bucket_start_utc`：事件所在 UTC 小时的起点；
- `usage_date`：pinned device IANA timezone 下的本地日期；
- `usage_hour`：同一 timezone 下的本地小时；
- `aggregation_timezone`：用于该次聚合的 IANA timezone。

事实主键为：

```text
(device_id, bucket_start_utc, usage_date, usage_hour,
 agent, billing_channel, channel_source, model,
 context_bucket, service_tier, speed, inference_geo)
```

半小时/四十五分钟 offset 时，同一 UTC 小时可能跨两个本地小时，因此允许相同
`bucket_start_utc` 产生两个 `usage_hour` rows。价格 effective date 从 `bucket_start_utc` 的 UTC 日期
推导，不另存易漂移的 `pricing_date`。

按日/月报告使用提交时的 `usage_date`，不随 viewer timezone 重切历史；跨设备小时趋势按
`bucket_start_utc` 汇总。UI 在设备 timezone 不一致时显示 timezone assumption。

## 4. 本地采集设计

### 4.1 Package boundary

```text
packages/provider
  Codex / Claude Code discovery, parsing, redaction, normalized events

packages/quota-model/src/usage
  fact schema, invariants, aggregation, report fold

packages/quota-model/src/pricing
  catalog schema, validator, resolver, calculator
  (不包含 canonical catalog data)

apps/cli
  discovery orchestration, file IO, local cache/outbox, catalog fetch/cache,
  login-aware sync, local/account JSON commands

packages/relay-core
  UsageState contract, authoritative replacement, account summary fold

apps/relay
  deployed catalog resource/API, D1 adapter, HTTP/auth
```

provider 不依赖 CLI/Relay；calculator 不依赖 Node、D1 或 Cloudflare。Relay app 将部署目录注入
relay-core，QuotaCLI 将远端缓存目录注入同一 calculator。

### 4.2 Codex 与 Claude Code

每个 parser 必须：

- 只打开 canonical collection 文档允许的日志位置；不盲扫整个 home。
- 以 fixture 固定已知 schema variants；未知 record 返回 typed partial coverage，不静默吞掉。
- 以 source file identity + record offset/hash 去重，避免 incremental scan 和 full rescan 重复。
- 先验证 token subset/total，再生成 normalized event。
- 从 event timestamp 与 pinned timezone 生成小时事实。
- 不把路径、session/conversation ID、prompt、completion、tool payload 放入 normalized event/outbox。

Codex 本地 JSONL 当前不提供价格。Claude Code 某些 records 可能提供 `costUSD`，但 coverage 不完整；
它只进入可选 source-reported fields，不是默认成本权威。

### 4.3 Coverage safety

Collector 对每个 `agent + [start_at, end_at)` UTC-hour interval 返回：

```ts
type ScanCoverage = {
  agent: "codex" | "claude_code";
  start_at: string; // canonical UTC hour boundary
  end_at: string;   // exclusive canonical UTC hour boundary
  status: "complete" | "partial";
  reasons: readonly CoverageReason[];
};
```

只有满足以下条件才是 `complete`：所有计划 source 均可读、所有目标 records 已处理、无 permission/
timeout/parser error、范围边界确定。完整范围可进入 authoritative outbox；partial 范围只在本地报告
coverage，服务端不得删除或替换该范围的旧行。

范围按 UTC 整小时切块。空的 complete range 是合法权威结果，可清除远端同范围旧行；partial empty
不是删除信号。

### 4.4 Cache、lock 与 outbox

QuotaCLI 在用户级 Quota state root 保存：

```text
installation.json       # random installation identity
session.json            # account/device sessions; owner-only
usage-cache.json         # source fingerprints + normalized aggregate cache
usage-outbox.json        # immutable pending submissions
pricing-catalog.json     # last validated catalog + revision/etag
state.lock               # all CLI writers share one lock
```

文件必须 owner-only、拒绝 symlink/非 regular file、atomic replace。QuotaBar 不读这些文件。

`usage-cache` 不是远端事实权威，只用于增量扫描。source 变更、parser revision、timezone 变更或
deletion watermark 可能切开已有 bucket 时，失效相关 cache 并从本地日志重建；绝不复用无法安全切分的
旧 aggregate。

Outbox entry 在完整扫描后一次性写入，包含 submission ID、device generation、sequence、coverage 和
facts。HTTP timeout/5xx 保留并重试；明确 accepted/duplicate 才删除；stale generation/deleted 是
terminal，丢弃该 generation 的 outbox 并按 server watermark 重建。

退出登录时立即停止所有上传，保留 cache/outbox。本地后台不刷新目录；显式 local report 可使用最后
有效目录。再次登录后先获取 sync control/catalog，再 backfill 和 drain outbox。

## 5. Wire protocol

Protocol 变更从 `packages/protocol` 开始，runtime schema、JSON Schema、tests 与 Swift decoding 同步。

### 5.1 Upload envelope

```ts
interface UsageSubmissionV2 {
  protocol_version: 2;
  submission_id: string;
  device_id: string;
  generation: number;
  sequence: number;
  parser_revision: string;
  aggregation_timezone: string;
  coverage: {
    agent: "codex" | "claude_code";
    start_at: string;
    end_at: string;
    status: "complete" | "partial";
  };
  rows: UsageHourlyFact[];
}

interface UsageHourlyFact {
  bucket_start_utc: string;
  usage_date: string;
  usage_hour: number;
  agent: "codex" | "claude_code";
  billing_channel: string;
  channel_source: "explicit" | "agent_default" | "unknown";
  model: string;
  context_bucket: string;
  service_tier: string;
  speed: string;
  inference_geo: string;
  input_tokens: number;
  cache_read_tokens: number;
  cache_write_5m_tokens: number;
  cache_write_1h_tokens: number;
  cache_write_inferred_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  requests: number;
  web_search_requests: number;
  web_fetch_requests: number;
  source_cost_microusd?: string;
  source_cost_covered_requests: number;
}
```

Wire JSON 使用 snake_case；micro-USD 用十进制字符串避免 JSON number 精度问题。服务端验证：

- coverage 是 canonical UTC-hour boundaries，`start_at < end_at` 且不超 bounded range；
- 每行 `bucket_start_utc` 在 coverage 中、agent 相同；
- date/hour/timezone 与 bounded dimensions 合法；
- token 子集、count、source coverage 守恒；
- rows、models、body size、range 和响应均有显式上限。

`partial` submission 是安全 no-op：不写 rows、不推进 authoritative coverage，返回 typed partial
outcome。CLI 正常情况下不发送它；保留服务端检查是为了防止 buggy client 删除数据。

### 5.2 Read contract

```text
GET /api/v2/account/usage
  ?from=YYYY-MM-DD&to=YYYY-MM-DD
  [&device_id=...][&cost_mode=calculate|auto|reported]
  account:read; bounded daily/agent/model/device/channel breakdown

GET /api/v2/account/usage/hourly
  ?start_at=<RFC3339>&end_at=<RFC3339>
  [&device_id=...][&cost_mode=calculate|auto|reported]
  account:read; tightly bounded UTC-hour series

GET /api/v2/account/usage/summary
  [?device_id=...][&cost_mode=calculate|auto|reported]
  account:read; all-time totals, no unbounded bucket array

GET /api/v2/pricing/catalog
  public; immutable-by-revision body, ETag/If-None-Match, cacheable
```

Responses always include token totals, device/agent/model/channel breakdown, coverage, cost status/basis,
catalog revision, assumptions and bounded unpriced items. Arrays are deterministic. QuotaCLI exposes the same
typed model to local CLI output and QuotaBar；Web consumes the same account API contract.

## 6. 价格目录与成本计算

### 6.1 唯一目录所有权

Canonical price catalog 是 `apps/relay` 的受版本控制 deploy resource，不是 D1 表，也不嵌入 CLI
binary。更新流程是：

1. 从 provider/渠道官方价格页核对价格、currency、单位、区域、tier/context 与生效日；例如
   [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)、
   [GPT-5.4 model pricing](https://developers.openai.com/api/docs/models/gpt-5.4)、
   [OpenAI Fast mode](https://openai.com/api-fast-mode/) 与
   [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)。Azure、Bedrock、Vertex、
   OpenRouter 也必须使用各自渠道的官方来源，不能套用 direct channel 价格；
2. 修改 catalog resource 与 fixtures，review diff；
3. 同一 calculator 对历史/边界 fixtures 通过后随 Relay 部署；
4. catalog revision 改变，API ETag 改变；客户端下次刷新即可使用，不需要发布新 CLI。

第三方 catalog 只能作为维护时的差异提示。运行时不能访问 LiteLLM/models.dev，也不能让第三方变更
自动成为 Quota 价格。首版不做 D1 price table、admin UI、定时抓取或通用 pricing service。

目录包含当前和已验证的历史 entries。若无法证明某价格的历史生效日，则从首次验证日开始；更早 Usage
保持 unpriced，不能把今天价格反推到过去。

### 6.2 Catalog entry 与精确解析

价格解析键：

```text
(billing_channel, model, effective_date,
 service_tier, speed, inference_geo, context_bucket)
```

Entry 包含：

- stable catalog/revision 与 entry ID；
- exact channel/model 或受审 alias；
- `effective_from` 和可选 exclusive `effective_to`；
- currency=`USD`、per-million token rates；
- uncached input、cache read、cache write 5m/1h、output rates；
- allowlisted per-request tool rates；
- tier/speed/geo/context constraints；
- provider 官方 source URL 与 verified-at metadata。

同一键至多一个有效 entry。找不到 exact entry、channel=`unknown`、TTL inferred 但目录没有 default，或
任一实际 billing dimension 无 rate 时，该 row 为 unpriced/partial。禁止跨 channel、region、tier、
context fallback；只有 catalog 明示的 wildcard/default 才可用，且结果必须显示 assumption。

### 6.3 Cost modes

```ts
type UsageCostMode = "calculate" | "auto" | "reported";
type CostBasis = "calculated" | "reported" | "mixed" | "none";
type CostStatus = "complete" | "partial" | "unavailable";
```

- `calculate`（默认）：只用 Quota catalog 和 billing facts。无 exact price 即 partial/unavailable。
- `auto`：优先 calculated；仅当整行没有 catalog price 且 source-reported 覆盖该行全部 requests 时，
  才使用 source cost。一个 report 可以由不同完整 rows 形成 `mixed` basis。
- `reported`：只使用 source-reported cost；未完整覆盖的部分保持 partial，不用 catalog 填补。

Codex 没有 source cost；Claude Code 的 source cost 也可能不完整，因此默认不能是 reported/auto。

### 6.4 Formula、精度与展示

对每个 stored hourly dimension row 单独计价：

```text
uncached_input * input_rate
+ cache_read * cache_read_rate
+ cache_write_5m * cache_write_5m_rate
+ cache_write_1h * cache_write_1h_rate
+ cache_write_inferred * declared_default_cache_write_rate
+ output * output_rate
+ SUM(allowlisted_tool_count * unit_rate)
```

`reasoning_tokens` 已包含在 output 中，不重复收费。Calculator 使用 BigInt/rational decimal，在单个
stored row 完整求和后 half-up round 一次到 integer micro-USD；report 只累加整数。D1 不保存该
calculated amount，目录更新可重新计算历史。

显示 contract：

```text
$12.34 estimated      complete
≥ $12.34 partial      priced subset only
— unpriced            no defensible amount
```

所有界面同时展示 `basis`、catalog revision、channel assumption 与 unpriced count。API-equivalent cost
不是 ChatGPT/Claude subscription 实际支出，也不是 provider invoice。

## 7. 同步、幂等与删除

### 7.1 Server acceptance

`PUT /api/v2/device/usage` 只接受 device principal。一个 D1 transaction 完成：

1. 验证 token/device、generation、deletion watermark、sequence 和 body limits；
2. 以 `(device_id, submission_id)` 幂等判重；
3. 拒绝 partial coverage；
4. 删除该 device + agent + `[start_at,end_at)` 的旧 hourly rows；
5. 插入本次 sparse rows；
6. 更新 coverage、accepted sequence、submission receipt 与 `last_seen_at`；
7. commit 后返回 accepted revision/next sequence。

同一 range replacement 必须先删范围内所有 local-date/hour/dimension variants，再插入，才能正确处理
timezone 或 parser revision 变化。空 complete submission 会只删除该范围。

HTTP retry 使用同一 submission ID/sequence。duplicate 返回原 accepted outcome；sequence conflict、
stale generation 和 deleted before watermark 返回不同 typed outcome，不能模糊成 retryable 500。

### 7.2 Logout、backfill 与 Web delete

- Logout：本地先禁用上传，再 best-effort revoke；远端 facts 和 device row 保留。
- Re-login：同 account + installation 恢复 device ID，读取 current generation/watermark，扫描仍存在的
  本地历史并补传；退出期间没有永久 exclusion。
- Delete Device：同一 lifecycle transaction revoke tokens、advance generation、set precise
  `deleted_before`、删除 quota/hourly/coverage/receipt rows，并保留最小 hidden tombstone。
- Stale outbox：旧 generation 永久拒绝；CLI 丢弃并重建。若 watermark 切开某个小时，只从原日志按
  event instant 重建 post-watermark facts，不能复用不可切分 aggregate。
- 同 installation 再登录：复用 stable device ID，但以新 generation 和空历史开始，仅允许 watermark
  后的新活动。

## 8. Relay persistence 与查询

### 8.1 Runtime-neutral state

`UsageService` 依赖最小 `UsageState` contract；contract 接受 device principal、coverage、facts、
account authorization 和 lifecycle control，不接受 `D1Database` 或 SQL rows。当前只实现
`D1UsageState`，不增加 SQLite parity/repository factory。

### 8.2 D1 tables

最终 migration 使用显式表（字段名以 protocol review 后为准）：

```sql
CREATE TABLE usage_hourly (
  device_id TEXT NOT NULL,
  bucket_start_utc TEXT NOT NULL,
  usage_date TEXT NOT NULL,
  usage_hour INTEGER NOT NULL,
  aggregation_timezone TEXT NOT NULL,
  agent TEXT NOT NULL,
  billing_channel TEXT NOT NULL,
  channel_source TEXT NOT NULL,
  model TEXT NOT NULL,
  context_bucket TEXT NOT NULL,
  service_tier TEXT NOT NULL,
  speed TEXT NOT NULL,
  inference_geo TEXT NOT NULL,

  input_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL,
  cache_write_5m_tokens INTEGER NOT NULL,
  cache_write_1h_tokens INTEGER NOT NULL,
  cache_write_inferred_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  reasoning_tokens INTEGER NOT NULL,
  requests INTEGER NOT NULL,
  web_search_requests INTEGER NOT NULL,
  web_fetch_requests INTEGER NOT NULL,
  source_cost_microusd TEXT,
  source_cost_covered_requests INTEGER NOT NULL,

  PRIMARY KEY (
    device_id, bucket_start_utc, usage_date, usage_hour,
    agent, billing_channel, channel_source, model,
    context_bucket, service_tier, speed, inference_geo
  )
);
```

另有 bounded `usage_coverage`、`usage_submissions`/receipt 和 device lifecycle control；具体字段与
account migration 合并 review。所有业务 rows 以 `device_id` 外键关联 devices，不保存 `account_id`。

不建 price table、calculated cost column、raw event table、prompt/tool table或 daily rollup table。
为实际查询添加最少索引：device + UTC hour、device + local date。索引与 D1 statement chunk size 在
实现时根据当前官方 limits 和 query plan 验证，不把易变数字写死在设计中。

### 8.3 Account query

D1 adapter 可执行高效 join：

```text
usage_hourly JOIN devices
  ON usage_hourly.device_id = devices.id
 WHERE devices.account_id = authorized_account_id
```

随后在 SQL 层按请求 group：

- daily/monthly：`usage_date`；
- hourly：`bucket_start_utc`；
- breakdown：device、agent、model、billing channel；
- all-time：只 totals，不返回无限 bucket array。

Calculator 输入必须保留全部 billing dimensions 和 source coverage，不能在 price resolution 前把
不同 channel/model/context/tier rows 合并。Relay 注入当前 catalog revision 计算 response；Web 不接触
raw facts 或 price table。

首版先用单表和 bounded queries。只有 production query plan/latency/row growth 证明必要，才新增 daily
materialized table；届时它是可重建 projection，不是第二事实来源。

## 9. 隐私、安全与保留

- 上传 schema 使用严格 allowlist；拒绝未知 keys 和自由文本 metadata。
- 不上传 prompt/completion、tool arguments/results、paths、session/conversation IDs、provider keys/
  cookies/tokens、原始 timestamps 序列或 raw events。
- Model、channel、timezone 等字符串有长度和枚举/字符限制；错误日志只记录 bounded reason/code/count。
- Device token 只可写自身；account token 只读 summaries；Web recent-auth 才可 Delete Device/Account。
- Credential responses `Cache-Control: no-store`；catalog 可 public cache，因为不含用户数据。
- Device inactive 不触发历史 GC。数据保留到 Web Delete Device、Delete Usage 或 Delete Account。
- Account export 可分页导出 normalized hourly facts/coverage，不包含凭证、raw logs 或 calculated cost；
  价格目录 revision 作为解释 metadata。

## 10. Verification contract

### 10.1 Parser 与 aggregation

- Codex/Claude fixtures 覆盖已支持 schema、cache read/write、reasoning、model switch、timezone/DST、
  fractional offset、malformed/unknown record 和 truncated file。
- total/subset invariants 在 event、hourly fact、daily fold、account fold 都成立。
- 同一 UTC 小时跨两个本地小时的 fixture 生成两行，UTC total 守恒。
- source file append/truncate/rotate/full rescan 不重复计数。
- permission/timeout/unknown record 产生 partial coverage，旧 remote rows 保留。
- raw prompt/path/session/tool payload 不能出现在 normalized JSON、outbox、logs、D1 或 export。

### 10.2 Pricing

- 每个 billing channel 至少一个 exact fixture；相同 model 不同 channel 得到预期不同金额。
- effective_from/to 边界、alias、context threshold、cache 5m/1h/inferred、tier、speed、geo 和 tool unit
  rates 都有 official-source fixture。
- `calculate` 默认；`auto` 只对 fully covered source row fallback；`reported` 不补算。
- Unknown model/channel/dimension 显示 partial/unpriced，永不 `$0`，永不 fuzzy/cross-channel fallback。
- BigInt/rational 与 half-up once-per-row fixture 跨 CLI/Relay 一致。
- Catalog schema/revision/ETag validation、atomic cache、304、损坏下载保留旧 cache 均通过。
- 同一 facts + catalog revision 在 local CLI 和 Relay 得到 byte-equivalent typed cost summary。

### 10.3 Sync、D1 与 lifecycle

- accepted response 前 crash/timeout 可用同 submission 重试且只写一次。
- complete empty range 可删除；partial/invalid range 完全不改 rows/coverage/sequence。
- authoritative hour replacement 删除旧 dimension variants，再原子写新 rows。
- D1 transaction rollback 保持事实、coverage、receipt、sequence 和 last_seen 全部不变。
- 两台/多台 devices 只能写自身；account summary 为 authorized devices 之和且支持 device breakdown。
- Logout 停止上传但保留远端；re-login backfill；Web delete 后旧 token/outbox/full rescan 不能复活数据。
- Delete Device/Account、export、hour/day/month/all-time 和 catalog update repricing E2E 通过。

### 10.4 Release gate

实现属于 protocol/persistence/account/provider 的 cross-cutting change，完成后运行 repository 要求的
root format/check/test/build、protocol/model/provider/Relay tests、D1 migration/dry-run、Swift decoding
与真实 QuotaBar + bundled CLI account E2E。任何平台检查不能运行时必须明确记录。

## 11. 实施拆分

| ID | Work package | 内容 | Exit |
| --- | --- | --- | --- |
| U0 | Contract | hourly fact、UTC coverage、channel、cost/read schemas | Protocol/Swift/runtime schema 一致 |
| U1 | Codex collector | discovery、parser、fixtures、coverage | 全量/增量/partial/redaction 通过 |
| U2 | Claude collector | discovery、parser、source cost coverage、fixtures | 同上且不信任不完整 cost |
| U3 | Aggregation | timezone/hour buckets、dimensions、invariants | fractional offset 与 fold 守恒 |
| U4 | Pricing | schema/calculator + Relay catalog/API + CLI cache | channel/effective-date/ETag fixtures 一致 |
| U5 | Local state | cache、lock、outbox、local report、backfill | crash/retry/logout/re-login 无丢失 |
| U6 | Relay state | migration、authoritative replacement、queries | D1 transaction/lifecycle tests 通过 |
| U7 | HTTP/CLI | device upload、account reads、typed commands | scopes/limits/idempotency 通过 |
| U8 | Product UI | Web Usage/device views、QuotaBar rendering/export/delete | 三端 totals/cost/coverage 一致 |
| U9 | Cutover | 删除 owner/pairing/self-hosted/SQLite，更新 canonical docs | managed-only release gates 通过 |

U1/U2/U3 可与 Account auth 并行；U6 使用 synthetic account/device principal。共同集成点只有
device generation/deletion watermark、account authorization 和 final protocol schemas。

## 12. Review 结论与风险

### 为什么是 hourly，不是 events 或 daily-only

- Events 能力最全，但隐私、存储、传输和删除成本明显更高；本产品不需要远端 prompt/session 级审计。
- Daily 成本最低，但会永久丢掉 24/72h 趋势、hour chart、burn rate 与约 5h window 能力。
- Sparse hourly 最多只为有活动的 hour/dimension 建行，保留产品需要的时间信息；日/月/总计可直接折叠。

### 为什么价格在 Relay、计算库共享

- 本地日志通常没有可靠价格，特别是 Codex；让每个 CLI 内置价格会要求发版才能更新并造成版本漂移。
- Relay 发布唯一 catalog，CLI 仍能离线使用最后有效 revision；同一 calculator 避免公式分叉。
- 目录不是用户数据，不需要 D1/admin service；version-controlled deploy 已满足 review、回滚和审计。

### 已知边界

1. API-equivalent cost 不等于 subscription invoice；agent-default channel 必须可见。
2. 复制同一日志到多台 device 会重复，MVP 不上传 session ID 做跨设备去重；device breakdown 用于发现。
3. 完全删除本地状态会生成新 installation/device；不使用 MAC/serial 修复。
4. 退出期间会在重新登录后补传；永久排除需独立显式功能。
5. Hourly row cardinality 高于 daily；先用 bounded dimensions、sparse rows 和 query limits，按实测再投影。
6. Catalog 需要持续维护；未知/历史无证据的价格宁可 unpriced，也不猜测。
7. Migration number 在合并最新 main 后分配；不修改已应用 migration，不为未发布数据保留兼容层。

在 canonical 文档、协议、migration 和代码合入前，本文保持 proposed/non-canonical。
