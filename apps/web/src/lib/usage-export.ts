/**
 * CSV / JSON for the Usage period already on screen. The website and QuotaBar both answer
 * `packages/protocol/fixtures/usage-export-conformance.json`. See ADR 0056.
 */

export const USAGE_EXPORT_CSV_HEADER =
  "date,total tokens,input,output,cache read,cache write,reasoning,messages,API-equivalent cost,cost status";

export const USAGE_EXPORT_COST_BASIS = "API-equivalent";
export const NO_USAGE_RECORDED = "no usage recorded";
/** Matches `apps/web/package.json` `version`. */
export const WEB_APP_VERSION = "0.0.3";

export type UsageExportScope = "Account" | "This Mac";
export type UsageExportCostStatus = "complete" | "partial" | "unpriced";
export type UsageExportCellKind = "text" | "number";

export type UsageExportDayInput = {
  date: string;
  totals: {
    total_tokens: number;
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens: number;
    cache_write_input_tokens: number;
    reasoning_tokens: number;
    messages: number;
  };
  cost: { amount_microusd: string | null; status: string };
};

export type UsageExportRevision = {
  usage_revision: number;
  device_generation: number;
  account_updated_at: string | null;
  pricing_revision: string;
  model_catalog_revision: string;
  fold_version: number;
};

export type UsageExportInput = {
  scope: UsageExportScope;
  from: string;
  to: string;
  timezone: string;
  bounds: { start: string; end: string; grid: string } | null;
  coverage: { partial: boolean; truncated_by_retention: boolean };
  revision: UsageExportRevision | null;
  exported_at: string;
  app_version: string;
  days: readonly UsageExportDayInput[];
};

export type UsageExportJsonDay = {
  date: string;
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  reasoning_tokens: number;
  messages: number;
  api_equivalent_cost: string | null;
  cost_status: UsageExportCostStatus;
};

export type UsageExportJson = {
  scope: UsageExportScope;
  from: string;
  to: string;
  timezone: string;
  bounds: { start: string; end: string; grid: string } | null;
  cost_basis: typeof USAGE_EXPORT_COST_BASIS;
  coverage: { partial: boolean; truncated_by_retention: boolean };
  revision: UsageExportRevision | null;
  exported_at: string;
  app_version: string;
  days: UsageExportJsonDay[];
};

const FORMULA_PREFIX = /^(?:[=+\-@]|\t|\r)/;

/** RFC 4180 cell, with spreadsheet formula prefixes quoted as text. */
export function csvCell(value: string, kind: UsageExportCellKind = "text"): string {
  if (kind === "number") return value;
  let text = value;
  if (FORMULA_PREFIX.test(text)) text = `'${text}`;
  if (/[",\n\r]/.test(text)) return `"${text.replaceAll('"', '""')}"`;
  return text;
}

/** Exact dollars from micro-USD, no grouping, no cent rounding. */
export function dollarsFromMicrousd(microusd: string): string {
  const value = BigInt(microusd);
  const whole = value / 1_000_000n;
  const frac = value % 1_000_000n;
  if (frac === 0n) return whole.toString();
  return `${whole.toString()}.${frac.toString().padStart(6, "0").replace(/0+$/, "")}`;
}

export function usageExportCostStatus(status: string): UsageExportCostStatus {
  if (status === "complete" || status === "partial") return status;
  return "unpriced";
}

export function usageExportFilename(from: string, to: string, format: "csv" | "json"): string {
  return `quota-usage-${from}-${to}.${format}`;
}

/** Account period body already on the Usage page, as the shared export input. */
export function accountPeriodExportInput(
  period: {
    request: { from: string; to: string; timezone: string };
    bounds: { start: string; end: string; grid: string };
    coverage: { partial: boolean; truncated_by_retention: boolean };
    revision: UsageExportRevision;
    days: readonly UsageExportDayInput[];
  },
  meta: { exportedAt: string; appVersion: string },
): UsageExportInput {
  return {
    scope: "Account",
    from: period.request.from,
    to: period.request.to,
    timezone: period.request.timezone,
    bounds: period.bounds,
    coverage: {
      partial: period.coverage.partial,
      truncated_by_retention: period.coverage.truncated_by_retention,
    },
    revision: period.revision,
    exported_at: meta.exportedAt,
    app_version: meta.appVersion,
    days: period.days,
  };
}

function shiftUtcDate(date: string, days: number): string {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + days);
  return shifted.toISOString().slice(0, 10);
}

function jsonDay(day: UsageExportDayInput): UsageExportJsonDay {
  const status = usageExportCostStatus(day.cost.status);
  const amount = day.cost.amount_microusd;
  return {
    date: day.date,
    total_tokens: day.totals.total_tokens,
    input_tokens: day.totals.input_tokens,
    output_tokens: day.totals.output_tokens,
    cache_read_tokens: day.totals.cache_read_input_tokens,
    cache_write_tokens: day.totals.cache_write_input_tokens,
    reasoning_tokens: day.totals.reasoning_tokens,
    messages: day.totals.messages,
    api_equivalent_cost:
      status === "unpriced" || amount === null ? null : dollarsFromMicrousd(amount),
    cost_status: status,
  };
}

export function usageExportJson(input: UsageExportInput): UsageExportJson {
  return {
    scope: input.scope,
    from: input.from,
    to: input.to,
    timezone: input.timezone,
    bounds: input.bounds,
    cost_basis: USAGE_EXPORT_COST_BASIS,
    coverage: input.coverage,
    revision: input.revision,
    exported_at: input.exported_at,
    app_version: input.app_version,
    days: input.days.map(jsonDay),
  };
}

export function usageExportCsv(input: UsageExportInput): string {
  const byDate = new Map(input.days.map((day) => [day.date, jsonDay(day)]));
  const lines = [USAGE_EXPORT_CSV_HEADER];
  for (let date = input.from; date <= input.to; date = shiftUtcDate(date, 1)) {
    const day = byDate.get(date);
    if (day === undefined) {
      lines.push(
        [csvCell(date), "", "", "", "", "", "", "", "", csvCell(NO_USAGE_RECORDED)].join(","),
      );
      continue;
    }
    lines.push(
      [
        csvCell(day.date),
        csvCell(String(day.total_tokens), "number"),
        csvCell(String(day.input_tokens), "number"),
        csvCell(String(day.output_tokens), "number"),
        csvCell(String(day.cache_read_tokens), "number"),
        csvCell(String(day.cache_write_tokens), "number"),
        csvCell(String(day.reasoning_tokens), "number"),
        csvCell(String(day.messages), "number"),
        day.api_equivalent_cost === null ? "" : csvCell(day.api_equivalent_cost, "number"),
        csvCell(day.cost_status),
      ].join(","),
    );
  }
  return `${lines.join("\n")}\n`;
}

export function usageExportJsonText(input: UsageExportInput): string {
  return `${JSON.stringify(usageExportJson(input), null, 2)}\n`;
}
