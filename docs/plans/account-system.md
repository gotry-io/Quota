# Quota Account 技术方案

- Status: proposed
- Canonical: no
- Updated: 2026-08-09
- Baseline: `f6e9047187f81519ad4b9008e53ef22b3eb93f5f`
- Scope: GitHub-only account、Web/QuotaCLI login、QuotaBar UI shell、direct account-device ownership、
  managed-only Relay

> 本文是目标实现方案，不描述当前已发布行为。产品语义以
> [`account-usage-requirements.md`](./account-usage-requirements.md) 为准。当前 canonical 边界仍见
> [`architecture.md`](../architecture.md)、[`security.md`](../security.md) 和现有 ADR；实现账号版时需
> 用新 ADR 明确 supersede 旧 owner/pairing/self-hosted 决策。

## 1. 结论

当前 account → owners → devices 方案不符合最新需求，应整体删除。最终模型只有：

```text
GitHub OAuth (only external IdP)
     |
     v
Quota Account System
     |
     +── Web ── account session
     |
     └── QuotaCLI ─┬─ account session ── all-device read
                  └─ device session ── current-device quota / Usage upload

QuotaBar UI ── fixed commands / JSON ──> bundled QuotaCLI
```

具体决策：

1. `Account` 直接拥有 `Device`。删除 owner、owner session、account-owner link、canonical owner、claim
   和 owner-approved pairing。
2. Web 和 QuotaCLI 登录的是 Quota account；Quota 账号系统只使用 GitHub 作为外部 IdP。账号不
   存在即创建，存在即恢复；没有独立注册流程。
3. QuotaCLI 的 OAuth 完成事务同时 upsert 本机 device，并签发 account-read 与 device-scoped
   credentials；登录就是绑定。QuotaBar 只启动 bundled CLI 的同一登录流程。
4. Web 使用 browser account session；QuotaCLI 持有分离的 account session 与 device session。
   QuotaBar 不是 principal，不持有任何 session。GitHub token 永不发给客户端。
5. Logout 立即停止本机上传并撤销 session，但不删 device 或业务数据。Web Delete Device 才删除
   quota/Usage、撤销 device sessions 并隐藏 device。
6. 客户端随机生成并持久化 `installation_id`；服务端以
   `(account_id, HMAC(account_id + installation_id))` 幂等恢复同一个 opaque `device_id`。
7. Bundled/standalone QuotaCLI 是 identity、account/device sessions、sequence、lock、Usage cache
   和 outbox 的唯一所有者。QuotaBar 只调用签名 bundled CLI 并渲染结构化输出，不直接读写
   这些状态。
8. 唯一远端 origin 是 `https://quota.gotry.io`。删除动态 discovery、Relay URL、self-hosted runtime 和
   旧协议兼容路径。
9. Account 是 runtime-neutral 领域。`D1AccountState`/`D1UsageState` 是 managed adapter，不得让
   `D1Database`、SQL row 或 Cloudflare binding 进入 service/API contract。
10. 不迁移任何现有 owner/device/data/token。最终代码直接实现新模型；数据库通过显式 destructive
    migration 或受控 reset 到最终 schema。
11. 价格目录由 QuotaRelay 唯一维护并通过公共、可缓存的版本化 API 发布。QuotaCLI 获取并缓存；
    QuotaBar 和 Web 不维护目录，也不自行实现计价逻辑。

## 2. 设计原则

### 2.1 两类权限，不是两种登录体验

用户只看到“使用 GitHub 登录”，但客户端拿到的权限按职责拆开：

| Principal | 保存位置 | 能力 | 明确禁止 |
| --- | --- | --- | --- |
| Web account session | HttpOnly Secure cookie | 读全部 devices/quota/Usage；删 device；管理 sessions/account | 上传 device data |
| QuotaCLI account session | owner-only QuotaCLI state | 读全部 devices/quota/Usage；撤销自身 session | 删 device/account；写 device data；携带进 routine upload |
| QuotaCLI device session | owner-only QuotaCLI state | 写自身 quota/Usage；读取自身 sync control；注销自身 | 读账号历史；删其他 device |
| QuotaBar | 无凭证 | 启动签名 bundled CLI；显示无敏感信息的 JSON 结果 | 直接读 CLI 状态；直接请求账号 API |
| GitHub access token | Worker callback memory only | 一次性读取 stable GitHub identity | 持久化或下发任何 Quota client |

QuotaCLI 是完整客户端，因此登录后保留两类 Quota session。权限分离仍有价值：无人值守的
`sync` 路径只使用 device session，显式 account read 命令才使用 account session。QuotaBar
只是 CLI 前端，不新增第三类凭证或独立账号客户端。

### 2.2 Account 不是 D1

建议领域边界：

