import { aggregateUsageEvents, calculateUsageCost, foldUsageFacts } from "@gotry-io/quota-model";
import {
  BILLING_AGENTS,
  type BillingAgent,
  IanaTimezoneSchema,
  type LocalUsageReport,
  LocalUsageReportSchema,
  type PricingCatalog,
  PROTOCOL_VERSION,
  type UsageBreakdown,
  type UsageHourlyFact,
} from "@gotry-io/quota-protocol";
import { scanLocalUsage, type UsageScanResult } from "@gotry-io/quota-provider";
import { loadPricingCatalogCache } from "./pricing-cache.ts";
import type { AccountStateStore } from "./state.ts";

const ALL_USAGE_START = "1970-01-01T00:00:00Z";

export interface LocalUsageDependencies {
  aggregationTimezone(): string;
  pricingCatalog(): Promise<PricingCatalog | null>;
  scan(agent: BillingAgent, startAt: string, endAt: string): Promise<UsageScanResult>;
}

export async function collectLocalUsage(
  now: Date,
  dependencies: LocalUsageDependencies,
): Promise<LocalUsageReport> {
  const generatedAt = now.toISOString();
  let timezone: string;
  let range: { from: string; to: string };
  try {
    timezone = IanaTimezoneSchema.parse(dependencies.aggregationTimezone());
    range = { from: localDate(now, timezone), to: localDate(now, timezone) };
  } catch {
    const today = now.toISOString().slice(0, 10);
    return unavailableReport(generatedAt, { from: today, to: today });
  }

  const startAt = ALL_USAGE_START;
  const endAt = nextUtcHour(now);
  const [catalog, scans] = await Promise.all([
    dependencies.pricingCatalog().catch(() => null),
    Promise.all(
      BILLING_AGENTS.map((agent) => dependencies.scan(agent, startAt, endAt).catch(() => null)),
    ),
  ]);
  if (scans.every((scan) => scan === null)) {
    return unavailableReport(generatedAt, range);
  }

  const coverage = BILLING_AGENTS.map((agent, index) => {
    const scan = scans[index]!;
    return scan === null
      ? { agent, start_at: startAt, end_at: endAt, status: "partial" as const }
      : {
          agent,
          start_at: scan.coverage.start_at,
          end_at: scan.coverage.end_at,
          // The current UTC hour is still open, so a local point-in-time report is a lower bound.
          status: "partial" as const,
        };
  });
  const rows = aggregateUsageEvents(
    scans.flatMap((scan) => scan?.records.map((record) => record.event) ?? []),
    timezone,
  );
  if (rows.length > 0) {
    range = {
      from: rows.reduce(
        (earliest, row) => (row.usage_date < earliest ? row.usage_date : earliest),
        rows[0]?.usage_date ?? range.from,
      ),
      to: range.to,
    };
  }

  return LocalUsageReportSchema.parse({
    protocol_version: PROTOCOL_VERSION,
    generated_at: generatedAt,
    aggregation_timezone: timezone,
    range,
    status: "partial",
    totals: foldUsageFacts(rows),
    cost: calculateUsageCost(rows, catalog),
    coverage,
    breakdowns: agentBreakdowns(rows, catalog),
  });
}

export function defaultLocalUsageDependencies(store: AccountStateStore): LocalUsageDependencies {
  return {
    aggregationTimezone: () => Intl.DateTimeFormat().resolvedOptions().timeZone,
    pricingCatalog: async () => (await loadPricingCatalogCache(store))?.catalog ?? null,
    scan: async (agent, startAt, endAt) => await scanLocalUsage(agent, { startAt, endAt }),
  };
}

function agentBreakdowns(
  rows: readonly UsageHourlyFact[],
  catalog: PricingCatalog | null,
): UsageBreakdown[] {
  return BILLING_AGENTS.flatMap((agent) => {
    const matching = rows.filter((row) => row.agent === agent);
    return matching.length === 0
      ? []
      : [
          {
            dimension: "agent" as const,
            key: agent,
            totals: foldUsageFacts(matching),
            cost: calculateUsageCost(matching, catalog),
          },
        ];
  });
}

function unavailableReport(
  generatedAt: string,
  range: { from: string; to: string },
): LocalUsageReport {
  return LocalUsageReportSchema.parse({
    protocol_version: PROTOCOL_VERSION,
    generated_at: generatedAt,
    aggregation_timezone: null,
    range,
    status: "unavailable",
    totals: null,
    cost: null,
    coverage: [],
    breakdowns: [],
  });
}

function localDate(value: Date, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(value);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((item) => item.type === type)?.value;
  const year = part("year");
  const month = part("month");
  const day = part("day");
  if (!year || !month || !day) throw new TypeError("Could not resolve the local Usage date.");
  return `${year}-${month}-${day}`;
}

function nextUtcHour(value: Date): string {
  const hour = 3_600_000;
  return new Date(Math.floor(value.getTime() / hour) * hour + hour)
    .toISOString()
    .replace(".000Z", "Z");
}
