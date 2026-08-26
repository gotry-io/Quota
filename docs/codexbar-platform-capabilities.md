# CodexBar 平台能力梳理

本文梳理 [CodexBar](https://github.com/steipete/CodexBar) 的**平台额度**、**使用量/成本**、**鉴权与降级规则**及平台特有能力，作为 Quota 对齐基线。Quota 自身策略仍以 [`provider-collection.md`](provider-collection.md) 为准。

## 核对说明

| 项 | 值 |
| --- | --- |
| 上游仓库 | `steipete/CodexBar` |
| 核对提交 | `f74117a`（2026-08-20） |
| 核对方式 | 读取 `ProviderManifest.swift`（69 个 descriptor）+ 各 `*ProviderDescriptor.swift` 的 `fetchPlan` / `resolveStrategies`、`ProviderTokenCostConfig.supportsTokenCost`，并以单平台文档补窗口语义 |
| 优先级 | **Descriptor / strategy 源码 > 单平台 `docs/<provider>.md` > `docs/providers.md` 总览表** |
| 增量核对 | `27c7f33`（2026-08-22）：仅重读 Quota 已支持 provider 的 descriptor / probe / fetcher（Codex、Claude、Cursor、Grok、Kimi、DeepSeek、OpenRouter、LiteLLM），用于 §7 对照。2026-08-26 复核 §7：上游未变，Quota 侧删掉了全部 provider CLI 阶梯（Claude PTY 探针、Codex `app-server`、Grok `agent stdio`），并把 `browser_session` 收敛到 Cursor 一家；差异按下表逐条记录。2026-08-26 增量：重读 `ProviderVersionDetector.swift` 与 `CodexPAT/CodexCLIUserAgent.swift`，Quota 已按同样思路把 Claude / Codex UA 的版本号改为读取本机安装的 CLI。2026-08-26 增量：Quota 为 Grok、Claude Code 与 Codex 各加回一条**只在过期时触发**的续期子进程，三家共用同一套机制与同一个 spawn 点，取额度的阶梯仍不含 CLI |

已发现并按源码修正的偏差（相对上游 `providers.md` 或初版整理）：

1. **Usage & Spend 入选集**：代码以 `tokenCost.supportsTokenCost == true` 为准，共 **11** 个，不是总览里点名的 6 个。
2. **Codex Auto**：源码为 `PAT → OAuth → CLI`（选中 managed workspace 时去掉 CLI）；**不是**「App: oauth→cli / CLI: web→cli」。`.web`（openai-web）仅显式 source。
3. **Cursor**：pipeline 只有一条 `CursorStatusFetchStrategy`；App→Cookie 降级在 `CursorStatusProbe` 内部；`sourceMode == .web` 时 `allowAppAuthFallback = false`。浏览器导入顺序 **Safari 优先**。
4. **Kimi Auto**：`API → CLI credential → Web`（中间多一步 CLI 凭证）。
5. **DeepSeek**：不只 API；无 key 时走 Platform Web；有 key 时 API 为主，可选 Chrome 会话补 detailed usage。
6. **OpenCode Go Auto**：unscoped=`local → api → web`；scoped=`web → local → api`（文档常漏掉 API）。
7. **Grok Auto**：`CLI → OAuth(proxy) → Web → OAuth(grpc)`；本地 sessions 不在额度 pipeline 内。
8. **Groq Auto**：Console Web → Prometheus metrics API。

---

## 1. 术语与产品切分

| 概念 | 含义 | 代码落点 |
| --- | --- | --- |
| **Quota / UsageSnapshot** | 菜单栏/卡片剩余额度窗口 | `ProviderFetchStrategy.fetch` → `UsageSnapshot` |
| **Token cost / Usage & Spend** | 花费、token、按日图表 | `ProviderTokenCostConfig.supportsTokenCost`；Settings 过滤见 `SettingsStore+MenuPreferences` / `UsageStore+SpendDashboardTokenCost` |
| **Fetch strategy** | 一条取数路径 | `ProviderFetchKind`：cli / web / oauth / apiToken / local 等 |
| **Source mode** | 过滤 pipeline | `.auto` / `.web` / `.oauth` / `.api` / `.cli` |

通用规则（`docs/provider.md` + pipeline 实现）：

1. `resolveStrategies` 返回**有序**策略列表；`auto` 按序尝试。
2. `isAvailable == false` 跳过；失败是否继续看 `shouldFallback`。
3. Cookie 类常见 Automatic / Manual；成功会话可进 Keychain cache。
4. API key / 手动 Cookie / token accounts 等在 `~/.codexbar/config.json`（或 `~/.config/codexbar/config.json`）。
5. Identity 按 provider 隔离。

---

## 2. 使用量与成本（跨平台）

### 2.1 谁进入 Usage & Spend

源码条件：`descriptor.tokenCost.supportsTokenCost` 且 provider 已启用（另有 cost 总开关）。

`supportsTokenCost: true`（`f74117a`）：

| ID | 显示名 | `supportsTokenSnapshot` | Cost 形态（摘要） |
| --- | --- | --- | --- |
| `codex` | Codex | true | 本机 sessions / archived_sessions JSONL + pi/OMP |
| `claude` | Claude | true | 本机 projects JSONL + pi/OMP；Admin API spend |
| `openai` | OpenAI | false/default | Admin / balance API 历史 |
| `cursor` | Cursor | macOS true / 非 macOS false | 远端 dashboard events（opt-in） |
| `vertexai` | Vertex AI | true | Claude 本地日志过滤 Vertex 标记 |
| `bedrock` | AWS Bedrock | true | Cost Explorer（+ 可选 CloudWatch） |
| `mistral` | Mistral | false/default | Cookie 会话账单 + 客户端算价 |
| `openrouter` | OpenRouter | false/default | `/credits` + `/key` spend 字段 |
| `opencodego` | OpenCode Go | false/default | 本地 DB / API / web 路径上的用量 |
| `grok` | Grok | false/default | 本地 session token 桶进目录；credits 不当美元 |
| `xai` | xAI | false/default | Management API prepaid + 30d spend |

其余 58 个 descriptor 为 `supportsTokenCost: false`，Settings → Usage & Spend **不会**当 cost 订阅列出。

### 2.2 Cost 实现形态

| 形态 | 平台 | 做法 |
| --- | --- | --- |
| 本机 session 扫描 | Codex、Claude | JSONL；本地定价 / models.dev 缓存；1–365 天窗口 |
| Claude 日志过滤 | Vertex AI | 同 scanner，按 Vertex 标记过滤 |
| Admin / org API | OpenAI、Claude Admin | 组织 spend / messages |
| 远端 Dashboard 事件 | Cursor | `POST /api/dashboard/get-filtered-usage-events`；账户级跨设备 |
| Billing / usage API | OpenRouter、xAI、Bedrock、Mistral… | 厂商计费接口 |
| 本地信号（非美元） | Grok | `~/.grok/sessions/**/signals.json` |

---

## 3. 全量平台矩阵（Automatic，源码顺序）

「使用量」列：`supportsTokenCost` 或明确的 detailed/spend 能力。策略名来自 descriptor。

| ID | Automatic 额度策略顺序 | 使用量 / Cost | 备注 |
| --- | --- | --- | --- |
| `codex` | **PAT → OAuth**（无 workspace 时再加 **CLI**） | 本机 JSONL | 显式 `.web` = openai-web；不写回 `auth.json` |
| `openai` | API（Swift balance；插件开启时 JS 优先） | Admin/API spend | 与 Codex 凭证隔离 |
| `azureopenai` | API deployment probe | — | 无 spend 历史 |
| `claude` | 见 §4.2（App: oauth→cli→web；CLI: web→cli；Admin/选中账号可钉死） | 本机 JSONL + Admin | claude-swap；Keychain 策略 |
| `cursor` | 单策略 `CursorStatusFetchStrategy`；内部 App→cache→import→legacy | 远端 dashboard（macOS） | `.web` 禁用 App fallback；Safari 优先 |
| `clinepass` | API（bundled TS plugin） | — | |
| `opencode` | Web | — | |
| `opencodego` | unscoped: **local→api→web**；scoped: **web→local→api** | token-cost true | scoped = 选中账号 / 手动 cookie / workspace |
| `alibaba` | cookie off → **API only**；否则 **web→API** | — | |
| `alibabatokenplan` | Web | — | |
| `qwencloud` | Web | — | OneConsole 共享层 |
| `factory` | **API→Web**（`.cli` 等同 auto） | — | |
| `fireworks` | API | billing summary（非 token-cost 入选） | |
| `gemini` | API（Gemini CLI OAuth credentials） | — | |
| `antigravity` | app→cli→ide→oauth（有 oauth 凭证时） | — | |
| `copilot` | API | — | |
| `devin` | Web | — | |
| `zai` | API（plugin） | usageDetails | |
| `minimax` | 见 §5：Coding Plan web 与 API token 分支 | 可选 30d web history | |
| `manus` | Web | — | |
| `kimi` | **API → CLI credential → Web** | — | |
| `kilo` | **API → CLI** | — | |
| `kiro` | CLI `/usage` | — | |
| `vertexai` | OAuth（ADC） | Claude 本地过滤 | |
| `augment` | **CLI → Web** | — | |
| `jetbrains` | Local XML | — | |
| `moonshot` | API | — | |
| `amp` | **CLI → API → Web** | — | |
| `t3chat` | Web | — | |
| `ollama` | cookie off→API；有 token→**web→API**；否则 web | — | |
| `synthetic` | API | — | |
| `openrouter` | API（plugin） | token-cost true | |
| `elevenlabs` | API | — | |
| `warp` | API | — | |
| `windsurf` | **Web → Local** | — | |
| `zed` | Local Keychain session → cloud API | — | kind 标 api，实现为 local session |
| `perplexity` | Web | — | |
| `mimo` | Web | — | |
| `doubao` | CLI/API 探活（descriptor modes `.auto,.cli,.api`） | — | |
| `sakana` | Web（手动 Cookie） | — | |
| `abacus` | Web | — | |
| `mistral` | Web | token-cost true | Chrome→Firefox→Safari |
| `deepseek` | 有 key→**API**（可叠加 Chrome detailed）；无 key→**Platform Web** | detailed via Chrome | **非**纯 API |
| `deepinfra` | API | — | |
| `codebuff` | API | — | |
| `crof` | API（plugin） | — | |
| `venice` | API | — | |
| `commandcode` | Web | — | |
| `qoder` | Web | — | |
| `stepfun` | Web | — | |
| `bedrock` | API | token-cost true | |
| `grok` | **CLI → OAuth(proxy) → Web → OAuth(grpc)** | token-cost true（本地 tokens） | ≠ `xai` |
| `groq` | **Console Web → Prometheus API** | — | |
| `llmproxy` | API | — | |
| `litellm` | API | — | 需 base URL |
| `deepgram` | API（plugin） | — | |
| `poe` | API | — | |
| `chutes` | API | — | |
| `neuralwatt` | API | — | |
| `clawrouter` | API（plugin） | — | |
| `longcat` | Web（token-pack → legacy tokenUsage） | — | |
| `sub2api` | API | — | |
| `wayfinder` | 本地 gateway | — | |
| `zenmux` | API | — | |
| `aiand` | API（30d logs spend） | — | |
| `zoommate` | Web（cookie→bearer） | credits chart | |
| `xai` | API（plugin） | token-cost true | Management key + team |
| `notion` | Web | — | |
| `ibmbob` | API | — | |

稳定 ID 顺序与 `ProviderManifest.allDescriptors` / `docs/provider-ids.md` 一致（69 个）。

---

## 4. 核心平台（源码细节）

### 4.1 Codex

**文件**：`Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift`

```text
auto (无 codexWorkspaceID):  [PAT, OAuth, CLI]
auto (有 workspace):         [PAT, OAuth]
.oauth: [OAuth, OAuthNativeRefreshCLI]
.web:   [WebDashboard]          // sourceLabel openai-web
.cli:   [CLI]
.api:   [PAT]
```

- PAT：读 Codex auth 文件中的 PAT；managed `CODEX_HOME` 不隐藏 ambient PAT。
- OAuth：`wham/usage`；不写回 `auth.json`；过期委托 CLI。
- CLI：`codex app-server` RPC；PTY `/status` 仅诊断。
- openai-web：显式 web / extras，**不在 auto pipeline**。
- Cost：本机 `sessions` + `archived_sessions`；Usage & Spend 账户行排除 pi/OMP。

### 4.2 Claude

**文件**：`ClaudeProviderDescriptor.swift` + `ClaudeSourcePlanner.swift`

选中 token account 时钉死策略（Admin / OAuth token / Web cookie），**禁止**回落到 ambient。

未选中账号时：

| 条件 | 顺序 |
| --- | --- |
| `sourceMode == .api` 或检测到 Admin key | `[AdminAPI]` |
| App + auto | oauth → cli → web |
| CLI runtime + auto | web → cli |
| App + 显式 oauth | oauth → cli（owner CLI fallback） |

Cost：本机 projects JSONL；Admin 另出 org spend。

### 4.3 Cursor

**文件**：`CursorProviderDescriptor.swift` + `CursorStatusProbe(+SessionResolution).swift`

- Pipeline：**仅** `CursorStatusFetchStrategy`（kind `.web`）。
- `fetch`：`allowAppAuthFallback: context.sourceMode != .web`。
- Probe 内 Automatic：Cursor.app `cursorAuth/accessToken` → Keychain cookie → browser import → legacy `cursor-session.json`。
- Cookie 导入顺序：descriptor 强制 **Safari 优先**，再跟 defaultImportOrder 其余项。
- Linux：无 App/自动浏览器；手动 Cookie 可通过 `browserSupportExemption`。
- Cost：`supportsTokenCost true`；snapshot 仅 macOS；Cookie source Off 时清 cost。

### 4.4 Grok

```text
.auto: [CLI, OAuth(proxy), Web, OAuth(grpc)]
.cli / .oauth / .web: 各自单策略
.api: []
```

本地 `signals.json` 不在额度 strategy 列表内，供目录/诊断。与 `xai` Management API 分离。

### 4.5 OpenCode Go

```text
.api:  [API]
.web:  [Web]
.auto + scoped (账号/手动cookie/workspace): [Web, Local, API]
.auto + unscoped:                          [Local, API, Web]
```

### 4.6 Kimi / DeepSeek / OpenRouter / LiteLLM

| 平台 | Automatic | 说明 |
| --- | --- | --- |
| Kimi | API → **CLI credential** → Web | 源码多一步 CLI 凭证 |
| DeepSeek | 有 key→API（可选 Chrome detailed）；无 key→Platform Web | `shouldFallback` 在 API/Web 策略上多为 false（互不自动串） |
| OpenRouter | API plugin | token-cost true |
| LiteLLM | API | key/info → user/team info；**非** token-cost 入选 |

---

## 5. 其他自动分支（源码）

**Alibaba Coding Plan**：`cookieSource == .off` → 仅 API；否则 web→API。

**MiniMax Auto**：

- 使用 API token 且 standard key → 仅 Coding Plan fetch；
- 使用 API token 且非 standard → API→Coding Plan；
- 否则仅 Coding Plan web。

**Ollama Auto**：cookie off→仅 API；有 ollama token→web→API；否则仅 web。

**Amp**：CLI→API→Web。

**Factory**：API→Web（`.cli` 走同一列表）。

**Windsurf**：Web→Local（固定两条）。

**Antigravity Auto**：有 oauth 时 app→cli→ide→oauth，否则 app→cli→ide。

---

## 6. 平台特有功能（代码/文档交叉）

| 能力 | 相关 | 说明 |
| --- | --- | --- |
| 多账号 / token accounts | Codex、Claude、Cursor、Copilot、OpenRouter、sub2api… | 切换器或堆叠卡 |
| claude-swap | Claude | 外部 `cswap`；不读其密钥库 |
| openai-web extras | Codex | 显式 web；隐藏 WKWebView |
| Add/Switch Account | Cursor | `authenticator.cursor.sh`；钉浏览器 |
| Bundled TS/JS plugins | ClinePass、OpenRouter、z.ai、xAI、Crof、Poe… | `ScriptFetchStrategy` |
| OneConsole 共享 | Alibaba / Qwen Cloud | Cookie/SEC/JSON 工具 |
| Statuspage | 多平台 | 部分只链不轮询 |
| Widgets | `widgetSelectable` | AppEnum 静态表 |
| Linux 限制 | Cookie/App 导入 | 多数自动浏览器导入仅 macOS |

---

## 7. 与 Quota 对照

| 主题 | CodexBar（源码） | Quota 现状（[`provider-collection.md`](provider-collection.md)） |
| --- | --- | --- |
| Cursor 额度 | Probe 内 App→Cookie；`usage-summary` + `get-sand-usage-status`（Grok Bot 周额度）+ `/api/usage?user=`（legacy 按次套餐） | 已对齐：Cursor.app `state.vscdb` → stored browser session；三个端点及 legacy 套餐替换规则一致。Cursor 是 Quota 中唯一声明 `browser_session` 的 provider——它既无 CLI 登录也无 API key，其余各家的 grant 由自己的程序续期，因此不为它们打开任何 cookie store；首次读 cookie 前有同意弹窗，被 macOS 拒绝时报 `browser_access_denied` 而不是「无会话」 |
| Cursor cost | Dashboard events + token-cost | 本机 bubble/JSONL，不等价 |
| Codex Auto | PAT→OAuth→CLI；`CodexOAuthNativeRefreshCLIStrategy` 在 `needsRefresh`（access 过期 ≤60 s，无 expiry 时看 `last_refresh` 是否超 8 天）时降级到 CLI 取额度 | PAT→OAuth(WHAM)；窗口按时长分类。**已对齐（限定触发）**：access token 的 JWT `exp` 过期或距过期不足一分钟时，跑一次 `codex -s read-only -a never app-server` 让 Codex 自己续期，随后重读 `auth.json`；`exp` 读不出来按过期处理，`id_token` 的一小时有效期只用于身份、不算过期。**实现差异**：不用 CLI 取额度——实测 codex-cli 0.149.0（临时 `CODEX_HOME` 副本），续期发生在**进程启动路径**上而非任何 app-server 请求：一次什么都不发的运行仍在约 2.2 s 时发出了 token 请求；CLI 自己的门限也是这个 `exp`（300 s 触发，360 s 不触发），`last_refresh` 改成 30 天前而 token 仍有效时**完全不续期**，所以 Quota 不采用 CodexBar 的 8 天规则——那会换来最多两天的、CLI 根本不理会的 spawn。发 `initialize` 只为确认进程起来了并在说协议（回包 1.3–1.4 s），随后关 stdin，CLI 会先做完已经开始的续期再退出（2.6–2.9 s）；`clientInfo` 如实写 Quota，因为 app-server 会把它拼进自己请求的 `User-Agent`。每小时至多一次（与 Claude / Grok 共用同一张 `cache.sqlite` provider→attempt 表）；8 秒、64 KiB 读完即丢、空的私有 cwd。**有意差异**：不自行拿 refresh token 换 token——Codex 的 refresh token 单次有效（CodexBar 的 `refresh_token_reused`），第二个程序花掉它会让 CLI 拿着一个已作废的 token；也不读 chatgpt.com cookie——同上，多一条 cookie 阶梯只是多要一份浏览器权限；续期后仍过期报 `auth_required`，由用户打开 Codex 续期 |
| Codex UA 版本 | `ProviderVersionDetector.codexVersion()` 跑 `codex --version`（`--version`/`version`/`-v` 依次尝试）；`CodexCLIUserAgent` 拼 `codex_cli_rs/<version> (<platform> <os>; <arch>)` | 已对齐：同一 UA 形状，含 OS 版本（由 `kern.osproductversion` 读出，不起 `sw_vers`）。**实现差异**：只试 `--version`，且按二进制真实路径 + size + mtime 缓存在 `cache.sqlite`，指纹未变不 spawn、同一 CLI 每小时至多一次；读不到版本时退回无版本号的 `codex_cli_rs (...)` |
| Claude Auto | Planner oauth→cli→web | 仅 OAuth。**已对齐（限定触发）**：CodexBar 用 PTY 跑 `/status` 取额度并顺带触发续期；Quota 只在凭据过期或距过期不足一分钟、且 `claudeAiOauth` 里有非空 `refreshToken` 时，跑一次 `claude mcp list` 让 Claude Code 自己续期，随后重读凭据。**实现差异**：不跑 PTY，也不用 CLI 取额度——`mcp list` 只为触碰 CLI 的 refresh 路径（实测 2.1.246：`auth status --json` 不续期；`doctor` 只在环境里带着运行中会话的变量时才续期；`mcp list` 在 `HOME`/`PATH`/`TERM=dumb`/`CLAUDE_CONFIG_DIR` 的最小环境下稳定续期，且凭据未过期时不动文件）；每小时至多一次（`cache.sqlite` 一张 provider→attempt 表记 fingerprint + 时间 + 结果）；10 秒、64 KiB 读完即丢、空的私有 cwd。副作用一条：`mcp list` 会健康检查已批准的 MCP server，空 cwd 把范围限制在 `~/.claude.json` 的 user 级 server，超时兜底。**有意差异**：不读 claude.ai cookie——同 Codex 理由；续期后仍过期报 `auth_required`，CLI 把凭据清空（refresh token 被拒）则报「Claude Code is signed out」，指向终端而不是打开 App |
| Claude UA 版本 | `ProviderVersionDetector.claudeVersion()` 跑 `claude --version`，按 realpath + mtime + size + inode 指纹缓存 30 分钟 | 已对齐：同样的指纹思路（realpath + size + mtime），UA 变为 `claude-code/<version>`。**实现差异**：缓存写在 `cache.sqlite` 而非进程内存，所以跨重启仍不 spawn；不设 TTL——指纹不变就永不重读，指纹变了每小时至多重读一次；读不到版本时退回 `claude-code/2.1.0` |
| Grok Auto | CLI→OAuth(proxy)→Web→OAuth(grpc)；套餐名来自 `/v1/settings` `subscription_tier_display` | OAuth(proxy)→OAuth(grpc)，settings 套餐名一致。**已对齐（限定触发）**：token 过期或距过期不足一分钟时，同样用 `grok agent stdio` 的 `authenticate` 让 CLI 续期，随后重读 `auth.json`。**实现差异**：只在过期时跑，不在每次采集前跑；每小时至多一次（`cache.sqlite` 记 fingerprint + 时间 + 结果）；整个握手 5 秒、64 KiB、只带 `HOME`/`PATH`/`GROK_HOME`；只请求 `cached_token` 方法——grok 1.0.5 只公布 `grok.com`（设备码交互登录），定时任务不得启动它。**有意差异**：不用 CLI 取额度（grok 1.0.5 `agent stdio` 对 `x.ai/billing` 返回 `-32601 Method not found`）；也不读 grok.com cookie——OAuth(grpc) 用同一个 token 打同一个 RPC，cookie 阶梯不增加任何能力 |
| Kimi | API→CLI cred→Web | API key→`~/.kimi-code` CLI 凭据。**有意差异**：不读 kimi.com cookie——同 Codex 理由 |
| DeepSeek | 有 key→API（可叠加 Chrome localStorage `userToken` 取月度明细）；无 key→Platform Web（同一 token） | **有意差异**：仅 API balance。Platform 路径的 token 来源是浏览器 localStorage（安全基线排除）或 `DEEPSEEK_PLATFORM_TOKEN` 手工粘贴；其增量是月度花费明细（cost，不是 quota），余额与 API key 路径相同 |
| OpenRouter | `/credits` + `/key` 额度；`/activity` 花费历史 | 额度已对齐；`/activity` 属 cost，不在 quota 范围 |
| LiteLLM | `key/info` → `user/info` / `team/info`，含 `budget_reset_at` | 已对齐 |
| Usage & Spend 集合 | 11 个 supportsTokenCost | Quota Usage 为本机 agent 扫描集 |
| 采集阶梯总则 | 各 provider 允许 CLI / PTY / cookie 阶梯 | **有意差异**：定时刷新路径不 spawn 任何 provider CLI 取额度，`browser_session` 只声明给 Cursor。凭据过期一律报 `auth_required`，恢复文案指向拥有该 grant 的程序。CLI 子进程只有三种，都跑在采集之前的 refresh worker 上、都不读额度：上面几行的 `--version`（按二进制指纹缓存，同一 binary 至多跑一次），以及 Claude Code / Grok 过期时各一次的续期（`claude mcp list` / `grok agent stdio`，每 provider 每小时至多一次，共用 `cache.sqlite` 里同一条记录）|

---

## 8. 维护

1. 变更后先读 `ProviderManifest` 与对应 `*ProviderDescriptor.resolveStrategies`。
2. 窗口语义仍可读 `docs/<provider>.md`，但 **pipeline 顺序以源码为准**。
3. 刷新本文件时更新「核对提交」哈希。
4. 不替代 [`provider-collection.md`](provider-collection.md)；分叉需在 collection 文档标明有意差异或待对齐。
