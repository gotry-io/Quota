import { usageCacheHitBasisPoints } from "@gotry-io/quota-model";
import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import { formatCost } from "./format.ts";
import {
  costPerMessageMicrousd,
  type ModelRow,
  namedModelCount,
  type ShareChange,
  shareChange,
  type TotalsView,
} from "./model-usage.ts";

/**
 * **What stood out** and the records under **Agents → models**: sentences and figures written
 * from the reader's own numbers. A sentence appears only when every number in it exists; none of
 * them gives advice, and none counts volume as an achievement
 * ([ADR 0064](../../../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md)).
 */
export type InsightPart =
  | { kind: "text"; text: string }
  | { kind: "figure"; text: string }
  | { kind: "model"; text: string }
  | { kind: "link"; text: string; href: string };

export type Insight = { id: string; tone: "ink" | "good" | "warn"; parts: InsightPart[] };

const text = (value: string): InsightPart => ({ kind: "text", text: value });
const figure = (value: string): InsightPart => ({ kind: "figure", text: value });
const model = (value: string): InsightPart => ({ kind: "model", text: value });

function percent(fraction: number): string {
  return `${Math.round(fraction * 100)}%`;
}

function changeWords(change: ShareChange): InsightPart[] {
  if (change.kind !== "points") return [text(".")];
  if (change.points === 0) return [text(", about the same share as the previous period.")];
  return [
    text(", "),
    figure(`${change.points > 0 ? "up" : "down"} ${Math.abs(change.points)} pts`),
    text(" on the previous period."),
  ];
}

export type InsightInput = {
  rows: readonly ModelRow[];
  previous: readonly ModelRow[] | null;
  totals: TotalsView;
  cacheSaved: { amount_microusd: string | null; status: string };
  /** A top model that entered inside the period, with the local date it did. */
  arrival: { model: string; date: string } | null;
  /** The tightest current window when it is getting tight. */
  tightest: { name: string; remaining: number; href: string | null } | null;
  rhythm: { hours: readonly number[]; weekdays: readonly number[] } | null;
};

const WEEKDAYS = [
  "Sundays",
  "Mondays",
  "Tuesdays",
  "Wednesdays",
  "Thursdays",
  "Fridays",
  "Saturdays",
];

export function usageInsights(input: InsightInput): Insight[] {
  const insights: Insight[] = [];
  const total = input.totals.total_tokens;
  const top = input.rows[0];

  if (top && total > 0) {
    const arrived = input.arrival
      ? input.rows.find((row) => row.model === input.arrival?.model)
      : undefined;
    if (arrived && input.arrival) {
      insights.push({
        id: "arrival",
        tone: "ink",
        parts: [
          model(arrived.model),
          text(" arrived on "),
          figure(shortDate(input.arrival.date)),
          text(" and carried "),
          figure(percent(arrived.totals.total_tokens / total)),
          text(" of your tokens in this period."),
        ],
      });
    } else if (top.model !== USAGE_OTHER_MODEL) {
      insights.push({
        id: "top-model",
        tone: "ink",
        parts: [
          model(top.model),
          text(" carried "),
          figure(percent(top.totals.total_tokens / total)),
          text(" of your tokens"),
          ...changeWords(shareChange(top, total, input.previous)),
        ],
      });
    }
  }

  const hit = usageCacheHitBasisPoints(input.totals);
  if (hit !== null && hit > 0) {
    const parts: InsightPart[] = [
      text("Cache reads covered "),
      figure(`${Math.round(hit / 100)}%`),
      text(" of input"),
    ];
    if (input.cacheSaved.amount_microusd !== null && input.cacheSaved.amount_microusd !== "0") {
      parts.push(text(", about "), figure(formatCost(input.cacheSaved)), text(" under list price"));
    }
    parts.push(text("."));
    const best = bestCachingModel(input.rows, total, hit);
    if (best) {
      parts.push(
        text(" "),
        model(best.model),
        text(` caches best at ${Math.round(best.hit / 100)}%.`),
      );
    }
    insights.push({ id: "cache", tone: "good", parts });
  }

  if (input.tightest && input.tightest.remaining < 40) {
    const parts: InsightPart[] = [
      figure(input.tightest.name),
      text(" is down to "),
      figure(`${Math.round(input.tightest.remaining)}%`),
      text(". "),
    ];
    if (input.tightest.href)
      parts.push({ kind: "link", text: "See the window", href: input.tightest.href });
    insights.push({ id: "quota", tone: "warn", parts });
  }

  const rhythm = input.rhythm ? busiest(input.rhythm) : null;
  if (rhythm) {
    const parts: InsightPart[] = [text("Your busiest hours are "), figure(rhythm.hours)];
    if (rhythm.weekday) {
      parts.push(
        text(", and "),
        figure(rhythm.weekday.name),
        text(" run "),
        figure(`${rhythm.weekday.ratio.toFixed(1)}×`),
        text(" your average day"),
      );
    }
    parts.push(text("."));
    insights.push({ id: "rhythm", tone: "ink", parts });
  }

  return insights.slice(0, 4);
}

