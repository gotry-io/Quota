import type { ProviderId } from "@gotry-io/quota-protocol";
import { PROVIDER_ORDER } from "./catalog.ts";
import type { ProviderCollector } from "./contracts.ts";
import { ClaudeCollector, type ClaudeCollectorOptions } from "./providers/claude/collector.ts";
import { CodexCollector, type CodexCollectorOptions } from "./providers/codex/collector.ts";
import { GrokCollector, type GrokCollectorOptions } from "./providers/grok/collector.ts";
import {
  OpenRouterCollector,
  type OpenRouterCollectorOptions,
} from "./providers/openrouter/collector.ts";

export { PROVIDER_ORDER } from "./catalog.ts";

export interface CollectorFactoryOptions {
  clientVersion?: string;
  codex?: CodexCollectorOptions;
  claude?: ClaudeCollectorOptions;
  grok?: GrokCollectorOptions;
  openrouter?: OpenRouterCollectorOptions;
}

type CollectorFactory = (options: CollectorFactoryOptions) => ProviderCollector;

/** One factory per catalog id. */
const COLLECTOR_FACTORIES = {
  codex: (options) =>
    new CodexCollector({
      ...options.codex,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    }),
  claude: (options) => new ClaudeCollector(options.claude),
  grok: (options) =>
    new GrokCollector({
      ...options.grok,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    }),
  openrouter: (options) =>
    new OpenRouterCollector({
      ...options.openrouter,
      ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    }),
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
