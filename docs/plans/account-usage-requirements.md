# Quota Account 与 Usage 产品需求及并行交付边界

- Status: proposed
- Canonical: no
- Updated: 2026-08-09
- Baseline: `f6e9047187f81519ad4b9008e53ef22b3eb93f5f`

> 本文描述全新账号版产品，不替代当前 canonical 文档。实现时必须同步更新
> [`README.md`](../../README.md)、[`architecture.md`](../architecture.md)、
> [`security.md`](../security.md) 和被取代的 ADR。账号技术设计见
> [`account-system.md`](./account-system.md)，Usage 实现见
> [`usage-analytics.md`](./usage-analytics.md)。

## 1. 已冻结的产品结论

Quota 不迁移现有匿名 owner、配对关系、self-hosted 数据或凭证。账号版作为全新产品边界实现：

```text
GitHub identity 1 ── 1 Quota account 1 ── N devices
                                      device 1 ── N quota snapshots
                                      device 1 ── N sparse hourly Usage facts
```

1. Quota 账号系统只支持 GitHub 这一个外部身份提供方。登录时不存在账号就创建，存在就
   恢复；界面和 API 不区分“注册”与“登录”。
2. Quota Web 登录只建立 account session，不注册浏览器为 device。
3. QuotaCLI 是 native 端的完整客户端，负责 Quota 账号登录、device 绑定、账号读取、采集、上传与
   退出。QuotaBar 只是 bundled QuotaCLI 的 UI 与调度层。登录成功即创建或恢复本机
   device；产品中不再有 Pair Device、owner、Relay URL 或 self-hosted 概念。
4. 退出登录立即停止本机上传并撤销本机 session，但保留服务器上的 account-device 关系及全部远端
   数据。Web 仍显示该设备为“已退出”或“离线”。因此准确术语是“停用设备会话”，不是“解除服务器
   归属”。
5. 只有 Web 的 Delete Device 才删除该设备的 quota/Usage 数据、撤销全部设备凭证并从设备列表隐藏。
6. 每个 OS 用户安装生成一个随机、非硬件 `installation_id`。同一 account 再次登录同一
   `installation_id` 时恢复同一个服务端 `device_id`。
7. Bundled/standalone QuotaCLI 是 installation identity、account/device credentials、sequence、
   Usage cache 和 outbox 的唯一读写者。QuotaBar 不直接读文件或凭证，只调用 bundled CLI 并
   解码无敏感信息的结构化输出。
8. Relay 在账号授权后按 `devices.account_id` 查询并聚合账号下所有 devices、quota 和 Usage；Web 与
   QuotaCLI 读取同一份 normalized account summary，QuotaBar 只渲染 CLI 返回结果。客户端不下载全部
   Usage storage rows 后自行计算，以此完全替代当前 QuotaBar 私有 owner 下的“配对设备”视图。
9. Account 是 runtime-neutral 领域模型；D1 只是 managed deployment 的当前持久化 adapter。领域
   service、协议和 Usage 代码不得以 `D1Database` 或 SQL row 表示 Account。
10. 远程产品只支持 `quota.gotry.io`。删除 self-hosted Relay、SQLite Relay runtime、动态 Relay
    discovery、任意 URL enrollment、anonymous owner 与旧 pairing 路径，不保留兼容层。
11. Usage 必须显示 USD API-equivalent cost。客户端上传可重算的 billing facts 和日志可能自带的
    source-reported cost；QuotaRelay 维护唯一的版本化、带生效时间与渠道维度的价格目录。QuotaCLI
    获取并缓存该目录，本地与远端通过同一计算库得到一致结果，不把订阅内用量误称为实际账单。

## 2. 产品目标与成功信号

### 2.1 目标

- 用户在 Web 或 QuotaCLI（包括通过 QuotaBar 调起 bundled CLI）完成一次 Quota 账号登录，
  账号系统通过 GitHub 验证身份。
- 多台设备的 quota 和 Usage 长期存放在 managed Relay，并可按 account 汇总、按 device 下钻。
- 更换或重装 QuotaBar/QuotaCLI 后，只要本地用户级 Quota 状态仍在，就恢复原 device，而不是新增一台
  重名设备。
- QuotaBar 触发 bundled CLI 登录后自动展示 CLI 同步的其他设备；不存在 CLI 与某一台
  QuotaBar 的服务端关系。