function bestCachingModel(
  rows: readonly ModelRow[],
  total: number,
  overall: number,
): { model: string; hit: number } | null {
  let best: { model: string; hit: number } | null = null;
  for (const row of rows) {
    if (row.model === USAGE_OTHER_MODEL || row.totals.total_tokens < total * 0.05) continue;
    const hit = usageCacheHitBasisPoints(row.totals);
    if (hit === null || hit < overall + 300) continue;
    if (best === null || hit > best.hit) best = { model: row.model, hit };
  }
  return rows.length > 1 ? best : null;
}

/** The busiest three clock hours in a row, and a weekday well above the average day. */
export function busiest(rhythm: {
  hours: readonly number[];
  weekdays: readonly number[];
}): { hours: string; weekday: { name: string; ratio: number } | null } | null {
  const sum = rhythm.hours.reduce((left, right) => left + right, 0);
  if (sum <= 0 || rhythm.hours.length !== 24) return null;
  let start = 0;
  let most = -1;
  for (let hour = 0; hour <= 21; hour += 1) {
    const window =
      (rhythm.hours[hour] ?? 0) + (rhythm.hours[hour + 1] ?? 0) + (rhythm.hours[hour + 2] ?? 0);
    if (window > most) {
      most = window;
      start = hour;
    }
  }
  const clock = (hour: number): string => `${String(hour).padStart(2, "0")}:00`;
  const days = rhythm.weekdays.reduce((left, right) => left + right, 0);
  let weekday: { name: string; ratio: number } | null = null;
  if (days > 0 && rhythm.weekdays.length === 7) {
    const average = days / 7;
    const peak = Math.max(...rhythm.weekdays);
    const ratio = peak / average;
    const name = WEEKDAYS[rhythm.weekdays.indexOf(peak)];
    if (ratio >= 1.3 && name) weekday = { name, ratio };
  }
  return { hours: `${clock(start)}–${clock(start + 3)}`, weekday };
}

export type UsageRecord = {
  id: string;
  label: string;
  value: string;
  note: string;
  model?: boolean;
};

/**
 * Records that celebrate efficiency or breadth, never volume: active days in the year, the best
 * cache day, how many models were tried, and the lowest cost per message.
 */
export function usageRecords(input: {
  days: ReadonlyArray<{ date: string; totals: TotalsView }>;
  range: { from: string; to: string };
  allRows: readonly ModelRow[];
}): UsageRecord[] {
  const records: UsageRecord[] = [];
  const span =
    Math.round(
      (Date.parse(`${input.range.to}T00:00:00Z`) - Date.parse(`${input.range.from}T00:00:00Z`)) /
        86_400_000,
    ) + 1;
  const active = input.days.filter((day) => day.totals.total_tokens > 0);
  if (active.length > 0) {
    records.push({
      id: "active",
      label: "Active days",
      value: `${active.length} of ${span}`,
      note: `since ${longDate(input.range.from)}`,
    });
  }
  const inputs = active.map((day) => day.totals.input_tokens).sort((left, right) => left - right);
  const median = inputs[Math.floor(inputs.length / 2)] ?? 0;
  let bestDay: { date: string; hit: number } | null = null;
  for (const day of active) {
    if (day.totals.input_tokens < median * 0.25) continue;
    const hit = usageCacheHitBasisPoints(day.totals);
    if (hit !== null && (bestDay === null || hit > bestDay.hit)) bestDay = { date: day.date, hit };
  }
  if (bestDay && bestDay.hit > 0) {
    records.push({
      id: "cache-day",
      label: "Best cache day",
      value: `${Math.round(bestDay.hit / 100)}%`,
      note: shortDate(bestDay.date),
    });
  }
  const tried = namedModelCount(input.allRows);
  if (tried > 0) {
    const agents = new Set(input.allRows.flatMap((row) => row.agents.map((sent) => sent.agent)));
    records.push({
      id: "models",
      label: "Models tried",
      value: String(tried),
      note: `through ${agents.size} ${agents.size === 1 ? "agent" : "agents"}`,
    });
  }
  let cheapest: { model: string; microusd: number } | null = null;
  for (const row of input.allRows) {
    if (
      row.model === USAGE_OTHER_MODEL ||
      row.cost.status !== "complete" ||
      row.totals.messages < 20
    )
      continue;
    const microusd = costPerMessageMicrousd(row);
    if (microusd !== null && (cheapest === null || microusd < cheapest.microusd)) {
      cheapest = { model: row.model, microusd };
    }
  }
  if (cheapest) {
    records.push({
      id: "per-message",
      label: "Lowest cost per message",
      value: `$${(cheapest.microusd / 1_000_000).toFixed(3)}`,
      note: cheapest.model,
      model: true,
    });
  }
  return records;
}

/** `Sep 10` for a `YYYY-MM-DD`, read as a calendar date. */
export function shortDate(date: string): string {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

function longDate(date: string): string {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
}
