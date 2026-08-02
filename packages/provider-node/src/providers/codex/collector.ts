import { homedir } from "node:os";
import {
  ProviderCollectionError,
  type CollectionContext,
  type ProviderCollector,
  type ProviderSession,
} from "@gotry-io/provider-core";
import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { classifyProviderError } from "../../runtime/errors.ts";
import {
  createFetchTransport,
  type HttpTransport,
  HttpRequestError,
  readJsonObject,
} from "../../runtime/http.ts";
import {
  CODEX_RPC_INITIALIZE_TIMEOUT_MS,
  CODEX_RPC_REQUEST_TIMEOUT_MS,
} from "../../runtime/limits.ts";
import { JsonRpcClient, resolveExecutable } from "../../runtime/process.ts";
import {
  extractCodexIdentity,
  loadCodexCredentials,
  type CodexCredentials,
} from "./credentials.ts";
import {
  buildCodexSnapshot,
  CODEX_SOURCE_API,
  CODEX_SOURCE_RPC,
  CODEX_USAGE_URL,
  mapCodexRpcRateLimits,
  mapCodexUsageResponse,
} from "./map.ts";

export interface CodexCollectorOptions {
  clientVersion?: string;
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  transport?: HttpTransport;
  resolveCodexExecutable?: (
    environment: Readonly<Record<string, string | undefined>>,
  ) => Promise<string | undefined>;
  readJson?: (path: string) => Promise<unknown | undefined>;
}

export class CodexCollector implements ProviderCollector {
  readonly provider = "codex" as const;
  private readonly homeDirectory: string;
  private readonly clientVersion: string;
  private readonly environment: Readonly<Record<string, string | undefined>>;
  private readonly transport: HttpTransport;
  private readonly resolveCodexExecutable: NonNullable<
    CodexCollectorOptions["resolveCodexExecutable"]
  >;
  private readonly readJson: CodexCollectorOptions["readJson"];

  constructor(options: CodexCollectorOptions = {}) {
    this.homeDirectory = options.homeDirectory ?? homedir();
    this.clientVersion = options.clientVersion ?? "development";
    this.environment = options.environment ?? process.env;
    this.transport = options.transport ?? createFetchTransport();
    this.resolveCodexExecutable =
      options.resolveCodexExecutable ??
      (async (environment) => await resolveExecutable("codex", environment));
    this.readJson = options.readJson;
  }

