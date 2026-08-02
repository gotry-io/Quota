import { homedir } from "node:os";
import {
  type CollectionContext,
  ProviderCollectionError,
  type ProviderCollector,
  type ProviderSession,
} from "@gotry-io/provider-core";
import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { classifyProviderError } from "../../runtime/errors.ts";
import {
  createFetchTransport,
  HttpRequestError,
  type HttpTransport,
  readJsonObject,
} from "../../runtime/http.ts";
import { GROK_SOURCE_API, type GrokCredentials, loadGrokCredentials } from "./credentials.ts";
import { buildGrokSnapshot, mapGrokBillingResponse } from "./map.ts";

export const GROK_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";

export interface GrokCollectorOptions {
  clientVersion?: string;
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  transport?: HttpTransport;
  readJson?: (path: string) => Promise<unknown | undefined>;
}

export class GrokCollector implements ProviderCollector {
  readonly provider = "grok" as const;
  private readonly clientVersion: string;
  private readonly homeDirectory: string;
  private readonly environment: Readonly<Record<string, string | undefined>>;
  private readonly transport: HttpTransport;
  private readonly readJson: GrokCollectorOptions["readJson"];

  constructor(options: GrokCollectorOptions = {}) {
    this.clientVersion = options.clientVersion ?? "development";
    this.homeDirectory = options.homeDirectory ?? homedir();
    this.environment = options.environment ?? process.env;
    this.transport = options.transport ?? createFetchTransport();
    this.readJson = options.readJson;
  }

  async discover(): Promise<ProviderSession[]> {
    const credentials = await loadGrokCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      ...(this.readJson ? { readJson: this.readJson } : {}),
    });
    if (!credentials) {
      return [];
    }
    return [
      {
        provider: "grok",
        session_id: "ambient",
        display_label: "Grok",
        credential_source: credentials.sourcePath,
      },
    ];
  }

  async collect(
    _session: ProviderSession,
    context: CollectionContext = {},
  ): Promise<QuotaSnapshot> {
    const credentials = await loadGrokCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      ...(this.readJson ? { readJson: this.readJson } : {}),
    });
    if (!credentials) {
      throw new ProviderCollectionError(
        "auth_required",
        "Grok auth.json not found. Run `grok login`.",
        GROK_SOURCE_API,
      );
    }
    const now = context.now ?? new Date();

    try {
      const billing = await this.fetchBillingApi(credentials, context.signal);
      const mapped = mapGrokBillingResponse(billing);
      if (!mapped.usable || !mapped.window) {
        throw new ProviderCollectionError(
          "error",
          "Grok billing API returned a malformed quota payload.",
          GROK_SOURCE_API,
        );
      }
      return buildGrokSnapshot({
        window: mapped.window,
        credentials,
        now,
      });
    } catch (error) {
      const classified = classifyProviderError(error);
      throw new ProviderCollectionError(
        classified.category,
        classified.message,
        classified.source ?? GROK_SOURCE_API,
      );
    }
  }

  private async fetchBillingApi(
    credentials: GrokCredentials,
    signal?: AbortSignal,
  ): Promise<unknown> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${credentials.accessToken}`,
      Accept: "application/json",
      "X-XAI-Token-Auth": "xai-grok-cli",
      "User-Agent": `QuotaCLI/${this.clientVersion}`,
    };
    if (credentials.userId) {
      headers["x-userid"] = credentials.userId;
    }

    const { status, json } = await readJsonObject(this.transport, {
      url: GROK_BILLING_URL,
      headers,
      ...(signal ? { signal } : {}),
    });
    if (status === 401 || status === 403) {
      throw new ProviderCollectionError(
        "auth_required",
        "Grok login expired or is invalid. Run `grok login` to re-authenticate.",
        GROK_SOURCE_API,
      );
    }
    if (status === 429) {
      throw new ProviderCollectionError(
        "unavailable",
        "Grok billing endpoint is rate limited. Wait a few minutes and retry.",
        GROK_SOURCE_API,
      );
    }
    if (status < 200 || status >= 300) {
      throw new HttpRequestError(`Grok billing API returned HTTP ${status}.`, status);
    }
    return json;
  }
}
