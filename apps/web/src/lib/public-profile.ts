import {
  type PublicUsageResponse,
  PUBLIC_ACTIVITY_DAYS,
  PUBLIC_PROFILE_HANDLE_PATTERN,
  type PublicActivityDay,
  type PublicUsagePeriod,
  isReservedPublicProfileHandle,
} from "@gotry-io/quota-protocol";
import { formatCount } from "./format.ts";

/** Why this handle cannot be published, in the words the form shows, or null when it can. */
export function handleProblem(handle: string): string | null {
  if (handle.length === 0) return "Choose a handle to publish this page.";
  if (isReservedPublicProfileHandle(handle)) return "That handle is reserved.";
  if (!PUBLIC_PROFILE_HANDLE_PATTERN.test(handle)) {
    return "Use 3 to 30 characters: lowercase letters, numbers, and hyphens, starting with a letter or number.";
  }
  return null;
}

type PublicActivityCell = {
  date: string;
  level: number;
  outside: boolean;
};

export type PublicActivityModel = {
  cells: PublicActivityCell[];
  weeks: number;
  from: string;
  to: string;
};

/**
 * A year of Sunday-first columns, the same shape the account's own graph draws.
 *
 * The response names only the days that had Usage, so the calendar is built here and a date it
 * does not carry is level 0. Padding days before the range are inert, exactly as they are on
 * `/my/usage`.
 */
export function buildPublicActivityModel(
  days: readonly PublicActivityDay[],
  today: string,
): PublicActivityModel {
  const to = today;
  const from = shiftUtcDate(to, -(PUBLIC_ACTIVITY_DAYS - 1));
  const levels = new Map(days.map((day) => [day.date, day.level]));
  const first = shiftUtcDate(from, -utcWeekday(from));
  const last = shiftUtcDate(to, 6 - utcWeekday(to));
  const cells: PublicActivityCell[] = [];
  for (let date = first; date <= last; date = shiftUtcDate(date, 1)) {
    const outside = date < from || date > to;
    cells.push({ date, outside, level: outside ? 0 : (levels.get(date) ?? 0) });
  }
  return { cells, weeks: cells.length / 7, from, to };
}

/**
 * The one sentence a link preview shows, and the page's own summary line.
 *
 * It names what the page publishes and nothing it does not: totals and a period. There is no
 * account label, no device, and no remaining quota in it, because there is none on the page.
 */
export function publicProfileSummary(profile: PublicUsageResponse): string {
  const period = profile.last_30_days;
  const tokens = formatCount(period.totals.total_tokens);
  const messages = formatCount(period.totals.messages);
  return `${profile.handle} used ${tokens} tokens across ${messages} coding-agent messages in the last 30 days, on Quota.`;
}

/** The share of a period one bar stands for, as a percentage string. */
export function sharePercent(permille: number): string {
  return `${(permille / 10).toFixed(permille % 10 === 0 ? 0 : 1)}%`;
}

/** Whether this period has anything to draw at all. */
export function hasUsage(period: PublicUsagePeriod): boolean {
  return period.totals.total_tokens > 0 || period.totals.messages > 0;
}

function utcWeekday(date: string): number {
  return new Date(`${date}T00:00:00Z`).getUTCDay();
}

function shiftUtcDate(date: string, days: number): string {
  return new Date(new Date(`${date}T00:00:00Z`).getTime() + days * 86_400_000)
    .toISOString()
    .slice(0, 10);
}
