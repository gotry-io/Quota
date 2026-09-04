import { getContext, setContext } from "svelte";
import type { AccountSummaryRead, UsageActivityDayRead } from "@gotry-io/quota-protocol";
import { type AccountError, fetchAccountActivity, fetchAccountSummary } from "./account-client.ts";
import { accountActivityRange } from "./account-reads.ts";
import { hashSelectorPreimage } from "./subscription-selector.ts";

/**
 * One signed-in `/my` store: summary, activity by `from|to`, and per-day detail.
 *
 * `ensure*` returns immediately when the read is younger than `maxAgeMs`, keeps the last
 * payload while a stale one revalidates, and joins an in-flight Promise for the same key.
 */
export type AccountLoadStatus = "idle" | "loading" | "ready" | "error";

export type AccountLoadResource<T> = {
  data: T | null;
  status: AccountLoadStatus;
  fetchedAt: number | null;
  error: AccountError | null;
};

export const SUMMARY_MAX_AGE_MS = 60_000;

const ACCOUNT_STORE = Symbol("account-store");

export function activityRangeKey(range: { from: string; to: string }): string {
  return `${range.from}|${range.to}`;
}

function emptyResource<T>(): AccountLoadResource<T> {
  return { data: null, status: "idle", fetchedAt: null, error: null };
}

function isFresh(fetchedAt: number | null, maxAgeMs: number): boolean {
  return fetchedAt !== null && Date.now() - fetchedAt < maxAgeMs;
}