- 本地 provider credentials、prompt、completion、工具参数、文件路径和原始日志永远不上传。
- 未登录或离线时，本地 quota/Usage collection 继续工作；网络同步仅在设备已登录时运行。

### 2.2 成功信号

- 同一 GitHub identity 连续两次 Web 登录得到同一 `account_id`，不存在独立 signup 分支。
- 四个不同 OS-user installations（其中两个由 QuotaBar 调起 bundled CLI）登录同一 account
  后，Web 与两台 Bar 都看到四台设备和一致的账号汇总。
- 正常卸载并重装客户端后，登录同一 account 得到原 `device_id`，历史不重复。
- 退出本机后不再产生网络上传；远端设备和历史仍可读。Web 删除后设备消失、历史清空、旧 token 与
  stale outbox 均不能恢复数据。
- 同一 macOS 用户同时运行 QuotaBar 和 `quotacli` 不会创建两台 device，也不会对同一日志重复计数。
- 同一账号、日期范围和 cost mode 在 Web、QuotaCLI 与 QuotaBar 显示相同 USD 成本；未知模型不会被
  当成零成本，价格目录更新可以重算历史而无需修改 Usage rows。

## 3. 术语与身份边界

| 术语 | 定义 | 不是 |
| --- | --- | --- |
| **Quota account** | GitHub identity 对应的可恢复 Quota 用户；拥有 devices 与 account sessions | Provider 账号；D1 row；owner capability |
| **Installation identity** | 客户端首次运行生成并保存在用户级状态目录的随机 ID | 硬件序列号、MAC 地址、主机名或可跨 OS 恢复身份 |
| **Device** | 某 account 下一个 installation identity 的服务端记录与写入边界 | 一次 OAuth session；某个 provider account |
| **Account session** | Web/QuotaCLI 的账号级短期 access 与可撤销 refresh session；具体权限受 client audience 限制 | Usage 上传凭证；GitHub token；QuotaBar 状态 |
| **Device session** | 仅允许当前 device 上传 quota/Usage 和注销自身的 credential | 账号级读写权限 |
| **Login grant** | Native/CLI 登录时一次性、短期的 OAuth authorization transaction | 旧 Relay pairing session |
| **Usage** | 从本地 agent 日志计算的 token 与 billing-fact sparse hourly aggregates | 剩余额度、实际订阅账单、prompt 内容或原始事件上传 |
| **API-equivalent cost** | 按公开 API 价格对本地 Usage 计算的 USD 等价值，带价格版本与 coverage | ChatGPT/Claude 订阅实际支出或 provider 发票 |
| **Deletion watermark** | Web 删除时阻止旧 outbox/本地历史重新出现的 server generation 与时间边界 | 用户可见历史数据 |

稳定约束：

- 一个 GitHub subject 只对应一个 account；不支持 account merge 或多个身份供应商。
- 一个 device 直接且只属于一个 account；没有 owner/link/canonical owner 中间层。
- `(account_id, installation_id_hash)` 唯一；同一个本地 installation 登录另一 Quota account 时创建该
  account 下的另一 device，不把旧账号历史转移过去。
- quota snapshot 与 Usage 的直接外键都是 `device_id`。账号读取通过 `devices.account_id` 授权；业务
  rows 不需要重复保存 `account_id`。

## 4. 用户流程

### 4.1 Web 登录

1. 用户点击 **Continue with GitHub**。
2. GitHub OAuth callback 返回 stable GitHub user ID。
3. 服务端在同一事务中按 GitHub subject 查找或创建 account。
4. 服务端设置 Quota Web HttpOnly session cookie，并进入同一个 dashboard。

产品不出现“注册账号”和“已有账号登录”两个入口；首次与后续登录只有内部 upsert 差异。

### 4.2 QuotaBar 中的登录

1. 用户在 QuotaBar 点击 **Continue with GitHub**，QuotaBar 启动签名的 bundled
   `quotacli login --format json`。
2. QuotaCLI 读取或创建 `installation_id`，建立 loopback callback，并用系统浏览器发起
   Quota OAuth Authorization Code + PKCE。
3. 浏览器在 `quota.gotry.io` 登录 Quota 账号；Quota 账号系统再使用 GitHub 这一个 IdP
   验证身份。GitHub token 只在服务端 callback 中短暂使用。