```text
packages/relay-core/src/account.ts
  AccountRecord / DeviceRecord / principals / state outcomes
  AccountState contract, including device lifecycle transactions

apps/relay/src/account/
  AccountService / GitHubIdentityClient / HTTP routes
  no D1 types

apps/relay/src/state/d1-account-state.ts
  D1AccountState implements AccountState

apps/relay/src/state/d1-usage-state.ts
  D1UsageState implements UsageState
```

Service 只依赖最小 contract。当前只有 D1 adapter；不为已删除的 self-hosted runtime 实现 SQLite
parity，也不为未来数据库建立 repository/factory 层。

### 2.3 Device 是数据与生命周期边界

- quota snapshots、Usage hourly facts、coverage 和 upload sequences 全部以 `device_id` 为直接外键。
- Account query 在鉴权后按 `devices.account_id` 过滤/聚合。
- Logout 只影响 sessions/status；Delete Device 是 device 级数据删除原语。
- Web browser 不是 collector，不创建 device。
- Provider account fingerprint 只用于 quota presentation merge，不参与 Quota account/device identity。

## 3. 身份模型

### 3.1 GitHub identity

GitHub OAuth 是唯一 IdP。服务端每次完成登录后调用 GitHub user endpoint，读取 immutable numeric user
ID，并计算：

```text
github_subject_hash = HMAC-SHA-256(GITHUB_SUBJECT_KEY, "github:" + numeric_user_id)
```

`accounts.github_subject_hash` 唯一。首次 callback 插入 account；后续 callback 更新可选 display label
并返回现有 account。不要用 email、GitHub login、avatar URL 或 OAuth scopes 作主键。

最小 GitHub scope 只需证明 identity，不申请 repository 权限。GitHub access token 在 callback 内完成
identity lookup 后丢弃；D1、browser、QuotaBar、QuotaCLI、日志和错误均不得接触 token。

### 3.2 Installation identity

首次运行生成 RFC 4122 random UUID 或等价 128-bit 随机值：

```json
{
  "schema_version": 1,
  "installation_id": "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998"
}
```

规则：

- 这是用户级、非同步、非硬件 ID；禁止读取 serial number、MAC、IP、主机名或 provider token 派生。
- POSIX state directory `0700`、file `0600`、no-follow read、same-directory atomic replace。
- 路径位于 app/npm 安装目录之外，例如
  `$XDG_CONFIG_HOME/quotacli/identity.json` 或 `~/.config/quotacli/identity.json`。
- 只有 QuotaCLI 可以读写 identity store。QuotaBar 需要本机 `device_id` 时调用 bundled CLI 的
  结构化 status/summary 命令，不在 Swift、UserDefaults 或 Keychain 中实现第二份 identity。
- 普通 app/package 重装保留该文件；显式 Delete All Local Quota Data 才删除它。
- 服务端只持有 keyed hash，不把 installation identity 作为公开 device ID。

若普通重装后 shared `session.json` 仍有效，客户端保持登录；若 session 已被清除、过期或 Web 撤销，
用户重新登录 Quota account 后仍通过保留的 installation identity 恢复原 device ID。

服务端 upsert key：

```text
installation_id_hash = HMAC-SHA-256(
  INSTALLATION_KEY,
  "account:" + account_id + ":installation:" + installation_id
)
(account_id, installation_id_hash)
```

同一 installation 登录同一 account 恢复原 device；登录不同 account 创建另一条 account-scoped
device，旧账号数据不移动。为避免把旧账号期间的本地历史自动复制到新账号，account switch 默认以
新登录时间作为 upload lower bound；更早历史只由未来显式 import 处理。不同 OS 用户生成不同
identity。彻底清除用户级 QuotaCLI 状态、OS wipe 或复制整个配置目录不属于“普通重装”；MVP 不用硬件
attestation 修补这些场景。

### 3.3 Server device identity

首次 device upsert 生成不可预测 `device_id`。后续同一 account + installation hash 总是返回该 ID。
服务端是 `device_id` source of truth，登录响应同时返回：

```text
device_id
device_generation
next_snapshot_sequence
usage_deleted_before
usage_sync_revision
```

客户端不得因本地 sequence 丢失而自行从 0 开始。显示名、platform、app version 可在每次登录更新，
但不参与 identity。

## 4. 登录协议

GitHub 只看到 `quota.gotry.io` 的 confidential web client。QuotaCLI 是 Quota authorization
service 的 public client；它登录的是 Quota account，由账号系统通过 GitHub 这一个 IdP 完成身份
验证。QuotaCLI 不嵌入 GitHub secret，也不接收 GitHub token。QuotaBar 不是 OAuth client。

### 4.1 Web：GitHub Authorization Code

1. `GET /api/auth/v2/github/login?return_to=/app` 生成随机 state、保存短期 login transaction。
2. Worker redirect 到 GitHub authorization endpoint。
3. GitHub callback 校验 exact state/redirect，服务端交换 code 并重新读取 current user identity。
4. `AccountState.upsertGitHubAccount()` 在事务中返回 account。
5. Worker 签发 Quota Web session cookie，删除 login transaction 与 GitHub token。

