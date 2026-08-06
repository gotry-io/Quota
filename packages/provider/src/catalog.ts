/**
 * Single registration table for providers (source of truth).
 *
 * Adding a provider:
 * 1. Add a row here (and collection strategy docs in docs/provider-collection.md)
 * 2. Ambient OAuth: implement packages/provider/src/providers/<id>/ + registry ambient factory
 *    API-key HTTPS: add map + ApiKeyHttpCollectorSpec in providers/<id>/ and register in api-key/specs.ts
 * 3. pnpm generate:provider-catalog  → protocol ProviderId, Swift ProviderID, JSON Schema enums
 * 4. Optional: BrandIcons/<brandIconAsset>.svg for QuotaBar
 *
 * API-key providers set `config.kind: "api_key"` so CLI `config set/get/unset` and QuotaBar
 * Settings forms appear without further UI wiring. Ambient session providers leave `config: null`.
 */
export type ProviderConfigKind = "api_key";

export interface ProviderApiKeyConfigSpec {
  kind: "api_key";
  /** Primary env fallback when config file has no key (display + default). */
  envKey?: string;
  /** Allow `quotacli config set <id> --base-url` / interactive base URL prompt. */
  supportsBaseUrl: boolean;
  /** When true, base URL is required at config time (e.g. LiteLLM proxy). */
  requireBaseUrl?: boolean;
  /** Allow http:// for loopback/private/.local when validating base URLs. */
  allowPrivateHttp?: boolean;
  /** Mask prefix for get/list (never the full secret). */
  maskLabel: string;
}

export interface ProviderCatalogEntry {
  id: string;
  displayName: string;
  /** Stable product order (lower first). */
  order: number;
  /** Menubar Agents toggle default. */
  defaultVisible: boolean;
  /** Recovery command shown on auth_required. */
  loginCommand: string;
  /** Full auth_required message (may mention env fallbacks). */
  authRequiredMessage: string;
  /** Brand SVG asset name under BrandIcons/ (no extension). */
  brandIconAsset: string;
  credentialSources: readonly string[];
  collectionStrategies: readonly string[];
  /** Null = ambient session only; no quotacli config secrets. */
  config: ProviderApiKeyConfigSpec | null;
}