4. QuotaCLI 用一次性 code + verifier 换取 Quota account session 和本机 device session；
   服务端按 `(account_id, installation_id_hash)` 创建、恢复或重新激活 device。
5. QuotaCLI 原子保存两类 Quota session，执行首次 sync，再向 QuotaBar 输出不含 token 的
   登录与账号摘要。QuotaBar 不保存或读取任何账号/device credential。

### 4.3 QuotaCLI 登录

- 直接运行 `quotacli login` 与 QuotaBar 调起的是同一条 Authorization Code + PKCE 流程。
- 无浏览器/SSH 环境使用 `quotacli login --device-auth`：CLI 显示 Quota verification URL 与 user
  code，用户在任意浏览器登录 Quota 账号（账号系统通过 GitHub 验证），CLI 按 server
  interval polling。
- 两条流程最终调用同一个 account upsert + device upsert transaction。CLI 保留分离的 Quota
  account session 与 device session，但永不保留 GitHub token。
- OAuth Device Authorization Grant 虽然也有 user code 和 polling，但它是“登录当前账号”，不需要
  QuotaBar 批准，也没有 owner/device 配对关系。

### 4.4 退出登录

- QuotaBar 的 logout 按钮只是启动 bundled `quotacli logout`；直接运行 CLI 得到完全相同的
  行为。
- QuotaCLI 撤销本机 account session 和 device session，并立即停止上传。QuotaBar 没有可单独
  保留的登录状态。
- 本地先原子切换为 signed-out，再做 server revoke；即使离线，后续 collection 也不得使用该 token
  上传。未完成的 revoke 保存在 `logout_pending` 状态，只允许重试 revoke，不允许业务上传。
- 服务端保留 device row、quota/Usage 与 account 归属。再次登录同一 account 会恢复同一
  `device_id` 并签发全新 credential。

### 4.5 Web 删除设备

1. 用户在 Web 对账号内 device 执行 Delete Device 并确认。
2. 服务端在一个事务中撤销该 device 的所有 sessions、删除 quota snapshots 与 Usage rows、推进
   generation/deletion watermark，并把 device 变为隐藏 tombstone。
3. 在线客户端收到拒绝后切为 signed-out；离线旧 outbox 因 generation 不匹配不能恢复历史。
4. 若同一 installation 以后主动重新登录同一 account，服务端复用原 `device_id`、开启新 generation，
   设备以空历史重新出现。

保留最小 tombstone 是删除竞态控制，不是保留用户可见数据；Delete Account 必须连 tombstone 一并
删除。

### 4.6 重装与身份恢复

- `installation_id`、sequence、Usage cache/outbox 放在 app/npm 安装目录之外的用户级状态目录；正常
  app/package 卸载与重装不得删除它们。
- 服务端登录响应返回 authoritative `device_id`、generation、`next_snapshot_sequence` 和 Usage
  watermark；本地 sequence 丢失时不得从 0 猜测。
- 完整清除 Quota 用户状态、删除 OS 用户、抹盘或重装系统会生成新 installation/device。这是明确
  边界，不使用硬件指纹绕过。
- 不同 OS 用户是不同 devices。复制整个 home/config 会复制 installation identity，属于不支持的
  克隆场景；检测到并发 sequence 冲突时停止上传并要求 Reset Device Identity。

## 5. 功能需求

### 5.1 Account 与登录

- **ACC-01 MUST**：客户端登录对象是 Quota account；Quota 账号系统只支持 GitHub OAuth 作为
  外部身份验证，同一 callback 完成 create-or-login。
- **ACC-02 MUST**：GitHub stable user ID 是唯一身份输入。不得用用户名、邮箱、avatar URL 或 OAuth
  scope 作为主键。
- **ACC-03 MUST**：GitHub access token 不进入浏览器客户端、QuotaBar、QuotaCLI、D1、日志、fixture
  或诊断；服务端完成 identity lookup 后立即丢弃。
- **ACC-04 MUST**：Account 领域 contract 位于 runtime-neutral package；D1 实现在 managed adapter。
- **ACC-05 MUST**：Web 与 QuotaCLI 可同时拥有独立的 account sessions。Web 可查看和撤销账号的
  sessions；CLI 只能撤销当前本地 session。
- **ACC-06 MUST**：失去 GitHub account 访问权即无法恢复 Quota account。MVP 不提供密码、邮箱、
  magic link、第二 IdP、identity linking 或人工改库恢复。

