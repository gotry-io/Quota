import type { AccountUsagePeriodResponseRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import { accountUsagePeriodTruncated, accountUsagePeriodView } from "./account-reads.ts";
import type { AccountError } from "./account-errors.ts";
import type { AccountStore } from "./account-store.svelte.ts";
import { type ModelColors, modelColors } from "./model-colors.ts";
import { type RiverData, riverArrival, riverData, singleStream } from "./model-river.ts";
import { foldModelRows, type ModelRow } from "./model-usage.ts";
import {
  localDate,
  previousUsagePeriodRange,
  type UsageDateRange,
  type UsagePeriodSelection,
  usagePeriodRange,
} from "./usage-period.ts";

/**
 * The reads an analysis page draws one period from, and what it derives from them.
 *
 * Every period but `all` is one period read with the agent tree and the model series; `all` is
 * the summary's 730-day window and carries no series. A single day has no river of its own, so
 * its chart reads the seven days ending on it. The previous equal range is a second read, with
 * the tree so the ledger can say how each model's share moved. Model colours always come from
 * the summary's `all` tree, so they do not change with the period.
 */
export type UsageView = ReturnType<typeof createUsageView>;

export function createUsageView(store: AccountStore, selection: () => UsagePeriodSelection) {
  const today = $derived(localDate(store.now));
  const fromSummary = $derived(selection().segment === "all");
  const range = $derived(usagePeriodRange(selection(), store.now));
  const riverRange = $derived.by((): UsageDateRange | null => {
    if (!range) return null;
    if (range.from !== range.to) return range;
    const end = new Date(`${range.to}T00:00:00`);
    const start = new Date(end.getFullYear(), end.getMonth(), end.getDate() - 6);
    return { from: localDate(start), to: range.to };
  });
  const previousRange = $derived(previousUsagePeriodRange(selection(), store.now));

  const shape = { breakdown: true, series: "model" } as const;
  const entry = $derived(range ? store.periodFor(range, shape) : undefined);
  const riverEntry = $derived(riverRange ? store.periodFor(riverRange, shape) : undefined);
  const previousEntry = $derived(
    previousRange ? store.periodFor(previousRange, { breakdown: true }) : undefined,
  );

  $effect(() => {
    if (range) void store.ensurePeriod(range, shape);
  });
  $effect(() => {
    if (riverRange && riverRange !== range) void store.ensurePeriod(riverRange, shape);
  });
  $effect(() => {
    if (previousRange) void store.ensurePeriod(previousRange, { breakdown: true });
  });

  const read = $derived<AccountUsagePeriodResponseRead | null>(entry?.data ?? null);
  const period = $derived<UsagePeriodRead | null>(
    fromSummary ? (store.summary?.usage.all ?? null) : read ? accountUsagePeriodView(read) : null,
  );
  const error = $derived<AccountError | null>(
    !fromSummary && entry?.status === "error" ? entry.error : null,
  );
  const colors = $derived<ModelColors>(modelColors(store.summary?.usage.all.agents ?? []));
  const rows = $derived<ModelRow[]>(period ? foldModelRows(period.agents) : []);
  const previousPeriod = $derived(previousEntry?.data ?? null);
  const previousRows = $derived<ModelRow[] | null>(
    previousPeriod ? foldModelRows(previousPeriod.agents ?? []) : null,
  );

  const riverRead = $derived(riverEntry?.data ?? null);
  function river(metric: "tokens" | "cost" | "messages"): RiverData | null {
    if (!riverRead || !riverRange) return null;
    if (metric === "messages") {
      return singleStream(
        riverRead.days.map((day) => ({ date: day.date, value: day.totals.messages })),
        riverRange,
        today,
        "Messages",
      );
    }
    if (!riverRead.model_series) return null;
    return riverData(riverRead.model_series, riverRange, metric, today);
  }
  const arrival = $derived.by(() => {
    const data = river("tokens");
    if (!data) return null;
    const found = riverArrival(data);
    return found ? { model: found.model, date: data.dates[found.index] ?? "" } : null;
  });

  return {
    get today() {
      return today;
    },
    get fromSummary() {
      return fromSummary;
    },
    get range() {
      return range;
    },
    get riverRange() {
      return riverRange;
    },
    get previousRange() {
      return previousRange;
    },
    get read() {
      return read;
    },
    get period() {
      return period;
    },
    get error() {
      return error;
    },
    get truncated() {
      return read ? accountUsagePeriodTruncated(read) : false;
    },
    get colors() {
      return colors;
    },
    get rows() {
      return rows;
    },
    get previousPeriod() {
      return previousPeriod;
    },
    get previousRows() {
      return previousRows;
    },
    get arrival() {
      return arrival;
    },
    river,
    retry() {
      if (range) void store.ensurePeriod(range, { ...shape, maxAgeMs: 0 });
    },
  };
}
