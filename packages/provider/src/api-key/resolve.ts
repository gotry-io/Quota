import type { ProviderId } from "@gotry-io/quota-protocol";
import { ProviderConfigStore, type ProviderConfigStoreOptions } from "../config/store.ts";

export interface ApiKeyCredentials {
  apiKey: string;
  /** Stable redacted label for UI (never the full key). */
  label: string;
  /** Credential location shown in discovery/status. */
  source: string;
  baseUrl: string;
}

export interface ApiKeyResolveConfig {
  provider: ProviderId;
  /** Env vars checked in order after config file. */
  envKeys: readonly string[];
  /** Optional base URL env (LiteLLM self-hosted proxy only). */
  urlEnvKey?: string;
  /** When set, used if config/env do not supply a base URL. */
  defaultBaseUrl?: string;
  /** When true, credentials are missing without an explicit base URL. */
  requireBaseUrl?: boolean;
  /** Allow http:// for loopback / RFC1918 / .local (LiteLLM self-host). */
  allowPrivateHttp?: boolean;
  maskLabel: string;
}

export interface ResolveApiKeyOptions extends ProviderConfigStoreOptions {
  environment?: Readonly<Record<string, string | undefined>>;
  store?: ProviderConfigStore;
  preferConfig?: boolean;
}

/**
 * Shared resolution for catalog `config.kind === "api_key"` providers:
 * 1. Owner-only `providers.json`
 * 2. Environment keys (first non-empty wins)
 */
export async function resolveApiKeyCredentials(
  config: ApiKeyResolveConfig,
  options: ResolveApiKeyOptions = {},
): Promise<ApiKeyCredentials | undefined> {
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
      const stored = await store.get(config.provider);
      if (stored?.api_key) {
        const baseUrl = resolveBaseUrl(stored.base_url, environment, config);
        if (!baseUrl) {
          return undefined;
        }
        return {
          apiKey: stored.api_key,
          label: maskApiKey(stored.api_key, config.maskLabel),
          source: `config:${config.provider}`,
          baseUrl,
        };
      }
    } catch {
      // Unreadable config falls through to env.
    }
  }

  for (const envKey of config.envKeys) {
    const raw = environment[envKey]?.trim();
    if (!raw) {
      continue;
    }
    const baseUrl = resolveBaseUrl(undefined, environment, config);
    if (!baseUrl) {
      return undefined;
    }
    return {
      apiKey: raw,
      label: maskApiKey(raw, config.maskLabel),
      source: `env:${envKey}`,
      baseUrl,
    };
  }

  return undefined;
}

export function maskApiKey(apiKey: string, label = "API"): string {
  const trimmed = apiKey.trim();
  if (trimmed.length <= 8) {
    return `${label} key`;
  }
  return `${label} ···${trimmed.slice(-4)}`;
}

export function normalizeBaseUrl(
  value: string | undefined,
  options: { allowPrivateHttp?: boolean } = {},
): string | undefined {
  if (!value) {
    return undefined;
  }
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) {
    return undefined;
  }
  try {
    const url = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    if (url.username || url.password) {
      return undefined;
    }
    if (url.protocol === "https:") {
      return `${url.origin}${url.pathname}`.replace(/\/+$/, "") || url.origin;
    }
    if (
      url.protocol === "http:" &&
      options.allowPrivateHttp &&
      isPrivateOrLocalHost(url.hostname)
    ) {
      return `${url.origin}${url.pathname}`.replace(/\/+$/, "") || url.origin;
    }
    return undefined;
  } catch {
    return undefined;
  }
}

/** Strip a trailing `/v1` management-root quirk (LiteLLM). */
export function stripTrailingV1(baseUrl: string): string {
  return baseUrl.replace(/\/v1\/?$/i, "");
}

function resolveBaseUrl(
  storedBaseUrl: string | undefined,
  environment: Readonly<Record<string, string | undefined>>,
  config: ApiKeyResolveConfig,
): string | undefined {
  const allowPrivateHttp = config.allowPrivateHttp === true;
  if (storedBaseUrl !== undefined && config.urlEnvKey) {
    // Custom endpoints are explicit routing choices and fail closed when invalid.
    return normalizeBaseUrl(storedBaseUrl, { allowPrivateHttp });
  }
  if (config.urlEnvKey) {
    const fromEnv = normalizeBaseUrl(environment[config.urlEnvKey], { allowPrivateHttp });
    if (fromEnv) {
      return fromEnv;
    }
  }
  if (config.defaultBaseUrl) {
    return config.defaultBaseUrl;
  }
  if (config.requireBaseUrl) {
    return undefined;
  }
  return undefined;
}

function isPrivateOrLocalHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host === "127.0.0.1" || host === "::1") {
    return true;
  }
  if (host.endsWith(".local")) {
    return true;
  }
  if (/^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) {
    return true;
  }
  if (/^192\.168\.\d{1,3}\.\d{1,3}$/.test(host)) {
    return true;
  }
  if (/^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$/.test(host)) {
    return true;
  }
  if (/^169\.254\.\d{1,3}\.\d{1,3}$/.test(host)) {
    return true;
  }
  // Unique-local IPv6 fc00::/7
  if (/^f[cd][0-9a-f]{2}:/i.test(host)) {
    return true;
  }
  return false;
}
