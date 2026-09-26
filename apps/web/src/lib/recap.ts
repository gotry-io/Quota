import { usageCacheHitBasisPoints } from "@gotry-io/quota-model";

/**
 * The numbers the weekly recap's posters are written from, all taken from one week's period read
 * ([`docs/design.md`](../../../../docs/design.md), Weekly recap poster). Nothing here ranks the
 * reader or counts a streak.
 */
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function weekday(date: string): string {
  return WEEKDAYS[new Date(`${date}T00:00:00Z`).getUTCDay()] ?? date;
}

/** Which days carried the week: two days that did half of it, or the single busiest day. */
export function busiestDays(days: ReadonlyArray<{ date: string; tokens: number }>): string | null {
  const total = days.reduce((sum, day) => sum + day.tokens, 0);
  if (total <= 0) return null;
  const sorted = [...days].sort((left, right) => right.tokens - left.tokens);
  const [first, second] = sorted;
  if (!first) return null;
  if (first.tokens >= total / 2) return `${weekday(first.date)} did half the work.`;
  if (second && first.tokens + second.tokens >= total / 2) {
    const pair = [first, second].sort((left, right) => left.date.localeCompare(right.date));
    return `${weekday(pair[0]?.date ?? "")} and ${weekday(pair[1]?.date ?? "")} did half the work.`;
  }
  return `${weekday(first.date)} was the busiest day.`;
}

/** The day whose input came most from cache, from the model series' cells. */
export function bestCacheDay(series: {
  days: ReadonlyArray<{
    date: string;
    models: ReadonlyArray<{ input_tokens: number; cache_read_input_tokens: number }>;
  }>;
}): { date: string; percent: number } | null {
  let best: { date: string; percent: number } | null = null;
  for (const day of series.days) {
    const totals = day.models.reduce(
      (sum, cell) => ({
        input_tokens: sum.input_tokens + cell.input_tokens,
        cache_read_input_tokens: sum.cache_read_input_tokens + cell.cache_read_input_tokens,
      }),
      { input_tokens: 0, cache_read_input_tokens: 0 },
    );
    const hit = usageCacheHitBasisPoints({
      ...totals,
      total_tokens: totals.input_tokens,
      output_tokens: 0,
      cache_write_input_tokens: 0,
      reasoning_tokens: 0,
      messages: 0,
    });
    if (hit === null) continue;
    const percent = Math.round(hit / 100);
    if (best === null || percent > best.percent) best = { date: day.date, percent };
  }
  return best;
}

/** The busiest clock hour and the longest run of three or more hours nothing ran in. */
export function recapRhythm(hours: readonly number[]): {
  peak: number;
  quiet: { from: number; to: number } | null;
} | null {
  if (hours.length !== 24 || hours.every((value) => value <= 0)) return null;
  const peak = hours.indexOf(Math.max(...hours));
  let quiet: { from: number; to: number } | null = null;
  let start: number | null = null;
  for (let hour = 0; hour <= 24; hour += 1) {
    const idle = hour < 24 && (hours[hour] ?? 0) <= 0;
    if (idle && start === null) start = hour;
    if (!idle && start !== null) {
      if (hour - start >= 3 && (quiet === null || hour - start > quiet.to - quiet.from)) {
        quiet = { from: start, to: hour };
      }
      start = null;
    }
  }
  return { peak, quiet };
}

export function clock(hour: number): string {
  return `${String(hour % 24).padStart(2, "0")}:00`;
}