export function createAccountStore() {
  let nowMs = $state(Date.now());
  let summary = $state<AccountSummaryRead | null>(null);
  let summaryStatus = $state<AccountLoadStatus>("idle");
  let summaryFetchedAt = $state<number | null>(null);
  let loadError = $state<AccountError | null>(null);
  let subscriptionSelectors = $state<Record<string, string>>({});
  let activity = $state<Record<string, AccountLoadResource<UsageActivityDayRead[]>>>({});
  let dayDetail = $state<Record<string, AccountLoadResource<UsageActivityDayRead>>>({});
  const selectorCache = new Map<string, string>();

  let summaryInflight: Promise<void> | null = null;
  const activityInflight = new Map<string, Promise<void>>();
  const dayInflight = new Map<string, Promise<void>>();

  async function hashSelectors(next: AccountSummaryRead): Promise<Record<string, string>> {
    const keys = next.subscriptions.map((item) => item.key);
    await Promise.all(
      keys.map(async (key) => {
        const cached = selectorCache.get(key);
        if (cached !== undefined) return;
        selectorCache.set(key, await hashSelectorPreimage(key));
      }),
    );
    const selectors: Record<string, string> = {};
    for (const key of keys) {
      const hashed = selectorCache.get(key);
      if (hashed !== undefined) selectors[key] = hashed;
    }
    return selectors;
  }

  function pullSummary(): Promise<void> {
    if (summaryInflight) return summaryInflight;
    if (summary === null) summaryStatus = "loading";
    summaryInflight = (async () => {
      const result = await fetchAccountSummary();
      if (result.status === "ok") {
        const selectors = await hashSelectors(result.summary);
        subscriptionSelectors = selectors;
        summary = result.summary;
        summaryStatus = "ready";
        summaryFetchedAt = Date.now();
        loadError = null;
        return;
      }
      loadError = result;
      summaryStatus = "error";
    })().finally(() => {
      summaryInflight = null;
    });
    return summaryInflight;
  }

  function ensureSummary({ maxAgeMs = SUMMARY_MAX_AGE_MS } = {}): Promise<void> {
    if (summary !== null && isFresh(summaryFetchedAt, maxAgeMs)) return Promise.resolve();
    const pull = pullSummary();
    if (summary !== null) return Promise.resolve();
    return pull;
  }

  async function refresh(): Promise<void> {
    if (summaryInflight) await summaryInflight;
    return pullSummary();
  }

  function pullActivity(range: { from: string; to: string }): Promise<void> {
    const key = activityRangeKey(range);
    const existing = activityInflight.get(key);
    if (existing) return existing;
    const current = activity[key] ?? emptyResource<UsageActivityDayRead[]>();
    if (current.data === null) {
      activity = { ...activity, [key]: { ...current, status: "loading" } };
    }
    const pull = (async () => {
      const result = await fetchAccountActivity(range);
      if (result.status === "ok") {
        activity = {
          ...activity,
          [key]: {
            data: result.activity.days,
            status: "ready",
            fetchedAt: Date.now(),
            error: null,
          },
        };
        return;
      }
      const previous = activity[key] ?? current;
      activity = {
        ...activity,
        [key]: { ...previous, status: "error", error: result },
      };
    })().finally(() => {
      activityInflight.delete(key);
    });
    activityInflight.set(key, pull);
    return pull;
  }

  function ensureActivity(
    range: { from: string; to: string },
    { maxAgeMs = SUMMARY_MAX_AGE_MS } = {},
  ): Promise<void> {
    const entry = activity[activityRangeKey(range)];
    if (entry !== undefined && entry.data !== null && isFresh(entry.fetchedAt, maxAgeMs)) {
      return Promise.resolve();
    }
    const pull = pullActivity(range);
    if (entry?.data !== null && entry?.data !== undefined) return Promise.resolve();
    return pull;
  }

  function pullDay(date: string): Promise<void> {
    const existing = dayInflight.get(date);
    if (existing) return existing;
    const current = dayDetail[date] ?? emptyResource<UsageActivityDayRead>();
    if (current.data === null) {
      dayDetail = { ...dayDetail, [date]: { ...current, status: "loading" } };
    }
    const pull = (async () => {
      const result = await fetchAccountActivity({ from: date, to: date }, "agents");
      if (result.status === "ok") {
        dayDetail = {
          ...dayDetail,
          [date]: {
            data: result.activity.days[0] ?? null,
            status: "ready",
            fetchedAt: Date.now(),
            error: null,
          },
        };
        return;
      }
      const previous = dayDetail[date] ?? current;
      dayDetail = {
        ...dayDetail,
        [date]: { ...previous, status: "error", error: result },
      };
    })().finally(() => {
      dayInflight.delete(date);
    });
    dayInflight.set(date, pull);
    return pull;
  }

  function ensureDay(date: string, { maxAgeMs = SUMMARY_MAX_AGE_MS } = {}): Promise<void> {
    const entry = dayDetail[date];
    if (entry !== undefined && isFresh(entry.fetchedAt, maxAgeMs)) return Promise.resolve();
    const pull = pullDay(date);
    if (entry?.fetchedAt !== null && entry?.fetchedAt !== undefined) return Promise.resolve();
    return pull;
  }

  function setError(error: AccountError): void {
    loadError = error;
    summaryStatus = "error";
  }

  function startClock(): () => void {
    nowMs = Date.now();
    const id = setInterval(() => {
      nowMs = Date.now();
    }, 60_000);
    const onVisibility = (): void => {
      if (document.visibilityState === "visible") nowMs = Date.now();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      clearInterval(id);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }

  return {
    get now() {
      return new Date(nowMs);
    },
    get summary() {
      return summary;
    },
    get summaryStatus() {
      return summaryStatus;
    },
    get summaryFetchedAt() {
      return summaryFetchedAt;
    },
    get loadError() {
      return loadError;
    },
    get subscriptionSelectors() {
      return subscriptionSelectors;
    },
    get activityRange() {
      return accountActivityRange(new Date());
    },
    get activity() {
      return activity;
    },
    get dayDetail() {
      return dayDetail;
    },
    ensureSummary,
    ensureActivity,
    ensureDay,
    refresh,
    setError,
    startClock,
  };
}

export type AccountStore = ReturnType<typeof createAccountStore>;

export function setAccountStore(store: AccountStore): void {
  setContext(ACCOUNT_STORE, store);
}

export function getAccountStore(): AccountStore {
  return getContext(ACCOUNT_STORE);
}
