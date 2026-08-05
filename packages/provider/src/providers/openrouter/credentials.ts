import { ProviderConfigStore, type ProviderConfigStoreOptions } from "../../config/store.ts";

export const OPENROUTER_SOURCE_API = "openrouter_api";
export const OPENROUTER_ENV_KEY = "OPENROUTER_API_KEY";
export const OPENROUTER_URL_ENV = "OPENROUTER_API_URL";
export const DEFAULT_OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";

export interface OpenRouterCredentials {
  apiKey: string;
  /** Stable redacted label for UI (never the full key). */
  label: string;
  /** Credential location shown in discovery/status. */
  source: string;
  baseUrl: string;
}

export interface ResolveOpenRouterOptions extends ProviderConfigStoreOptions {
  environment?: Readonly<Record<string, string | undefined>>;
  /** Injected store for tests; defaults to the owner-only config file. */
  store?: ProviderConfigStore;
  /** When false, skip config file and use env only. Default true. */
  preferConfig?: boolean;
}

/**
 * Resolution order:
 * 1. Owner-only config (`providers.json` via quotacli config / QuotaBar Settings)
 * 2. `OPENROUTER_API_KEY` environment variable
 */
export async function resolveOpenRouterCredentials(
  options: ResolveOpenRouterOptions = {},
): Promise<OpenRouterCredentials | undefined> {
  const environment = options.environment ?? process.env;
  const preferConfig = options.preferConfig !== false;

  if (preferConfig) {
    const store =
      options.store ??
      new ProviderConfigStore({
        ...(options.path ? { path: options.path } : {}),
        ...(options.homeDirectory ? { homeDirectory: options.homeDirectory } : {}),
        environment,
      });
    try {
      const stored = await store.get("openrouter");
      if (stored?.api_key) {
        const baseUrl =
          normalizeBaseUrl(stored.base_url) ??
          normalizeBaseUrl(environment[OPENROUTER_URL_ENV]) ??
          DEFAULT_OPENROUTER_BASE_URL;
        return {
          apiKey: stored.api_key,
          label: maskApiKey(stored.api_key),
          source: "config:openrouter",
          baseUrl,
        };
      }
    } catch {
      // Unreadable/invalid config falls through to env rather than blocking collection.
    }
  }

  const raw = environment[OPENROUTER_ENV_KEY]?.trim();
  if (!raw) {
    return undefined;
  }
  const baseUrl = normalizeBaseUrl(environment[OPENROUTER_URL_ENV]) ?? DEFAULT_OPENROUTER_BASE_URL;
  return {
    apiKey: raw,
    label: maskApiKey(raw),
    source: `env:${OPENROUTER_ENV_KEY}`,
    baseUrl,
  };
}

export function maskApiKey(apiKey: string, label = "OpenRouter"): string {
  const trimmed = apiKey.trim();
  if (trimmed.length <= 8) {
    return `${label} key`;
  }
  return `${label} ···${trimmed.slice(-4)}`;
}

export function normalizeBaseUrl(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) {
    return undefined;
  }
  try {
    const url = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    if (url.protocol !== "https:") {
      return undefined;
    }
    return `${url.origin}${url.pathname}`.replace(/\/+$/, "") || url.origin;
  } catch {
    return undefined;
  }
}