  async discover(): Promise<ProviderSession[]> {
    const credentials = await loadCodexCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      ...(this.readJson ? { readJson: this.readJson } : {}),
    });
    if (!credentials) {
      return [];
    }
    return [
      {
        provider: "codex",
        session_id: "ambient",
        display_label: "Codex",
        credential_source: credentials.sourcePath,
      },
    ];
  }

  async collect(
    _session: ProviderSession,
    context: CollectionContext = {},
  ): Promise<QuotaSnapshot> {
    const credentials = await loadCodexCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      ...(this.readJson ? { readJson: this.readJson } : {}),
    });
    if (!credentials) {
      throw new ProviderCollectionError(
        "auth_required",
        "Codex auth.json not found. Run `codex` to log in.",
        CODEX_SOURCE_API,
      );
    }

    const identity = extractCodexIdentity(credentials);
    const now = context.now ?? new Date();

    try {
      const apiSnapshot = await this.collectViaApi(credentials, identity, now, context.signal);
      if (apiSnapshot) {
        return apiSnapshot;
      }
    } catch (error) {
      const classified = classifyProviderError(error);
      // Fallback only for unusable/transient direct OAuth results.
      // Auth failures and malformed successful payloads must not hide behind RPC.
      if (classified.category === "auth_required" || classified.category === "error") {
        throw new ProviderCollectionError(
          classified.category,
          classified.message,
          classified.source ?? CODEX_SOURCE_API,
        );
      }
      // continue to RPC fallback for unavailable
    }

    return await this.collectViaRpc(identity, now, context.signal);
  }

  private async collectViaApi(
    credentials: CodexCredentials,
    identity: { email?: string; plan?: string; accountId?: string },
    now: Date,
    signal?: AbortSignal,
  ): Promise<QuotaSnapshot | undefined> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${credentials.accessToken}`,
      Accept: "application/json",
    };
    const accountId = identity.accountId ?? credentials.accountId;
    if (accountId) {
      headers["ChatGPT-Account-Id"] = accountId;
    }

    const { status, json } = await readJsonObject(this.transport, {
      url: CODEX_USAGE_URL,
      headers,
      ...(signal ? { signal } : {}),
    });

    if (status === 401 || status === 403) {
      throw new ProviderCollectionError(
        "auth_required",
        "Codex OAuth token expired or invalid. Run `codex` to re-authenticate.",
        CODEX_SOURCE_API,
      );
    }
    if (status < 200 || status >= 300) {
      throw new HttpRequestError(`Codex usage API returned HTTP ${status}.`, status);
    }

    const mapped = mapCodexUsageResponse(json, now);
    if (mapped.malformedSuccess) {
      // Do not hide parser bugs behind RPC fallback.
      throw new ProviderCollectionError(
        "error",
        "Codex usage API returned a malformed rate-limit payload.",
        CODEX_SOURCE_API,
      );
    }
    if (!mapped.usable) {
      return undefined;
    }

    const resolvedPlan = mapped.plan ?? identity.plan;
    const resolvedEmail = mapped.email ?? identity.email;
    const resolvedAccountId = mapped.accountId ?? accountId;
    return buildCodexSnapshot({
      source: CODEX_SOURCE_API,
      windows: mapped.windows,
      now,
      ...(resolvedPlan ? { plan: resolvedPlan } : {}),
      ...(resolvedEmail ? { email: resolvedEmail } : {}),
      ...(resolvedAccountId ? { accountId: resolvedAccountId } : {}),
    });
  }

  private async collectViaRpc(
    identity: { email?: string; plan?: string; accountId?: string },
    now: Date,
    signal?: AbortSignal,
  ): Promise<QuotaSnapshot> {
    const executable = await this.resolveCodexExecutable(this.environment);
    if (!executable) {
      throw new ProviderCollectionError(
        "unavailable",
        "Codex CLI not found for app-server fallback.",
        CODEX_SOURCE_RPC,
      );
    }

    const client = new JsonRpcClient({
      executable,
      args: ["-s", "read-only", "-a", "untrusted", "app-server"],
      environment: this.environment,
      initializeTimeoutMs: CODEX_RPC_INITIALIZE_TIMEOUT_MS,
      requestTimeoutMs: CODEX_RPC_REQUEST_TIMEOUT_MS,
      ...(signal ? { signal } : {}),
    });

    try {
      await client.initialize("initialize", {
        clientInfo: { name: "quotacli", version: this.clientVersion },
      });
      await client.request({ method: "initialized", notification: true });

      const rateLimits = await client.request({
        method: "account/rateLimits/read",
        timeoutMs: CODEX_RPC_REQUEST_TIMEOUT_MS,
      });
      let accountEmail = identity.email;
      let accountPlan = identity.plan;
      try {
        const account = await client.request({
          method: "account/read",
          timeoutMs: CODEX_RPC_REQUEST_TIMEOUT_MS,
        });
        const parsedAccount = parseRpcAccount(account);
        accountEmail = accountEmail ?? parsedAccount.email;
        accountPlan = accountPlan ?? parsedAccount.plan;
      } catch {
        // Identity enrichment is best-effort.
      }

      const mapped = mapCodexRpcRateLimits(rateLimits);
      if (!mapped.usable) {
        throw new ProviderCollectionError(
          "unavailable",
          "Codex app-server did not return rate limits.",
          CODEX_SOURCE_RPC,
        );
      }

      return buildCodexSnapshot({
        source: CODEX_SOURCE_RPC,
        windows: mapped.windows,
        now,
        ...((mapped.plan ?? accountPlan) ? { plan: mapped.plan ?? accountPlan } : {}),
        ...(accountEmail ? { email: accountEmail } : {}),
        ...(identity.accountId ? { accountId: identity.accountId } : {}),
      });
    } catch (error) {
      const classified = classifyProviderError(error);
      throw new ProviderCollectionError(
        classified.category,
        classified.message,
        classified.source ?? CODEX_SOURCE_RPC,
      );
    } finally {
      client.shutdown();
    }
  }
}

function parseRpcAccount(value: unknown): { email?: string; plan?: string } {
  if (!value || typeof value !== "object") {
    return {};
  }
  const root = value as Record<string, unknown>;
  const account = root.account;
  if (!account || typeof account !== "object") {
    return {};
  }
  const details = account as Record<string, unknown>;
  // Shape variants: { type: "chatgpt", email, plan } or nested chatgpt object.
  const email =
    (typeof details.email === "string" && details.email) ||
    (typeof (details.chatgpt as { email?: string } | undefined)?.email === "string"
      ? (details.chatgpt as { email?: string }).email
      : undefined);
  const plan =
    (typeof details.plan === "string" && details.plan) ||
    (typeof details.planType === "string" && details.planType) ||
    (typeof (details.chatgpt as { plan?: string } | undefined)?.plan === "string"
      ? (details.chatgpt as { plan?: string }).plan
      : undefined);
  return {
    ...(email ? { email } : {}),
    ...(plan ? { plan } : {}),
  };
}
