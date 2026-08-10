import { aggregateUsageEvents, calculateUsageCost, foldUsageFacts } from "@gotry-io/quota-model";
import {
  type BillingAgent,
  IanaTimezoneSchema,
  type LocalUsageReport,
  LocalUsageReportSchema,
  type PricingCatalog,
  PROTOCOL_VERSION,
  type UsageBreakdown,
  type UsageHourlyFact,
} from "@gotry-io/quota-protocol";
import { scanClaudeUsage, scanCodexUsage, type UsageScanResult } from "@gotry-io/quota-provider";
import { loadPricingCatalogCache } from "./pricing-cache.ts";
import type { AccountStateStore } from "./state.ts";

const LOCAL_USAGE_DAYS = 30;
const USAGE_AGENTS = ["codex", "claude_code"] as const;

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
    range = localDateRange(now, timezone);
  } catch {
    return unavailableReport(generatedAt, utcDateRange(now));
  }

  const startAt = `${previousDate(range.from)}T00:00:00Z`;
  const endAt = nextUtcHour(now);
  const [catalog, scans] = await Promise.all([
    dependencies.pricingCatalog().catch(() => null),
    Promise.all(
      USAGE_AGENTS.map((agent) => dependencies.scan(agent, startAt, endAt).catch(() => null)),
    ),
  ]);
  if (scans.every((scan) => scan === null)) {
    return unavailableReport(generatedAt, range);
  }

  const coverage = USAGE_AGENTS.map((agent, index) => {
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
  ).filter((row) => row.usage_date >= range.from && row.usage_date <= range.to);

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
    scan: async (agent, startAt, endAt) =>
      agent === "codex"
        ? await scanCodexUsage({ startAt, endAt })
        : await scanClaudeUsage({ startAt, endAt }),
  };
}

function agentBreakdowns(
  rows: readonly UsageHourlyFact[],
  catalog: PricingCatalog | null,
): UsageBreakdown[] {
  return USAGE_AGENTS.flatMap((agent) => {
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

function localDateRange(now: Date, timezone: string): { from: string; to: string } {
  const to = localDate(now, timezone);
  const anchor = Date.parse(`${to}T12:00:00Z`);
  return {
    from: new Date(anchor - (LOCAL_USAGE_DAYS - 1) * 86_400_000).toISOString().slice(0, 10),
    to,
  };
}

function utcDateRange(now: Date): { from: string; to: string } {
  const to = now.toISOString().slice(0, 10);
  const anchor = Date.parse(`${to}T12:00:00Z`);
  return {
    from: new Date(anchor - (LOCAL_USAGE_DAYS - 1) * 86_400_000).toISOString().slice(0, 10),
    to,
  };
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

function previousDate(value: string): string {
  return new Date(Date.parse(`${value}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
}

function nextUtcHour(value: Date): string {
  const hour = 3_600_000;
  return new Date(Math.floor(value.getTime() / hour) * hour + hour)
    .toISOString()
    .replace(".000Z", "Z");
}
