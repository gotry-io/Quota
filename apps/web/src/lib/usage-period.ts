export const USAGE_PERIODS = [
  { query: "today", key: "today", label: "Today" },
  { query: "7d", key: "last_7_days", label: "7 Days" },
  { query: "30d", key: "last_30_days", label: "30 Days" },
  { query: "all", key: "all", label: "Up to 2 years" },
] as const;

export type UsagePeriodQuery = (typeof USAGE_PERIODS)[number]["query"];
export type UsagePeriodKey = (typeof USAGE_PERIODS)[number]["key"];

export const DEFAULT_USAGE_PERIOD_QUERY: UsagePeriodQuery = "30d";
export const USAGE_MODEL_FOLD_LIMIT = 5;

const QUERY_TO_KEY = {
  today: "today",
  "7d": "last_7_days",
  "30d": "last_30_days",
  all: "all",
} as const satisfies Record<UsagePeriodQuery, UsagePeriodKey>;

/** How many extra models a provider group hides behind Show N more. */
export function hiddenModelCount(modelCount: number): number {
  return Math.max(0, modelCount - USAGE_MODEL_FOLD_LIMIT);
}

export function usagePeriodFromQuery(value: string | null): UsagePeriodQuery {
  if (value === "today" || value === "7d" || value === "30d" || value === "all") return value;
  return DEFAULT_USAGE_PERIOD_QUERY;
}

export function usagePeriodKey(query: UsagePeriodQuery): UsagePeriodKey {
  return QUERY_TO_KEY[query];
}

export function usagePeriodHref(url: URL, query: UsagePeriodQuery): string {
  const next = new URL(url);
  next.searchParams.set("period", query);
  return `${next.pathname}${next.search}${next.hash}`;
}