### 5.2 Native/CLI OAuth

- **AUT-01 MUST**：QuotaCLI 的默认登录使用系统浏览器、Authorization Code、PKCE S256、精确
  redirect allowlist、单次 code、state 和短期过期；QuotaBar 只启动该 CLI 流程。
- **AUT-02 MUST**：CLI 提供标准 Device Authorization fallback；遵守 server `interval`、
  `slow_down`、single-use 与 expiry，不复用旧 pairing schema/UI。
- **AUT-03 MUST**：Native public clients 不包含 GitHub client secret，也不直接接收 GitHub token。
- **AUT-04 MUST**：登录 grant 成功消费与 device upsert/token issuance 是原子的；网络重试不能创建
  重复 device。
- **AUT-05 MUST**：QuotaCLI 获得分离的 account read/self-logout session 与 device write/self-logout
  session；QuotaBar 不是 principal，不获得任何 session。

### 5.3 Device identity 与生命周期

- **DEV-01 MUST**：客户端生成至少 128-bit 随机 `installation_id`；禁止硬件 ID、主机名、IP、provider
  identity 或 GitHub identity 参与生成。
- **DEV-02 MUST**：服务端只保存 account-scoped keyed hash，并用
  `(account_id, installation_id_hash)` 唯一约束完成幂等 upsert；数据库中的 hash 不得用于跨 account
  关联同一 installation。
- **DEV-03 MUST**：普通重装、退出后重新登录、account session 刷新都保持 `device_id`；Web Delete
  后重新登录也复用该 ID，但使用新 generation 和空历史。
- **DEV-04 MUST**：同一 macOS 用户下的 bundled/standalone QuotaCLI 进程使用同一 local state、
  sessions、lock 与 outbox。QuotaBar 只通过 bundled CLI 访问这些能力，不得直接读写。
- **DEV-05 MUST**：切换 account 前必须先 logout 当前 device。登录另一 account 不转移旧 device 或
  数据；新 account 的自动上传以切换登录时间为 lower bound，不复制此前本地历史；旧 account 仍
  看到已退出设备，直到其 Web 用户删除。
- **DEV-06 MUST**：设备展示名可更新且不参与身份；默认由经过清理的本地 device name/platform 生成。
- **DEV-07 MUST**：QuotaCLI 拥有的 identity/session/cache/outbox 均显式带 schema version。旧 CLI
  遇到更高且不认识的 version 必须在任何写入前 fail closed；QuotaBar 只显示升级提示。

### 5.4 上传、同步与读取

- **SYN-01 MUST**：device credential 只能写 envelope 中与自己相同的 `device_id`，不能读取账号历史
  或删除其他 devices。
- **SYN-02 MUST**：Relay 按已授权 account 在服务端聚合全部 devices、quota 和 Usage；Web 与
  QuotaCLI 的 account session 读取同一 normalized summary。Routine upload 只使用 device session，
  QuotaBar 只消费 CLI JSON 输出。Delete Device/Account 仍是 Web 中需要 recent authentication 的
  显式管理操作。
- **SYN-03 MUST**：未登录时 local collection/cache 继续，所有 network upload 停止。
- **SYN-04 MUST**：首次 account 登录可 backfill 本地可读历史；重新登录同一 account 恢复同步，
  并 backfill 退出期间仍保存在本地的 Usage。这意味着“退出”保证当时不传输，但不表示这些历史
  永远排除。切换到另一 account 则遵守 DEV-05 的 login-time lower bound。若产品需要永久排除某段
  历史，必须另增显式删除/排除操作，不能把它藏在 logout 中。
- **SYN-05 MUST**：完整权威 scan 才能 replacement；权限错误、timeout、未知 record 或 partial tail
  不得上传零值或 tombstone。
- **SYN-06 MUST**：同一 coverage 重试、乱序、parser correction 和 crash-after-commit 不重复计数。
- **SYN-07 MUST**：QuotaCLI 从账号 API 只下载 normalized quota/Usage，不下载原始日志、provider
  credentials 或其他设备的本地 cache；QuotaBar 只获得这些 normalized 结果。
- **SYN-08 MUST**：QuotaCLI 加载时必须验证 account session 与 device session 属于同一 account。不一致
  时 fail closed、停止上传并要求重新登录，不得向 QuotaBar 返回混合账号的视图。

