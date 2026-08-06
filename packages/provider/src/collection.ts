import {
  PROTOCOL_VERSION,
  type ProviderId,
  type QuotaCollectionReport,
  QuotaCollectionReportSchema,
  type QuotaCollectionResult,
  type QuotaSnapshot,
} from "@gotry-io/quota-protocol";
import { authRequiredMessage } from "./catalog.ts";
import type { CollectionContext, ProviderCollectionError, ProviderCollector } from "./contracts.ts";
import {
  type CollectorFactoryOptions,
  createDefaultCollectors,
  PROVIDER_ORDER,
  resolveProviders,
} from "./registry.ts";
import { classifyProviderError, sanitizeMessage } from "./runtime/errors.ts";
import { toIsoOffset } from "./runtime/time.ts";

export interface CollectQuotaOptions extends CollectorFactoryOptions {
  providers?: "all" | ProviderId | ProviderId[];
  collectors?: Partial<Record<ProviderId, ProviderCollector>>;
  context?: CollectionContext;
  now?: Date;
}

export async function collectQuotaReport(
  options: CollectQuotaOptions = {},
): Promise<QuotaCollectionReport> {
  // Freeze only for tests/tooling. Production must not inject a shared now —
  // each provider stamps observed_at near successful payload mapping.
  const frozenNow = options.now ?? options.context?.now;
  const providerIds = resolveProviders(options.providers ?? "all");
  const factoryOptions: CollectorFactoryOptions = {
    ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    ...(options.codex ? { codex: options.codex } : {}),
    ...(options.claude ? { claude: options.claude } : {}),
    ...(options.grok ? { grok: options.grok } : {}),
    ...(options.openrouter ? { openrouter: options.openrouter } : {}),
  };
  const defaults = createDefaultCollectors(factoryOptions);
  const collectors = {} as Record<ProviderId, ProviderCollector>;
  for (const id of PROVIDER_ORDER) {
    collectors[id] = options.collectors?.[id] ?? defaults[id];
  }

  const results: QuotaCollectionResult[] = await Promise.all(
    providerIds.map(async (provider) => {
      const context: CollectionContext = {};
      if (options.context?.signal) {
        context.signal = options.context.signal;
      }
      if (frozenNow) {
        context.now = frozenNow;
      }
      return await collectOne(collectors[provider], context);
    }),
  );

  // Batch assembly time (end of collection), not per-provider data age.
  const capturedAt = frozenNow ?? new Date();
  const report = {
    schema_version: PROTOCOL_VERSION,
    captured_at: toIsoOffset(capturedAt),
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

export function collectionExitCode(report: QuotaCollectionReport): number {
  const allFresh = report.results.every(
    (result) =>
      result.outcome === "success" &&
      result.snapshots.some((snapshot) => snapshot.status === "available"),
  );
  return allFresh ? 0 : 1;
}
