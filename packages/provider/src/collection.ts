import {
  ProviderCollectionError,
  type CollectionContext,
  type ProviderCollector,
} from "./contracts.ts";
import {
  PROTOCOL_VERSION,
  QuotaCollectionReportSchema,
  type ProviderId,
  type QuotaCollectionReport,
  type QuotaCollectionResult,
  type QuotaSnapshot,
} from "@gotry-io/quota-protocol";
import { classifyProviderError, sanitizeMessage } from "./runtime/errors.ts";
import { toIsoOffset } from "./runtime/time.ts";
import {
  createDefaultCollectors,
  resolveProviders,
  type CollectorFactoryOptions,
} from "./registry.ts";

export interface CollectQuotaOptions extends CollectorFactoryOptions {
  providers?: "all" | ProviderId | ProviderId[];
  collectors?: Partial<Record<ProviderId, ProviderCollector>>;
  context?: CollectionContext;
  now?: Date;
}

export async function collectQuotaReport(
  options: CollectQuotaOptions = {},
): Promise<QuotaCollectionReport> {
  const now = options.now ?? options.context?.now ?? new Date();
  const providerIds = resolveProviders(options.providers ?? "all");
  const factoryOptions: CollectorFactoryOptions = {};
  if (options.codex) {
    factoryOptions.codex = options.codex;
  }
  if (options.claude) {
    factoryOptions.claude = options.claude;
  }
  if (options.grok) {
    factoryOptions.grok = options.grok;
  }
  if (options.clientVersion) {
    factoryOptions.clientVersion = options.clientVersion;
  }
  const defaults = createDefaultCollectors(factoryOptions);
  const collectors: Record<ProviderId, ProviderCollector> = {
    codex: options.collectors?.codex ?? defaults.codex,
    claude: options.collectors?.claude ?? defaults.claude,
    grok: options.collectors?.grok ?? defaults.grok,
  };

  const results: QuotaCollectionResult[] = await Promise.all(
    providerIds.map(async (provider) => {
      const context: CollectionContext = { now };
      if (options.context?.signal) {
        context.signal = options.context.signal;
      }
      return await collectOne(collectors[provider], context);
    }),
  );

  const report = {
    schema_version: PROTOCOL_VERSION,
    captured_at: toIsoOffset(now),
    results,
  };
  return QuotaCollectionReportSchema.parse(report);
}

async function collectOne(
  collector: ProviderCollector,
  context: CollectionContext,
): Promise<QuotaCollectionResult> {
  try {
    const sessions = await collector.discover();
    if (sessions.length === 0) {
      return {
        provider: collector.provider,
        outcome: "auth_required",
        snapshots: [],
        message: authRequiredMessage(collector.provider),
      };
    }

    const snapshots: QuotaSnapshot[] = [];
    let lastError: ProviderCollectionError | undefined;
    for (const session of sessions) {
      try {
        const snapshot = await collector.collect(session, context);
        snapshots.push(snapshot);
      } catch (error) {
        lastError = classifyProviderError(error);
      }
    }

    if (snapshots.length > 0) {
      const source = snapshots[0]?.source;
      return {
        provider: collector.provider,
        outcome: "success",
        snapshots,
        ...(source ? { source } : {}),
      };
    }

    if (lastError) {
      return {
        provider: collector.provider,
        outcome: lastError.category,
        snapshots: [],
        ...(lastError.source ? { source: lastError.source } : {}),
        message: sanitizeMessage(lastError.message),
      };
    }

    return {
      provider: collector.provider,
      outcome: "unavailable",
      snapshots: [],
      message: "No quota snapshots were collected.",
    };
  } catch (error) {
    const classified = classifyProviderError(error);
    return {
      provider: collector.provider,
      outcome: classified.category,
      snapshots: [],
      ...(classified.source ? { source: classified.source } : {}),
      message: sanitizeMessage(classified.message),
    };
  }
}

function authRequiredMessage(provider: ProviderId): string {
  switch (provider) {
    case "codex":
      return "Codex auth.json not found. Run `codex` to log in.";
    case "claude":
      return "Claude OAuth credentials are missing or unreadable. Run `claude auth login`.";
    case "grok":
      return "Grok auth.json not found. Run `grok login`.";
  }
}

export function collectionExitCode(report: QuotaCollectionReport): number {
  const allFresh = report.results.every(
    (result) =>
      result.outcome === "success" &&
      result.snapshots.some((snapshot) => snapshot.status === "available"),
  );
  return allFresh ? 0 : 1;
}