export const PROVIDER_CATALOG = {
  codex: {
    id: "codex",
    displayName: "Codex",
    order: 0,
    defaultVisible: true,
    loginCommand: "codex login",
    authRequiredMessage: "Codex auth.json not found. Run `codex` to log in.",
    brandIconAsset: "openai",
    credentialSources: ["$CODEX_HOME/auth.json", "~/.codex/auth.json"],
    collectionStrategies: ["chatgpt_usage_api", "codex_app_server"],
    config: null,
  },
  claude: {
    id: "claude",
    displayName: "Claude Code",
    order: 1,
    defaultVisible: true,
    loginCommand: "claude auth login",
    authRequiredMessage:
      "Claude OAuth credentials are missing or unreadable. Run `claude auth login`.",
    brandIconAsset: "claude",
    credentialSources: ["~/.claude/.credentials.json", "macOS Keychain: Claude Code-credentials"],
    collectionStrategies: ["anthropic_oauth_usage_api", "claude_cli_auth_refresh"],
    config: null,
  },
  grok: {
    id: "grok",
    displayName: "Grok",
    order: 2,
    defaultVisible: true,
    loginCommand: "grok login",
    authRequiredMessage: "Grok auth.json not found. Run `grok login`.",
    brandIconAsset: "grok",
    credentialSources: ["$GROK_HOME/auth.json", "~/.grok/auth.json"],
    collectionStrategies: ["grok_billing_api", "grok_cli_auth_refresh"],
    config: null,
  },
  openrouter: {
    id: "openrouter",
    displayName: "OpenRouter",
    order: 3,
    defaultVisible: false,
    loginCommand: "quotacli config set openrouter",
    authRequiredMessage:
      "OpenRouter API key is missing. Run `quotacli config set openrouter` or set `OPENROUTER_API_KEY`.",
    brandIconAsset: "openrouter",
    credentialSources: ["config:openrouter", "OPENROUTER_API_KEY"],
    collectionStrategies: ["openrouter_credits_api", "openrouter_key_api"],
    config: {
      kind: "api_key",
      envKey: "OPENROUTER_API_KEY",
      supportsBaseUrl: true,
      maskLabel: "OpenRouter",
    },
  },
  deepseek: {
    id: "deepseek",
    displayName: "DeepSeek",
    order: 4,
    defaultVisible: false,
    loginCommand: "quotacli config set deepseek",
    authRequiredMessage:
      "DeepSeek API key is missing. Run `quotacli config set deepseek` or set `DEEPSEEK_API_KEY`.",
    brandIconAsset: "deepseek",
    credentialSources: ["config:deepseek", "DEEPSEEK_API_KEY", "DEEPSEEK_KEY"],
    collectionStrategies: ["deepseek_balance_api"],
    config: {
      kind: "api_key",
      envKey: "DEEPSEEK_API_KEY",
      supportsBaseUrl: true,
      maskLabel: "DeepSeek",
    },
  },
  kimi: {
    id: "kimi",
    displayName: "Kimi Code",
    order: 5,
    defaultVisible: false,
    loginCommand: "quotacli config set kimi",
    authRequiredMessage:
      "Kimi Code API key is missing. Run `quotacli config set kimi` or set `KIMI_CODE_API_KEY`.",
    brandIconAsset: "kimi",
    credentialSources: ["config:kimi", "KIMI_CODE_API_KEY", "KIMI_API_KEY"],
    collectionStrategies: ["kimi_code_usages_api"],
    config: {
      kind: "api_key",
      envKey: "KIMI_CODE_API_KEY",
      supportsBaseUrl: true,
      maskLabel: "Kimi",
    },
  },
  litellm: {
    id: "litellm",
    displayName: "LiteLLM",
    order: 6,
    defaultVisible: false,
    loginCommand: "quotacli config set litellm",
    authRequiredMessage:
      "LiteLLM API key or base URL is missing. Run `quotacli config set litellm` or set `LITELLM_API_KEY` and `LITELLM_BASE_URL`.",
    brandIconAsset: "litellm",
    credentialSources: ["config:litellm", "LITELLM_API_KEY", "LITELLM_BASE_URL"],
    collectionStrategies: ["litellm_budget_api"],
    config: {
      kind: "api_key",
      envKey: "LITELLM_API_KEY",
      supportsBaseUrl: true,
      requireBaseUrl: true,
      allowPrivateHttp: true,
      maskLabel: "LiteLLM",
    },
  },
} as const satisfies Record<string, ProviderCatalogEntry>;

export type ProviderCatalogId = keyof typeof PROVIDER_CATALOG;

export const PROVIDER_ORDER = (Object.values(PROVIDER_CATALOG) as ProviderCatalogEntry[])
  .slice()
  .sort((a, b) => a.order - b.order)
  .map((entry) => entry.id as ProviderCatalogId);

export function configurableProviderIds(): ProviderCatalogId[] {
  return PROVIDER_ORDER.filter((id) => PROVIDER_CATALOG[id].config !== null);
}

export function isConfigurableProviderId(id: string): id is ProviderCatalogId {
  return (
    Object.hasOwn(PROVIDER_CATALOG, id) && PROVIDER_CATALOG[id as ProviderCatalogId].config !== null
  );
}

export function authRequiredMessage(provider: ProviderCatalogId): string {
  return PROVIDER_CATALOG[provider].authRequiredMessage;
}

/** Snapshot for codegen (Swift + protocol ids). */
export function providerCatalogSnapshot(): readonly ProviderCatalogEntry[] {
  return PROVIDER_ORDER.map((id) => PROVIDER_CATALOG[id]);
}
