import type { ProviderId } from "@gotry-io/quota-protocol";
import { ApiKeyHttpCollector, type ApiKeyHttpCollectorOptions } from "./api-key/collector.ts";
import { API_KEY_SPECS, type ApiKeyProviderId } from "./api-key/specs.ts";
import { PROVIDER_ORDER } from "./catalog.ts";
import type { ProviderCollector } from "./contracts.ts";
import { ClaudeCollector, type ClaudeCollectorOptions } from "./providers/claude/collector.ts";
import { CodexCollector, type CodexCollectorOptions } from "./providers/codex/collector.ts";
import { GrokCollector, type GrokCollectorOptions } from "./providers/grok/collector.ts";

export { PROVIDER_ORDER } from "./catalog.ts";

export interface CollectorFactoryOptions {
  clientVersion?: string;
  codex?: CodexCollectorOptions;
  claude?: ClaudeCollectorOptions;
  grok?: GrokCollectorOptions;
  /** Shared options for all API-key HTTPS collectors. */
  apiKey?: ApiKeyHttpCollectorOptions;
  /** Per-provider API-key option overrides (transport, env, config path). */
  apiKeyByProvider?: Partial<Record<ApiKeyProviderId, ApiKeyHttpCollectorOptions>>;
}

type CollectorFactory = (options: CollectorFactoryOptions) => ProviderCollector;

const AMBIENT_FACTORIES = {
  codex: (options: CollectorFactoryOptions) =>
    new CodexCollector({
      ...options.codex,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    }),
  claude: (options: CollectorFactoryOptions) => new ClaudeCollector(options.claude),
  grok: (options: CollectorFactoryOptions) =>
    new GrokCollector({
      ...options.grok,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    }),
} as const satisfies Record<"codex" | "claude" | "grok", CollectorFactory>;

function apiKeyFactory(id: ApiKeyProviderId): CollectorFactory {
  return (options) => {
    const perProvider = options.apiKeyByProvider?.[id];
    const merged: ApiKeyHttpCollectorOptions = {
      ...options.apiKey,
      ...perProvider,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    };
    return new ApiKeyHttpCollector(API_KEY_SPECS[id], merged);
  };
}

const COLLECTOR_FACTORIES = {
  ...AMBIENT_FACTORIES,
  openrouter: apiKeyFactory("openrouter"),
  deepseek: apiKeyFactory("deepseek"),
  kimi: apiKeyFactory("kimi"),
  litellm: apiKeyFactory("litellm"),
} as const satisfies Record<ProviderId, CollectorFactory>;

export function createDefaultCollectors(
  options: CollectorFactoryOptions = {},
): Record<ProviderId, ProviderCollector> {
  const collectors = {} as Record<ProviderId, ProviderCollector>;
  for (const id of PROVIDER_ORDER) {
    collectors[id] = COLLECTOR_FACTORIES[id](options);
  }
  return collectors;
}

export function resolveProviders(selection: "all" | ProviderId | ProviderId[]): ProviderId[] {
  if (selection === "all") {
    return [...PROVIDER_ORDER] as ProviderId[];
  }
  if (typeof selection === "string") {
    return [selection];
  }
  const selected = new Set(selection);
  return (PROVIDER_ORDER as readonly ProviderId[]).filter((id) => selected.has(id));
}