只有一个 **Continue with GitHub** 入口；`upsert` 结果不改变 UI 路径。

### 4.2 QuotaCLI：browser + loopback PKCE

参考 native app browser login：

1. 客户端若已有 active device session，则恢复该登录而不是开始第二个 account；切换 account 必须先
   logout。随后创建 `code_verifier`/S256 challenge、random state 和 loopback listener。
2. 打开 `GET /oauth/v2/authorize`，参数只包含 public `client_id`、exact loopback `redirect_uri`、state、
   challenge；installation identity 在 token exchange 的 HTTPS body 中发送，不放 URL。
3. Quota authorization endpoint 复用 Web 的 Quota account login，并通过 GitHub IdP 验证身份；
   callback 成功后把一次性 Quota code 绑定到
   account、client、redirect URI 和 challenge。
4. Browser redirect 到 loopback callback。客户端校验 state，以 code + verifier + installation metadata
   调用 `POST /oauth/v2/token`。
5. 单个事务消费 code、upsert device，并为 QuotaCLI 分别 rotate account session 和 device
   session。
6. 客户端关闭 listener，打开登录完成状态；失败、取消或过期不留下 device/session。

Loopback listener 只绑定 loopback interface、随机 high port，验证 state，并在一次 callback 后关闭。
拒绝非 allowlisted redirect、plain PKCE 和 credential-bearing redirects。

QuotaBar 点击登录时直接启动签名 bundled `quotacli login --format json`。Loopback listener、
PKCE、browser launch、token exchange 与 session 落盘全部在 QuotaCLI 进程中完成；QuotaBar 只获得
不含 token 的成功、取消或失败结果。

### 4.3 Headless CLI：Device Authorization Grant

`quotacli login --device-auth` 使用 Quota 自己的 device authorization endpoint：

1. CLI 拒绝在 active device session 上覆盖登录；account switch 必须先 logout。随后
   `POST /oauth/v2/device/code`，通过 HTTPS 提交 public client ID、随机 installation identity 和
   display metadata；HMAC 只在服务端计算，scope 由 server 对该 client ID 固定为 account-read +
   current-device-write 两类分离凭证。
2. Server 返回 secret `device_code`、human `user_code`、`verification_uri`、expiry、poll interval。
3. CLI 打印并尝试打开 Quota verification URL；用户可在另一台设备的浏览器打开。
4. Browser 先登录 Quota account（账号系统通过 GitHub IdP 验证），再显示“登录此
   QuotaCLI”确认页。它不选择 owner/QuotaBar，也不把
   device 加入某台 Bar。
5. CLI 按 interval 调用 `POST /oauth/v2/token`；pending/slow_down/denied/expired 遵守 RFC 8628。
6. 成功 consume 与 device upsert/session issuance 原子完成；CLI 收到 Quota account 和 device
   credentials，永不收到 GitHub credential。

旧 pairing session、Pair Device UI 和 owner approval 全部删除。虽然 device grant 也使用 code/poll，
其授权主体是 Quota account，GitHub 只是账号系统使用的 IdP；产品语义是 login，不是
设备间配对。

### 4.4 为什么保留两种 native flow

Browser + loopback 是正常桌面体验；Device Authorization 是没有本地浏览器/callback 的 CLI 必需
fallback。两者只复用一个 `LoginGrant` state machine 和同一个 completion transaction，不实现两套
account/device issuance 逻辑。

## 5. Session 与 token

### 5.1 Token classes

使用 server-generated opaque random bearer，不需要 JWT、自建 signing key rotation 或 token
introspection protocol。D1 只存 keyed hash。

| Token class | Scope | 建议生命周期 |
| --- | --- | --- |
| Web account access | `account:read account:manage` | 15 分钟 |
| CLI account access | `account:read session:revoke:self` | 15 分钟 |
| Account refresh | 按 client audience rotate account access；撤销当前 session | 90 天 inactivity，成功使用后 rotation |
| Device access | `quota:write:self usage:write:self sync:read:self session:revoke:self` | 15 分钟 |
| Device refresh | rotate device access；只绑定一个 device/generation | 90 天 inactivity，成功使用后 rotation |
| Login code/device code | 单次完成登录 | 10 分钟以内 |

Access/refresh 分离让离线 logout 最多暴露一个短 access TTL；refresh rotation 用 session row 的
compare-and-swap 保证旧 refresh token 在成功轮换后失效。具体 TTL 可在安全 review 中缩短，但不得
改变 scope 隔离。

### 5.2 Client storage