### 5.5 删除、保留与恢复

- **DAT-01 MUST**：Logout 只停用 sessions；device 和业务数据保留至 Web Delete Device、Delete Usage
  或 Delete Account。
- **DAT-02 MUST**：Delete Device 撤销全部 device sessions，删除该 device 的 quota/Usage，并从所有
  account clients 隐藏。
- **DAT-03 MUST**：删除事务推进 generation 与 precise deletion watermark。删除前生成的 snapshot/
  Usage outbox 永远不能恢复删除前历史；删除后的新活动可在重新登录后上传。
- **DAT-04 MUST**：Device offline/inactive 不自动删除历史。长期保留规则属于 account，不再有匿名
  owner 30 天 GC。
- **DAT-05 MUST**：Delete Account 撤销全部 account/device sessions，并级联 devices、tombstones、
  quota、Usage 与 auth state。
- **DAT-06 SHOULD**：Web 在 Delete Account 前提供 machine-readable JSON export；不得包含 token、
  token hash、GitHub token、provider credential 或原始日志。

## 6. Usage 数据要求

- 本地优先支持 Codex 和 Claude Code 的历史日志；adapter、dedup、coverage 与精确字段见
  [`usage-analytics.md`](./usage-analytics.md)。
- 权威 token facts 至少包含 input、cached input、cache write 5m/1h、output、reasoning 和 total；所有
  值为非负 safe integer，并满足定义的守恒关系。
- 成本分析是首发能力。Billing facts 还必须保留 `billing_channel`、`channel_source`、request count、
  context bucket、service tier、speed、inference geo、固定 allowlist 的 billable tool counts，以及
  source-reported cost coverage。聚合后不可恢复的计价维度不得在上传前丢弃。
- 服务端只存非空的 sparse hourly facts、coverage metadata 和删除控制状态。事实键包含
  `device_id + bucket_start_utc + device-local date/hour + agent + billing channel + model + bounded billing
  dimensions`；不存逐 turn/message/tool 事件、tool 参数或任意 tool name。
- Account total 是账号下各 device 权威 totals 的和。MVP 不猜测两台 device 是否扫描了同一份复制
  日志；UI 必须保留 device breakdown，使重复来源可发现。
- 每个 event 同时投影到 UTC 小时和 pinned device IANA timezone 下的本地日期/小时；日报沿用提交时的
  本地日期，不按 viewer timezone 重切历史。价格生效日由 `bucket_start_utc` 推导。
- 模型名与维度有长度、数量、日期范围和响应大小上限，避免 D1 行数失控。
- 唯一价格目录是随 QuotaRelay 部署、受版本控制的资源；Relay 通过带 revision/ETag 的 API 提供，
  QuotaCLI 校验后缓存。目录按 billing channel、model、UTC effective date、tier/speed/region/context
  精确匹配。运行时不依赖第三方价格服务；LiteLLM/models.dev 只能用于维护时发现差异。
- Web、QuotaCLI 和 QuotaBar 默认使用 `calculate` cost mode；同时支持 `auto` 与 `reported`。任何
  unpriced/partial 范围必须显式标记，禁止把缺失价格按 `$0` 聚合。
- Codex 当前日志没有价格；Claude Code 的 `costUSD` 也只视为可能不完整的 source-reported fact。
  客户端从未成功获取价格目录时显示 unpriced，不内置另一份静态价格或猜测价格。

## 7. Managed-only 与 greenfield 边界

- 最终代码不包含 `owners`、`owner_sessions`、`account_owner_links`、canonical owner、owner claim、
  anonymous registration 或 owner-approved pairing。
- 最终产品不包含 self-hosted Relay binary/image、Bun/SQLite Relay adapter、Compose、Relay URL setting、
  discovery/enrollment 或 Pair Device UI。
- CLI 命令收敛为 `quotacli login`、`quotacli logout`、`quotacli auth status` 与上传/同步命令；删除
  `relay pair --relay`、`relay unpair` 和任意 endpoint selection。
- 不做旧 owner/device/data/token 转换，不做 dual read/write，不做 legacy claim window，不保留隐藏
  fallback。开发/测试数据允许清空。
- 数据库仍必须通过显式、可 review 的 destructive migration 或部署前 reset 到最终 schema；“不迁移
  用户数据”不等于绕过 migration discipline 或手改已应用 migration。
