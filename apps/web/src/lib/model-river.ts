import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import { modelKey } from "./model-colors.ts";

/**
 * The model river: a period's usage by local day and model, stacked largest model at the bottom
 * ([`docs/design.md`](../../../../docs/design.md#components), Model river).
 *
 * Every date of the asked range keeps its place on the axis. A date with no Usage is a gap, not a
 * zero day: in Amount the stack meets the baseline there, and in Share the areas break over it
 * rather than drawing a 0 % dip. The current day is marked in progress.
 */
type CellView = {
  model: string;
  total_tokens: number;
  cost_microusd: string | null;
};

export type ModelSeriesView = {
  models: ReadonlyArray<{ model: string; provider: string | null }>;
  days: ReadonlyArray<{ date: string; partial: boolean; models: readonly CellView[] }>;
};

export type RiverMetric = "tokens" | "cost" | "messages";
export type RiverMode = "amount" | "share";

export type RiverBand = {
  key: string;
  model: string;
  provider: string | null;
  /** One value per axis date; 0 where the model had no Usage that day. */
  values: number[];
  /** Days whose cost the catalog could not price, drawn as zero and named unpriced. */
  unpriced: boolean[];
};

export type RiverData = {
  dates: string[];
  bands: RiverBand[];
  /** Per date: whether any Usage was recorded. */
  present: boolean[];
  /** The index of today's date when it is inside the range, which is still running. */
  inProgress: number | null;
};

const DAY_MS = 86_400_000;

/** Every local date from `from` to `to`, both included. */
export function rangeDates(from: string, to: string): string[] {
  const dates: string[] = [];
  const end = Date.parse(`${to}T00:00:00Z`);
  for (let at = Date.parse(`${from}T00:00:00Z`); at <= end; at += DAY_MS) {
    dates.push(new Date(at).toISOString().slice(0, 10));
  }
  return dates;
}

/** The river's values for one metric. Messages are not split by model, so they have no river. */
export function riverData(
  series: ModelSeriesView,
  range: { from: string; to: string },
  metric: "tokens" | "cost",
  today: string,
): RiverData {
  const dates = rangeDates(range.from, range.to);
  const index = new Map(dates.map((date, position) => [date, position]));
  const bands: RiverBand[] = series.models.map((entry) => ({
    key: modelKey(entry.provider, entry.model),
    model: entry.model,
    provider: entry.provider,
    values: dates.map(() => 0),
    unpriced: dates.map(() => false),
  }));
  const byModel = new Map(bands.map((band) => [band.model, band]));
  const present = dates.map(() => false);
  for (const day of series.days) {
    const position = index.get(day.date);
    if (position === undefined) continue;
    for (const cell of day.models) {
      const band = byModel.get(cell.model);
      if (!band || cell.total_tokens <= 0) continue;
      present[position] = true;
      if (metric === "tokens") {
        band.values[position] = cell.total_tokens;
      } else if (cell.cost_microusd === null) {
        band.unpriced[position] = true;
      } else {
        band.values[position] = Number(cell.cost_microusd);
      }
    }
  }
  const todayIndex = index.get(today);
  return {
    dates,
    bands: bands.filter(
      (band) => band.values.some((value) => value > 0) || band.unpriced.some(Boolean),
    ),
    present,
    inProgress: todayIndex === undefined ? null : todayIndex,
  };
}

/** A single stream of one per-day figure, for the metric no model split carries. */
export function singleStream(
  days: ReadonlyArray<{ date: string; value: number }>,
  range: { from: string; to: string },
  today: string,
  label: string,
): RiverData {
  const dates = rangeDates(range.from, range.to);
  const values = dates.map(() => 0);
  const present = dates.map(() => false);
  const index = new Map(dates.map((date, position) => [date, position]));
  for (const day of days) {
    const position = index.get(day.date);
    if (position === undefined || day.value <= 0) continue;
    values[position] = day.value;
    present[position] = true;
  }
  const todayIndex = index.get(today);
  return {
    dates,
    bands: [{ key: "|", model: label, provider: null, values, unpriced: dates.map(() => false) }],
    present,
    inProgress: todayIndex === undefined ? null : todayIndex,
  };
}