- Web：HttpOnly、Secure、SameSite cookie；不放 localStorage。
- QuotaCLI auth：`~/.config/quotacli/session.json` 或 XDG equivalent，目录 `0700`、文件
  `0600`。由 QuotaCLI 独占读写，内含分离的 account/device refresh sessions，以及 opaque
  `account_id`、`device_id` 和 generation，供 CLI 加载时校验两类 session 属于同一账号。
- QuotaBar 只可在 UserDefaults 保存视图偏好和不含凭证的 last-known CLI 输出；不得在
  Keychain、UserDefaults 或自有文件中保存 Quota sessions。
- Access token 可仅驻内存；refresh token plaintext 不进入日志、argv、environment、helper stdout 或
  crash report。
- Local `identity.json` 与 `session.json` 分离。Logout 删除 session，不删除 installation identity、
  sequence 或 Usage cache。
- 每个 CLI-owned state 显式带 schema version。当独立安装的旧 CLI 读到更新且不支持的 schema
  时，必须在写入前拒绝并返回 typed `client_upgrade_required`，不得降级或重写状态。

### 5.3 Logout state machine

```text
active
  |
  | user logout: atomically disable uploader
  v
logout_pending -- revoke succeeds / token expires --> signed_out
```

`logout_pending` 中只允许向 fixed revoke endpoint 发送 credential；禁止 quota/Usage collection result
upload。在线 revoke 后删除 local token；离线时下次 app/command startup 先重试 revoke，业务同步仍
关闭。

Server revoke：

- 撤销 QuotaCLI 本机 account session；
- 撤销该 device 的当前 device token family；
- 设置 `devices.signed_out_at`；
- 保留 device、quota snapshots、Usage、generation 与 account link。

再次登录同一 account 清除 `signed_out_at`、rotate 新 token family、返回同一 `device_id`。

### 5.4 QuotaBar 是 QuotaCLI 的 UI 层

macOS distribution 已由 QuotaBar bundle 提供签名 `quotacli` helper，并对用户暴露同一实现的 CLI。
最终规则：

- QuotaCLI 负责完整功能：Quota OAuth、account/device sessions、identity、account query、
  provider collection、sync、cache/outbox 和 logout。
- QuotaBar 只负责 UI、命令调度、输出解码和非敏感视图 cache。它不直接访问 Quota API，
  不读 `identity.json`/`session.json`/`usage-v1` 目录，也不以文件是否存在推断登录状态。
- Bar 在启动和每五分钟调用 fixed bundled `quotacli sync --format json`；CLI 自行判断
  active/signed-out/deleted 状态并返回 typed outcome，不需要 Bar 先检查 credential 文件。
- Bar 的 login/logout/status/account views 分别调用对应 CLI 命令。标准输出不得包含 token、
  installation ID、provider credential 或原始日志。
- collection/sync 继续使用 60 秒/1 MiB 边界；交互式 login 使用 OAuth grant expiry 作为上限，
  并支持 Bar 取消子进程。两者不共用 60 秒 timeout。
- 只有 bundled/standalone QuotaCLI 进程可能并发访问用户级状态，因此 filesystem lock 保护的是
  CLI 进程间竞争，不是 QuotaBar 与 helper 之间的“共享读取”。
- `session.json` 中 account/device principal 的 `account_id` 不一致时，CLI fail closed、停止上传并
  要求重新登录；Bar 只显示该错误 outcome。

## 6. Device lifecycle 与删除

### 6.1 Status

| 状态 | Server row | 可上传 | Account UI | 业务数据 |
| --- | --- | --- | --- | --- |
| active | 正常 device | 是 | 显示 | 保留 |
| offline | `last_seen_at` 较旧的派生状态 | session 有效时可 | 显示 | 保留 |
| signed_out | `signed_out_at` 非空、sessions revoked | 否 | 显示“已退出” | 保留 |
| deleted | `deleted_at` tombstone、generation advanced | 否 | 隐藏 | 删除 |

不再因 30 天 inactivity 自动删除 account device/history。Session 可以过期，业务数据只能由用户明确
删除。

### 6.2 Delete Device transaction

`AccountState.deleteDeviceData(account_id, device_id, deleted_at)` 必须原子完成：

1. 验证 device 直接属于 account；
2. revoke 全部 account/device grant 与 device token families；
3. increment `generation` 并设置 precise `deleted_before`；
4. delete quota snapshots、Usage hourly facts、coverage/ack state；
5. 清除 display/platform/last-seen 等非必要 metadata，保留最小 hidden tombstone：account、installation
   hash、stable device ID、generation、watermark、deleted_at；
6. commit 后所有旧 token/outbox 返回 terminal stale/deleted outcome。

如果同一 installation 再次主动登录，completion transaction reactivates tombstone，保留 device ID、
再次推进/使用新 generation，并只接受 deletion watermark 之后的活动。当前 quota snapshot 可由新
collection 写回；删除前 Usage 不可由 full-log rescan 恢复。

### 6.3 Delete Account