- 新协议作为唯一受支持版本发布；旧路由与旧 discovery 同时从 runtime 删除，不在旧 schema 上改义。

## 8. 非功能需求

### 8.1 安全

- Account、device、GitHub 和 provider credentials 是四个不同边界；授权函数、token audience、scope
  和存储位置不得混用。
- Access token 短期；refresh token 可旋转、只存 hash、支持 session revoke。所有 bearer plaintext 只
  返回一次并保存在平台安全存储或 `0600` 用户文件。
- Auth/refresh/device-code/delete endpoints 使用 keyed subject 的持久化 rate limit；不记录原始 IP、
  GitHub subject 或 token。
- Cross-account device ID 猜测返回不泄漏存在性的 generic `404`。
- 所有请求拒绝 credential-bearing redirects；remote origin 固定为 managed canonical origin。

### 8.2 一致性与可用性

- Account/device upsert、grant consume、session issuance、logout、Delete Device 与 Delete Account 有明确
  transaction boundary。
- Local collection 与 cache 不依赖账号服务可用；outage 不丢 complete local results。
- QuotaBar 启动先显示上次 CLI 输出的 last-known report，再异步调用 bundled CLI 同步；
  历史扫描不得阻塞 menu panel。
- 现有 helper 60 秒/1 MiB 边界继续成立；本地 cache/outbox 使用原子替换、用户级锁和 no-follow
  safety。
- 60 秒 helper timeout 只适用于 collection/sync。交互式 `login` 由 OAuth grant 的最长生命周期约束，
  QuotaBar 必须可取消该子进程，不得因用户在浏览器中停留超过 60 秒而失败。
- Date-range query 只扫预聚合 rows，并有严格上限与稳定排序。

## 9. 并行开发契约

Account 与 Usage 可以并行，但共同冻结以下最小接口：

1. `AccountState` 提供 account/session/device upsert、授权、logout 与 delete 的 runtime-neutral 原语。
2. Device 是 quota 与 Usage 唯一 write principal；两个 envelope 都带 `device_id` 与 generation。
3. UsageState 以 `device_id` 存储 sparse hourly facts；account read 在授权后传入 account ID 或 authorized device IDs，
   Usage service 不读取 D1 binding。
4. Web Delete Device 调用 quota 与 Usage 共用的 device deletion transaction/control state。
5. QuotaCLI 是 installation/device local state 的唯一 owner；QuotaBar 与 CLI 只共享稳定的命令输出
   contract，不共享文件读写责任。
6. Local parser/cache 可在 synthetic device fixture 上开发；Account 可用 synthetic rows 完成跨设备
   查询，两者不等待彼此 UI。

| Workstream | 主责 | 可并行内容 | 集成点 |
| --- | --- | --- | --- |
| **A. Account & device auth** | GitHub OAuth、AccountState、device identity/session、Web/CLI login/logout | 与 parser/cache/D1 Usage schema 并行 | device principal + account authorization |
| **B. Usage** | Codex/Claude parser、cache/outbox、coverage replacement、device upload、D1 aggregates | 与 auth UI/device store 实现并行 | device generation + account query |
| **C. Product integration** | QuotaCLI account JSON surfaces、QuotaBar UI、Web devices/Usage、delete/export、managed-only removal | A/B contract 冻结后并行 UI | lifecycle E2E |

## 10. 交付顺序与验收

### Gate 0：契约冻结

- 接受 direct Account → Devices 模型、GitHub-only、installation identity 边界、两类 session、logout 与
  Web delete 语义。
- 明确重新登录会 backfill 退出期间的本地 Usage。
- 冻结 device generation/deletion watermark、UTC-hour coverage、billing channel 与 Usage fact schema。

### Gate 1：独立垂直切片

- Account：synthetic GitHub subject → account upsert → device upsert → scoped tokens → logout/delete。
- Usage：fixture → local hourly aggregate → synthetic device upload → D1 row replacement/query。
- 两条流使用同一 device fixture 和 generation contract。

### Gate 2：客户端登录与多设备

- Web browser login、CLI browser PKCE 与 CLI device auth 全部成功/取消/过期可恢复；
  QuotaBar 调起的是同一 CLI browser flow，不再实现第二套 OAuth。