export type RiverStack = {
  /** Per band, per date: the band's lower and upper edge, in the metric or as 0…1 share. */
  lower: number[][];
  upper: number[][];
  /** The largest stacked value, which the axis is drawn against. 1 in Share. */
  maximum: number;
};

export function stackRiver(data: RiverData, mode: RiverMode): RiverStack {
  const totals = data.dates.map((_, position) =>
    data.bands.reduce((sum, band) => sum + (band.values[position] ?? 0), 0),
  );
  const base = data.dates.map(() => 0);
  const lower: number[][] = [];
  const upper: number[][] = [];
  for (const band of data.bands) {
    lower.push([...base]);
    for (let position = 0; position < base.length; position += 1) {
      const value = band.values[position] ?? 0;
      const total = totals[position] ?? 0;
      base[position] =
        (base[position] ?? 0) + (mode === "share" ? (total > 0 ? value / total : 0) : value);
    }
    upper.push([...base]);
  }
  return { lower, upper, maximum: mode === "share" ? 1 : Math.max(0, ...totals) };
}

/**
 * The runs of dates a band is drawn over. Amount draws every date (an empty day meets the
 * baseline); Share draws only dates with Usage, so an empty day breaks the areas.
 */
export function riverRuns(data: RiverData, mode: RiverMode): Array<[number, number]> {
  if (data.dates.length === 0) return [];
  if (mode === "amount") return [[0, data.dates.length - 1]];
  const runs: Array<[number, number]> = [];
  let start: number | null = null;
  data.present.forEach((present, position) => {
    if (present && start === null) start = position;
    if (!present && start !== null) {
      runs.push([start, position - 1]);
      start = null;
    }
  });
  if (start !== null) runs.push([start, data.present.length - 1]);
  return runs;
}

/**
 * The model worth marking where it enters: among the three largest named bands, the one whose
 * first day comes after at least two days on which something else ran.
 */
export function riverArrival(data: RiverData): { index: number; model: string } | null {
  const candidates = data.bands.filter((band) => band.model !== USAGE_OTHER_MODEL).slice(0, 3);
  for (const band of candidates) {
    const first = band.values.findIndex((value) => value > 0);
    if (first < 1) continue;
    const activeBefore = data.present.slice(0, first).filter(Boolean).length;
    if (activeBefore >= 2) return { index: first, model: band.model };
  }
  return null;
}

/** A monotone cubic through the points, which never overshoots a day's value. */
export function monotonePath(
  points: ReadonlyArray<readonly [number, number]>,
  move = true,
): string {
  const first = points[0];
  if (!first) return "";
  const head = `${move ? "M" : "L"}${round(first[0])},${round(first[1])}`;
  if (points.length < 2) return head;
  const count = points.length;
  const dx: number[] = [];
  const slope: number[] = [];
  for (let i = 0; i < count - 1; i += 1) {
    const [x0, y0] = points[i] as readonly [number, number];
    const [x1, y1] = points[i + 1] as readonly [number, number];
    dx.push(x1 - x0);
    slope.push((y1 - y0) / (x1 - x0));
  }
  const tangent: number[] = [slope[0] ?? 0];
  for (let i = 1; i < count - 1; i += 1) {
    const left = slope[i - 1] ?? 0;
    const right = slope[i] ?? 0;
    const dl = dx[i - 1] ?? 0;
    const dr = dx[i] ?? 0;
    tangent.push(
      left * right <= 0 ? 0 : (3 * (dl + dr)) / ((2 * dr + dl) / left + (dr + 2 * dl) / right),
    );
  }
  tangent.push(slope[count - 2] ?? 0);
  let path = head;
  for (let i = 0; i < count - 1; i += 1) {
    const [x0, y0] = points[i] as readonly [number, number];
    const [x1, y1] = points[i + 1] as readonly [number, number];
    const h = (dx[i] ?? 0) / 3;
    path += `C${round(x0 + h)},${round(y0 + h * (tangent[i] ?? 0))} ${round(x1 - h)},${round(y1 - h * (tangent[i + 1] ?? 0))} ${round(x1)},${round(y1)}`;
  }
  return path;
}

function round(value: number): number {
  return Math.round(value * 10) / 10;
}