Recent-auth account session 才能执行。事务撤销全部 sessions/grants，并级联 devices、tombstones、
quota、Usage 与 account row。安全 rate-limit counters 按自身短期 expiry 清理，不因账号删除提前
清空。完成后同一 GitHub identity 再登录将创建一个
全新 account；本地旧 device state 必须因 account/generation mismatch fail closed。

## 7. Runtime-neutral records 与 D1 schema

### 7.1 Domain records

`packages/relay-core` 定义 JSON-safe records/outcomes，不暴露 SQL：

```ts
interface AccountRecord {
  id: string;
  github_subject_hash: string;
  created_at: string;
}

interface DeviceRecord {
  id: string;
  account_id: string;
  display_name: string;
  platform: string;
  generation: number;
  created_at: string;
  last_login_at: string;
  last_seen_at: string | null;
  signed_out_at: string | null;
  deleted_at: string | null;
  deleted_before: string | null;
}
```

建议 contract 只包含实际 use cases：

```text
upsertAccountByGitHubSubject
create/consume/cancelLoginGrant
upsertAccountDevice
authorizeAccountSession / authorizeDeviceSession
refreshSession / revokeSession
listAccountDevices
markDeviceSignedOut
deleteDeviceData
deleteAccountData
```

不要先建 generic CRUD repository、event bus、RBAC engine、identity-provider interface 或多数据库
factory。GitHub-only 与 D1-only 是明确目标，不是暂时缺少 adapter。

### 7.2 D1 tables

最终 schema 可采用以下最小关系：

```sql
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  github_subject_hash TEXT NOT NULL UNIQUE,
  display_label TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE account_sessions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  client_kind TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  installation_id_hash TEXT NOT NULL,
  display_name TEXT,
  platform TEXT,
  generation INTEGER NOT NULL DEFAULT 1 CHECK (generation > 0),
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  created_at TEXT NOT NULL,
  last_login_at TEXT NOT NULL,
  last_seen_at TEXT,
  signed_out_at TEXT,
  deleted_at TEXT,
  deleted_before TEXT,
  UNIQUE (account_id, installation_id_hash)
);

CREATE TABLE device_sessions (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_generation INTEGER NOT NULL,
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE login_grants (
  id TEXT PRIMARY KEY,
  grant_kind TEXT NOT NULL,
  client_id TEXT NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  code_hash TEXT UNIQUE,
  user_code_hash TEXT UNIQUE,
  installation_id_hash TEXT,
  device_display_name TEXT,
  platform TEXT,
  pkce_challenge TEXT,
  redirect_uri TEXT,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  consumed_at TEXT,
  denied_at TEXT,
  created_at TEXT NOT NULL
);
```

Add only measured access-path indexes: account sessions by account, device sessions by device,
visible devices by account, and login/session expiry for cleanup. Token and identity uniqueness
already creates the corresponding lookup indexes.

Quota snapshots/Usage tables继续 FK `devices(id)`。Deleted tombstone 仍在 `devices`，所以 Delete Device
不能依赖 `ON DELETE CASCADE`；`D1AccountState.deleteDeviceData()` 用 D1 transactional batch 删除 child
rows 并更新 tombstone。Domain 只看到一个原子 outcome，不看到 SQL batch。

### 7.3 Greenfield schema replacement

- 新显式 migration 删除 owner/pairing/self-hosted-era tables 并创建 final account schema；不复制旧
  rows。
- 如果 managed D1 尚无正式数据，可在受控部署前 reset database，再从空 schema 应用 migrations。
- 不修改已经提交/应用的 migration 文件；也不添加 legacy aliases、dual read/write 或 background
  conversion jobs。
- Account 与 Usage 分支在合并前分配唯一 migration 序号，或合并成一个 reviewed destructive
  cutover migration。

## 8. HTTP API

下面是 final v2 surface；旧 `/api/v1/owners`、pairings、owner reads 和 self-delete routes 全部移除。

### 8.1 Auth

