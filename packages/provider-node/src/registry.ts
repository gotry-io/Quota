import type { ProviderCollector, ProviderDescriptor } from "@gotry-io/provider-core";
import type { ProviderId } from "@gotry-io/quota-protocol";
import { ClaudeCollector, type ClaudeCollectorOptions } from "./providers/claude/collector.ts";
import { CodexCollector, type CodexCollectorOptions } from "./providers/codex/collector.ts";
import { GrokCollector, type GrokCollectorOptions } from "./providers/grok/collector.ts";

export const providerDescriptors = [
  {
    id: "codex",
    display_name: "Codex",
    credential_sources: ["$CODEX_HOME/auth.json", "~/.codex/auth.json"],
    collection_strategies: ["chatgpt_usage_api", "codex_app_server"],
  },
  {
    id: "claude",
    display_name: "Claude Code",
    credential_sources: ["~/.claude/.credentials.json", "macOS Keychain: Claude Code-credentials"],
    collection_strategies: ["anthropic_oauth_usage_api"],
  },
  {
    id: "grok",
    display_name: "Grok",
    credential_sources: ["$GROK_HOME/auth.json", "~/.grok/auth.json"],
    collection_strategies: ["grok_billing_api"],
  },
] as const satisfies readonly ProviderDescriptor[];

export const PROVIDER_ORDER = ["codex", "claude", "grok"] as const satisfies readonly ProviderId[];

export interface CollectorFactoryOptions {
  clientVersion?: string;
  codex?: CodexCollectorOptions;
  claude?: ClaudeCollectorOptions;
  grok?: GrokCollectorOptions;
}

export function createDefaultCollectors(
  options: CollectorFactoryOptions = {},
): Record<ProviderId, ProviderCollector> {
  const client = options.clientVersion ? { clientVersion: options.clientVersion } : {};
  return {
    codex: new CodexCollector({ ...options.codex, ...client }),
    claude: new ClaudeCollector(options.claude),
    grok: new GrokCollector({ ...options.grok, ...client }),
  };
}

export function resolveProviders(selection: "all" | ProviderId | ProviderId[]): ProviderId[] {
  if (selection === "all") {
    return [...PROVIDER_ORDER];
  }
  if (typeof selection === "string") {
    return [selection];
  }
  const selected = new Set(selection);
  return PROVIDER_ORDER.filter((id) => selected.has(id));
}
