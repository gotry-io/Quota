import type { ProviderId, QuotaSnapshot } from "@gotry-io/quota-protocol";
import { authRequiredMessage } from "../catalog.ts";
import {
  type CollectionContext,
  ProviderCollectionError,
  type ProviderCollector,
  type ProviderSession,
} from "../contracts.ts";
import { createFetchTransport, type HttpTransport } from "../runtime/http.ts";
import type { ApiKeyCredentials, ApiKeyResolveConfig } from "./resolve.ts";
import { resolveApiKeyCredentials } from "./resolve.ts";

export interface ApiKeyCollectContext {
  credentials: ApiKeyCredentials;
  transport: HttpTransport;
  clientVersion: string;
  signal?: AbortSignal;
  now?: Date;
}

export interface ApiKeyHttpCollectorSpec extends ApiKeyResolveConfig {
  source: string;
  collect(ctx: ApiKeyCollectContext): Promise<QuotaSnapshot>;
}

export interface ApiKeyHttpCollectorOptions {
  environment?: Readonly<Record<string, string | undefined>>;
  transport?: HttpTransport;
  clientVersion?: string;
  configPath?: string;
}

/** Shared discover/collect shell for API-key HTTPS providers. */
export class ApiKeyHttpCollector implements ProviderCollector {
  readonly provider: ProviderId;
  private readonly spec: ApiKeyHttpCollectorSpec;
  private readonly environment: Readonly<Record<string, string | undefined>>;
  private readonly transport: HttpTransport;
  private readonly clientVersion: string;
  private readonly configPath?: string;

  constructor(spec: ApiKeyHttpCollectorSpec, options: ApiKeyHttpCollectorOptions = {}) {
    this.spec = spec;
    this.provider = spec.provider;
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
        provider: this.provider,
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
        authRequiredMessage(this.provider),
        this.spec.source,
      );
    }
    return await this.spec.collect({
      credentials,
      transport: this.transport,
      clientVersion: this.clientVersion,
      ...(context.signal ? { signal: context.signal } : {}),
      ...(context.now ? { now: context.now } : {}),
    });
  }

  private resolveCredentials() {
    return resolveApiKeyCredentials(this.spec, {
      environment: this.environment,
      ...(this.configPath ? { path: this.configPath } : {}),
    });
  }
}