| Method | Path | Principal | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/auth/v2/github/login` | anonymous | Web create-or-login |
| `GET` | `/api/auth/v2/github/callback` | login state | 完成 GitHub identity proof |
| `POST` | `/api/auth/v2/logout` | Web account | 撤销当前 Web session |
| `GET` | `/oauth/v2/authorize` | native public client | Browser + PKCE 登录开始 |
| `POST` | `/oauth/v2/device/code` | CLI public client | Headless device grant 开始 |
| `POST` | `/oauth/v2/token` | one-time code/device code/refresh | Consume 或 rotate Quota tokens |
| `POST` | `/oauth/v2/revoke` | account/device session | 撤销当前 token family |

### 8.2 Account/device/data

| Method | Path | Principal | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v2/account` | Web/CLI `account:read` | 当前 account metadata |
| `GET` | `/api/v2/account/sessions` | Web `account:manage` | 列出 Web/CLI sessions |
| `DELETE` | `/api/v2/account/sessions/:id` | Web `account:manage` | 撤销指定 account session |
| `GET` | `/api/v2/account/devices` | Web/CLI `account:read` | 列出 active/signed-out devices |
| `GET` | `/api/v2/account/snapshots` | Web/CLI `account:read` | 读取所有 device latest quota |
| `DELETE` | `/api/v2/account/devices/:device_id` | recent-auth Web `account:manage` | Delete Device transaction |
| `DELETE` | `/api/v2/account` | recent-auth Web `account:manage` | Delete Account |
| `GET` | `/api/v2/pricing/catalog` | public | 当前/历史价格目录，支持 revision 与 ETag |
| `GET` | `/api/v2/device/sync` | device | generation、sequence、watermark |
| `POST` | `/api/v2/device/logout` | device | 注销自身 session，保留数据 |
| `PUT` | `/api/v2/device/snapshots` | device | write-self quota envelope |
| `PUT` | `/api/v2/device/usage` | device | write-self Usage coverage |

Usage range/summary routes由 [`usage-analytics.md`](./usage-analytics.md) 定义，但 read principal 只能是
account。所有 credential routes 响应 `Cache-Control: no-store`，拒绝 redirect，限制 body/range/result
大小。

### 8.3 Managed endpoint

客户端内置 canonical origin，不再需要 Relay URL 或 instance discovery。可保留无凭证
`GET /api/v2/info` 用于版本/健康检查，但它不是 enrollment/discovery，也不能让客户端切换 endpoint。

## 9. 客户端改造

### 9.1 QuotaCLI

删除：

- `relay pair [--relay]`、`relay unpair`、URL discovery/instance binding；
- current pairing client/store/state machine；
- owner/self-hosted terminology与帮助文本。

新增/替换：

```text
quotacli login [--device-auth]
quotacli logout
quotacli auth status
quotacli sync          # quota + bounded Usage outbox drain
quotacli account summary [--from <date> --to <date>] [--cost-mode calculate|auto|reported]
quotacli account devices
```

`status`/local Usage 无登录仍工作；`sync` 在无 device session 时安全跳过并返回明确 auth outcome。
Account 命令使用 account session 读取跨设备结果。上述命令均需有稳定、严格的 `--format json`
输出供 QuotaBar 消费。QuotaCLI 通过 ETag 获取并校验价格目录，原子缓存最后一个有效 revision；从未
获取目录时成本状态为 unpriced，不能回退到内置价格。非 macOS recurring sync 仍由用户 scheduler
驱动，不新增 daemon。

### 9.2 QuotaBar

- Settings 顶部只有 **Continue with GitHub** / account / logout，不再有 Relay URL、Remote Devices owner
  profile 或 Pair Device。这些按钮只启动 bundled CLI 命令。
- 登录后 Overview/Devices 显示 `quotacli account ... --format json` 返回的本机与其他 devices。
- Usage 金额、coverage、basis 和 pricing catalog revision 全部来自 CLI 的 typed summary；默认
  `calculate` 使用远端官方目录，QuotaBar 只
  格式化 USD，不维护价格表或重新计算。
- app launch + 每五分钟始终调用 signed bundled helper `sync --format json`；是否已登录由 CLI
  判定并以 typed outcome 返回，Bar 不探测 credential 文件。
- QuotaBar 不保存 account/device token、installation identity 或 sync state。
- logout、device signed-out、token expired、Web deleted 是不同 UI state；Web delete导致本机 fail
  closed 并提示重新登录。

### 9.3 Web

- 单一 **Continue with GitHub**。
- Dashboard：account token/cost total、device breakdown、cost coverage、last seen、signed-out status、
  Delete Device；Web 使用 Relay 已计算 summary，不维护第二份价格表。
- `/activate`：CLI device authorization 登录确认；如果未登录，先通过 GitHub IdP 完成 Quota
  account login，再回到同一 grant。
- Account settings：sessions、export（若实现）、Delete Account。
- Browser login 本身不创建 device，也不展示 Pair Device owner/code 语义。

### 9.4 Relay/runtime removal

- 删除 `apps/relay/src/self-hosted.ts`、SQLite state/tests、Bun server、Compose/container 和 self-hosted
  scripts/workflows。
- 删除 QuotaBar endpoint profile/owner credential store/UI/tests。
- 删除 protocol discovery mode/self-hosted capability 与 owner/pairing schemas；同步 JSON Schema 与 Swift
  decoding。
- Managed Worker/D1 与 Web static assets 仍由现有 Cloudflare deployment boundary 发布。

## 10. 安全要求

- OAuth state、PKCE S256、exact redirect、single-use code、short expiry、poll interval 与 rate limits
  必须有 negative tests。
