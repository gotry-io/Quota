import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { authRequiredMessage } from "../../catalog.ts";
import {
  type CollectionContext,
  ProviderCollectionError,
  type ProviderCollector,
  type ProviderSession,
} from "../../contracts.ts";
import {
  createFetchTransport,
  HttpRequestError,
  type HttpTransport,
  readJsonObject,
} from "../../runtime/http.ts";
import {
  OPENROUTER_SOURCE_API,
  type OpenRouterCredentials,
  resolveOpenRouterCredentials,
} from "./credentials.ts";
import {
  buildOpenRouterSnapshot,
  mapOpenRouterCreditsResponse,
  mapOpenRouterKeyResponse,
  mapOpenRouterWindows,
  type OpenRouterKeyData,
} from "./map.ts";

export interface OpenRouterCollectorOptions {
  environment?: Readonly<Record<string, string | undefined>>;
  transport?: HttpTransport;
  clientVersion?: string;
  /** Absolute path override for provider config (tests). */
  configPath?: string;
}

export class OpenRouterCollector implements ProviderCollector {
  readonly provider = "openrouter" as const;
  private readonly environment: Readonly<Record<string, string | undefined>>;
  private readonly transport: HttpTransport;
  private readonly clientVersion: string;
  private readonly configPath?: string;

  constructor(options: OpenRouterCollectorOptions = {}) {
    this.environment = options.environment ?? process.env;
    this.transport = options.transport ?? createFetchTransport();
    this.clientVersion = options.clientVersion ?? "QuotaCLI";
    if (options.configPath !== undefined) {
      this.configPath = options.configPath;
    }
  }

  async discover(): Promise<ProviderSession[]> {
    const credentials = await this.resolveCredentials();
    if (!credentials) {
      return [];
    }
    return [
      {
        provider: "openrouter",
        session_id: "ambient",
        display_label: credentials.label,
        credential_source: credentials.source,
      },
    ];
  }

  async collect(
    _session: ProviderSession,
    context: CollectionContext = {},
  ): Promise<QuotaSnapshot> {
    const credentials = await this.resolveCredentials();
    if (!credentials) {
      throw new ProviderCollectionError(
        "auth_required",
        authRequiredMessage("openrouter"),
        OPENROUTER_SOURCE_API,
      );
    }

    const creditsJson = await this.fetchJson(
      `${credentials.baseUrl}/credits`,
      credentials,
      context.signal,
    );
    const credits = mapOpenRouterCreditsResponse(creditsJson);
    if (!credits) {
      throw new ProviderCollectionError(
        "error",
        "OpenRouter credits response was malformed.",
        OPENROUTER_SOURCE_API,
      );
    }

    // Best-effort: credits alone still form a usable snapshot.
    let keyData: OpenRouterKeyData | undefined;
    try {
      const keyJson = await this.fetchJson(
        `${credentials.baseUrl}/key`,
        credentials,
        context.signal,
        false,
      );
      keyData = keyJson !== undefined ? mapOpenRouterKeyResponse(keyJson) : undefined;
    } catch {
      keyData = undefined;
    }

    const windows = mapOpenRouterWindows(credits, keyData);
    if (windows.length === 0) {
      throw new ProviderCollectionError(
        "error",
        "OpenRouter returned no usable credit or key-limit quota.",
        OPENROUTER_SOURCE_API,
      );
    }

    return buildOpenRouterSnapshot({
      windows,
      credentials,
      ...(context.now ? { now: context.now } : {}),
    });
  }

  private resolveCredentials() {
    return resolveOpenRouterCredentials({
      environment: this.environment,
      ...(this.configPath ? { path: this.configPath } : {}),
    });
  }

  private async fetchJson(
    url: string,
    credentials: OpenRouterCredentials,
    signal: AbortSignal | undefined,
    required = true,
  ): Promise<unknown> {
    try {
      const request: Parameters<typeof readJsonObject>[1] = {
        url,
        method: "GET",
        headers: {
          Authorization: `Bearer ${credentials.apiKey}`,
          Accept: "application/json",
          "X-Title": this.clientVersion,
        },
      };
      if (signal) {
        request.signal = signal;
      }
      const { status, json } = await readJsonObject(this.transport, request);
      if (status === 401 || status === 403) {
        throw new ProviderCollectionError(
          "auth_required",
          "OpenRouter rejected the API key. Update the saved key or `OPENROUTER_API_KEY`.",
          OPENROUTER_SOURCE_API,
        );
      }
      if (status === 429) {
        throw new ProviderCollectionError(
          "unavailable",
          "OpenRouter rate limited the request.",
          OPENROUTER_SOURCE_API,
        );
      }
      if (status < 200 || status >= 300) {
        if (!required) {
          return undefined;
        }
        throw new ProviderCollectionError(
          "unavailable",
          `OpenRouter request failed (HTTP ${status}).`,
          OPENROUTER_SOURCE_API,
        );
      }
      return json;
    } catch (error) {
      if (error instanceof ProviderCollectionError) {
        throw error;
      }
      if (error instanceof HttpRequestError) {
        if (error.status === 401 || error.status === 403) {
          throw new ProviderCollectionError(
            "auth_required",
            "OpenRouter rejected the API key. Update the saved key or `OPENROUTER_API_KEY`.",
            OPENROUTER_SOURCE_API,
          );
        }
        if (!required) {
          return undefined;
        }
        throw new ProviderCollectionError(
          "unavailable",
          "OpenRouter is unreachable.",
          OPENROUTER_SOURCE_API,
        );
      }
      if (!required) {
        return undefined;
      }
      throw error;
    }
  }
}