- 第二台 Bar 通过其 bundled CLI 登录后展示其他 devices；同 Mac 仅出现一个 device。
- 退出本机停止上传但远端可见；同账号重新登录恢复同一 ID。

### Gate 3：删除、竞态与隐私

- Web Delete Device 删除全部业务 rows、撤销 tokens、隐藏 device；offline stale outbox 被拒绝。
- Delete 后同 installation 重登录复用 ID、新 generation、空历史；只允许 post-watermark activity。
- 请求、D1、日志、fixture、export 和 UI 均通过敏感字段 allowlist 检查。
- 价格计算 fixtures 覆盖不同 billing channel、cache TTL、context、tier/speed/geo、source-reported
  fallback、未知模型、目录 effective-date 与 revision/ETag 边界；三个展示端对同一 fixture 的金额和
  coverage 完全一致。

### Gate 4：Breaking replacement

- 最终 build/router/UI 不再包含 self-hosted、SQLite Relay、owner、pairing、Relay URL/discovery 或旧 CLI
  commands。
- 完成 root format/check/test/build、Relay D1/dry-run、Swift decoding、真实 QuotaBar + bundled helper
  account E2E。
- 更新 canonical docs 与 superseding ADR 后，才将 account history 标为正式能力。

## 11. 合理性 review

### 11.1 当前方案为何不能直接满足

此前方案保留 account → owners → devices、legacy owner claim、配对批准、device credential continuity
和 migration window；QuotaBar logout 也不会停止 device upload。这些都与本需求相反，不能靠字段微调
修复，必须换成 direct account-device model。

### 11.2 新方案成立的原因

- **更少的领域对象**：删除 owner/link/claim/canonical owner 后，账号即读取、管理、聚合和保留边界。
- **登录即绑定**：OAuth 成功事务同时 upsert device 和签发 write-self credential，无第二次批准。
- **权限隔离**：CLI 是完整客户端，因此同时保存 account 与 device session；但 routine
  collector 只使用 device token，账号权限不进入上传请求。QuotaBar 不获得任何 token。
- **重装稳定**：随机 user-level installation identity 解决普通重装；明确不承诺 OS wipe，避免硬件
  fingerprint 的隐私与可移植性问题。
- **删除可证明**：tombstone + generation/watermark 防止离线 outbox 和本地旧日志恢复已删历史。
- **真正并行**：Account 与 Usage 共享 device contract，而不通过 D1 类型或迁移期 owner 彼此耦合。

### 11.3 需要特别接受的边界

1. **退出不是从服务器解绑**：否则 Web 无法继续看到设备。UI 应使用“退出登录/停止同步”，不要写
   “已从账号移除”。
2. **普通重装可恢复，彻底清除本地状态不可恢复**：这是随机 ID 的必要边界。硬件 ID 不应成为补丁。
3. **重新登录会补传退出期间历史**：这是已冻结的长期连续统计语义；若未来需要永久隐私断点，必须
   另行提供显式删除/排除操作，不能改变 logout 的含义。
4. **Web delete 后仍保留最小 tombstone**：仅用于拒绝旧 credential/outbox 和恢复稳定 ID；账号删除
   才完全删除。
5. **QuotaBar 不是第二个客户端**：Bar 和直接执行的 CLI 都调用同一 QuotaCLI 实现与用户级
   状态。CLI logout 后 Bar 立即显示 signed-out，不存在独立 Bar account session。
6. **复制整个用户配置不是重装**：克隆产生相同 installation ID，MVP 以 sequence conflict fail closed，
   不增加硬件 attestation。

## 12. 实现时必须更新的 canonical 来源

- 产品状态、命令、layout 与 distribution：[`README.md`](../../README.md)
- Account/device data paths、managed-only runtime 与 package graph：
  [`architecture.md`](../architecture.md)
- GitHub/session/device identity、PII、token、retention 与 deletion：
  [`security.md`](../security.md)
- 用新的 Account + Device ADR supersede anonymous owner、device pairing 与 URL-only enrollment ADR。
- 更新持久化 ADR，移除 self-hosted SQLite 边界，确认 D1 是 adapter 而非 Account 领域依赖。
- Protocol schemas、generated JSON Schema、Swift decoding、D1 migration、app README 与 acceptance
  harness 随实现同步。

在这些 canonical 更新合入前，本文保持 proposed/non-canonical，不能描述为当前线上行为。