- Login code、user/device code、access/refresh token、GitHub subject 与 installation identity 在存储中只
  保存 keyed hash；plaintext 只在必要响应中出现一次。
- GitHub subject key、GitHub OAuth secret 和 credential hashing keys 只用 Worker secrets 配置并支持
  独立 rotation。
- Token scopes/audience 分离；device principal 即使猜中其他 ID 也只能写自身，account principal 只能
  访问 `principal.account_id` 下的 devices。
- Cross-account lookup 使用 generic not-found；授权与删除不泄漏其他 account/device 是否存在。
- Display name、platform、GitHub label 经过长度/字符清理；日志采用 allowlist，不记录 request body、
  Authorization、Cookie、OAuth code 或原始 error body。
- Delete Device/Delete Account 需要 recent authentication、CSRF 防护和 explicit confirmation。
- Local state 拒绝 symlink、宽权限和非 regular files；写入用 lock + atomic replace。
- Provider credentials 与 agent logs 继续只在 QuotaCLI process boundary 内，账号登录不得扩大其网络
  目的地或读取权限。

## 11. 实施任务

| ID | Work package | 主要内容 | Exit |
| --- | --- | --- | --- |
| A0 | Contract/ADR | 冻结 direct account-device、OAuth flows、session/lifecycle、greenfield removal | 产品/安全 review 通过 |
| A1 | Domain state | runtime-neutral records、AccountState、synthetic contract tests | 无 D1 type 泄漏 |
| A2 | D1 schema | destructive migration、D1AccountState、transaction/constraint tests | 空库 final schema 与 rollback cases 通过 |
| A3 | GitHub/Web auth | create-or-login、Web cookie、session management、token redaction | synthetic + GitHub sandbox E2E 通过 |
| A4 | Native OAuth | browser PKCE、device grant、shared completion/token rotation | success/cancel/expire/replay/slow-down 通过 |
| A5 | Device identity | identity/session stores、upsert、sequence recovery、same-Mac shared lock | reinstall 与 concurrent client tests 通过 |
| A6 | Client UX | CLI 完整 login/logout/sync/account JSON；QuotaBar 纯 UI；Web activate/devices | 无 Pair Device/Relay URL surface |
| A7 | Lifecycle | logout pending、signed-out、Delete Device tombstone/generation、Delete Account | stale outbox 不能复活数据 |
| A8 | Removal | owner/pairing/self-hosted/SQLite/discovery/code/docs deletion | search/build/E2E 无旧 runtime path |
| A9 | Integration | Account + quota + Usage token/cost + Web/Bar E2E 与 canonical docs | managed-only release gates 通过 |

A1/A2/A3 可与 Usage parser/cache/protocol 开发并行；A4/A5 冻结 token/device contract 后，Usage 可用
synthetic device session完成写入。A7 是两条流的汇合点。

## 12. 验证

### 12.1 Account/auth

- 同一 GitHub ID 并发首次 callback 只产生一个 account；不同 ID 不能互读。
- Web 首次/后续 login 的可见流程相同；GitHub token 不出现在 DB/log/fixture/client。
- PKCE wrong verifier、state mismatch、redirect mismatch、expired/replayed code、poll too fast、denied
  device grant 全部 fail closed。
- Refresh compare-and-swap rotation 与 account/device token scopes 互不接受。

### 12.2 Device identity/session

- 同 account + installation 的重复/并发 login 只有一个 device ID；token family安全 rotate。
- 普通 reinstall 后 identity file仍在，server 返回同一 ID/next sequence/history。
- 登录另一 account 不转移旧 data；回到原 account 恢复原 device。
- 同 Mac 的 bundled/standalone CLI concurrent sync 由共享 lock 保证单 uploader state；QuotaBar 从不读取
  该 state。
- 旧 standalone CLI 读到 bundled CLI 写入的更新 state schema 时在任何修改前返回
  `client_upgrade_required`，原文件保持不变。
- 直接执行 `quotacli logout` 或点击 QuotaBar logout 均撤销同一组 account/device sessions，Bar
  立即显示 signed-out。
- Offline logout immediately disables upload；仅 revoke retry 可使用 pending credential。

### 12.3 Data/lifecycle

- Signed-out device仍出现在 account view且历史可读；device token不能写。
- 同一 account/date/device filter/cost mode 下 Relay、QuotaCLI、QuotaBar 与 Web 的 Usage token/cost
  summary 一致；UI 均显示相同 coverage、basis 与 catalog revision，未知模型不显示为 `$0`。
- Delete Device 同事务清除 quota/Usage、revoke tokens、advance generation、hide device。
- 删除前 offline outbox、旧 access token、旧 refresh token、旧 parser replacement均不能恢复数据。
- 同 installation重新登录复用 stable ID，以新 generation空历史开始；post-watermark activity可写。
- Delete Account 后所有 sessions/data/tombstones清空；同 GitHub ID下一次登录得到新 account。

### 12.4 Removal/cross-cutting

- Protocol/model/Relay/Swift tests 不引用 owners、pairing、self-hosted mode或 Relay URL enrollment。
- 不生成 self-hosted executable/image、SQLite state或 Compose artifact。
- Root `format:check`、`check`、`test`、`build`、Cloudflare dry-run、D1 migration和 macOS真实 App +
  bundled helper E2E通过。

## 13. 发布与回滚

这是一次 greenfield breaking replacement，不做迁移期：

1. 在分支内先完成 final schema、clients、managed Worker/Web 与 tests；旧产品入口不与新入口混合发布。
2. 对非正式 managed D1 执行受控 reset 或 destructive migration；部署前导出仅用于调试，不承诺导入。
3. 一次 cutover 只发布 v2 routes/clients；同时删除 v1 owner/pairing/self-hosted routes 与 artifacts。
4. 合入前更新 canonical docs/ADR/status。未通过 macOS E2E 与 stale-outbox delete gate 不发布。

代码可以在 cutover 前回滚；一旦新 account/device 数据开始产生，禁止回滚到会忽略 account 或把旧
owner capability重新开放的版本。紧急回滚应保留最小 account/device auth + read service，暂停写入，
而不是恢复旧 pairing。

## 14. 非目标

- 其他 identity provider、email/password、magic link、teams/org/RBAC、account merge/linking。
- Self-hosted Relay、private Relay URL、operator account、SQLite parity、跨 deployment federation。
- 硬件 fingerprint、device attestation、MDM identity、跨 OS wipe 自动恢复。
- 为 Web browser 创建 device，或让 QuotaBar 成为独立 account/device principal。
- 同步 provider credentials、provider sessions、API keys、本地 agent logs、prompt 或 completion。
- 新 daemon、WebSocket、event bus、microservice、R2 history 或通用 OAuth provider framework。
- 旧 owner/device/data/token migration、claim、compat shim、dual route/read/write。

## 15. 合理性 review

### 15.1 可以满足的预期

- Web 的首次/后续 Quota account login 完全统一，GitHub 仅是身份验证方式。
- QuotaCLI 登录即 device upsert；QuotaBar 只调起该流程，无 QuotaBar-to-CLI pairing。
- Logout 停上传且远端保留；Web delete 才删数据。
- 同 account 多 device聚合与任意 Bar恢复视图直接成立，不再依赖 owner合并。
- 普通 app/package重装在 local identity保留时恢复同一 device。
- Account 领域不绑定 D1；D1只实现 state contract。

### 15.2 主要问题及控制

| 问题 | 后果 | 设计控制 |
| --- | --- | --- |
| 把 logout叫“解绑” | 与 Web 仍显示设备矛盾 | UI定义为停止同步/退出；server account-device link保留 |
| installation file也被删除 | 无法识别旧机器 | 明确只保证普通重装；不用硬件 ID；旧远端 device由 Web删除 |
| Bar 直接读 CLI 状态或调 account API | 双客户端、状态漂移与重复设备 | Bar 只调签名 CLI 并消费无敏感 JSON |
| CLI 同时持有 account/device token | collector 路径可能误用账号权限 | token audience/scope 分离；`sync` 只接受 device principal |
| Bundled 与 standalone CLI 版本不同 | 旧进程破坏新 state | versioned schema；unknown newer version 在写入前 fail closed |
| Web delete后 full scan重传旧历史 | 用户删除失效 | hidden tombstone + generation + precise watermark |
| offline logout无法即时通知 server | stolen token短暂有效 | local先停传、logout_pending retry、short access TTL、refresh revoke |
| config/home被克隆 | 两台机器争用同一 device | sequence conflict fail closed；显式 Reset Identity，不加 attestation |
| 退出期间 history后来 backfill | 用户可能误解隐私语义 | 产品明确说明；若要永久排除，另设 exclusion/delete，不复用 logout |
| 自建 OAuth边界有实现风险 | account takeover | 标准 flows、成熟协议库、安全 review、完整 negative tests |

### 15.3 已冻结的补传语义

已确认“重新登录后补传退出期间仍存在的本地 Usage”。Logout 保证退出期间不上传，但不创建永久
排除区间；若未来需要永久排除某段历史，应新增显式删除/排除操作，而不是改变 session logout 语义。

## 16. 参考实现与标准

- GitHub 官方 OAuth 文档同时区分 browser web flow 与 headless device flow，并要求每次登录后重新
  验证当前 user identity：
  [Authorizing OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- OAuth native app browser/loopback/PKCE：
  [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252)
- OAuth Device Authorization Grant：
  [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628)
- Codex 官方 app-server 公开了 browser callback login、device-code login、completion notification 与
  logout 的并列状态机，可借鉴交互而不复制其 token/账号模型：
  [openai/codex app-server authentication](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#auth-endpoints)
