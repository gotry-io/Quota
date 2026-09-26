import {
  type AccountSummaryRead,
  providerMinCollectionIntervalSeconds,
} from "@gotry-io/quota-protocol";

/**
 * When the dashboard asks the Account's Macs for a fresh reading, and when it stops waiting
 * (ADR 0063).
 *
 * Someone looking at the dashboard is the demand: when it opens, or its tab becomes visible
 * again, a subscription whose newest Mac reading is older than `staleAfterMs` is worth one
 * `POST /api/v6/account/collection-request`. Only a Mac answers one, so only a Mac's reading is
 * judged. The summary is then re-read every 30 seconds for up to three minutes, and the wait ends
 * as soon as every subscription asked about has a Mac reading at or after the instant Relay
 * stored, or the tab is hidden.
 */
/**
 * Two minutes, or the provider's catalog floor when that is longer: a Mac does not ask a provider
 * again inside its floor, so a younger reading is as fresh as a request could make it.
 */
export function staleAfterMs(provider: string): number {
  return Math.max(2 * 60, providerMinCollectionIntervalSeconds(provider)) * 1_000;
}
export const FOLLOW_UP_INTERVAL_MS = 30_000;
/** Three minutes of 30-second reads. */
export const FOLLOW_UP_READS = 6;

export type CollectionDemand = {
  /** Subscriptions whose newest Mac reading was stale when the request went out. */
  keys: Set<string>;
  /** How many Macs those readings came from, which is what the status line names. */
  macCount: number;
};

type Subscription = AccountSummaryRead["subscriptions"][number];
type Source = Subscription["sources"][number];

function macIds(summary: AccountSummaryRead): Set<string> {
  return new Set(
    summary.devices.filter((device) => device.platform === "macos").map((device) => device.id),
  );
}

function newestMacSource(subscription: Subscription, macs: Set<string>): Source | null {
  let newest: Source | null = null;
  for (const source of subscription.sources) {
    if (!macs.has(source.device_id)) continue;
    if (newest === null || Date.parse(source.observed_at) > Date.parse(newest.observed_at)) {
      newest = source;
    }
  }
  return newest;
}

/** What is worth asking for in `summary` at `nowMs`, or null when every Mac reading is fresh. */
export function staleDemand(summary: AccountSummaryRead, nowMs: number): CollectionDemand | null {
  const macs = macIds(summary);
  const keys = new Set<string>();
  const devices = new Set<string>();
  for (const subscription of summary.subscriptions) {
    const newest = newestMacSource(subscription, macs);
    if (
      newest === null ||
      nowMs - Date.parse(newest.observed_at) <= staleAfterMs(subscription.provider)
    )
      continue;
    keys.add(subscription.key);
    devices.add(newest.device_id);
  }
  return keys.size === 0 ? null : { keys, macCount: devices.size };
}

/** Whether every subscription asked about has a Mac reading at or after `requestedAtMs`. */
export function isAnswered(
  summary: AccountSummaryRead,
  demand: CollectionDemand,
  requestedAtMs: number,
): boolean {
  const macs = macIds(summary);
  return summary.subscriptions.every((subscription) => {
    if (!demand.keys.has(subscription.key)) return true;
    const newest = newestMacSource(subscription, macs);
    return newest === null || Date.parse(newest.observed_at) >= requestedAtMs;
  });
}

/** The status line while the Macs are being waited on. */
export function askingCopy(macCount: number): string {
  return macCount === 1 ? "Asking your Mac…" : "Asking your Macs…";
}

export type FollowUpDeps = {
  summary: () => AccountSummaryRead | null;
  /** The instant Relay stored, or null when it refused: an older Relay, or a busy session. */
  requestCollection: () => Promise<number | null>;
  readSummary: () => Promise<void>;
  /** Resolves after `ms`, or as soon as `signal` aborts. */
  wait: (ms: number, signal: AbortSignal) => Promise<void>;
  now: () => number;
  onWaiting: (macCount: number) => void;
};

/** One request and its follow-up. A refusal and a timeout both end it without a word. */
export async function followCollectionDemand(
  deps: FollowUpDeps,
  signal: AbortSignal,
): Promise<void> {
  const current = deps.summary();
  const demand = current === null ? null : staleDemand(current, deps.now());
  if (demand === null) return;
  const requestedAt = await deps.requestCollection();
  if (requestedAt === null || signal.aborted) return;
  deps.onWaiting(demand.macCount);
  for (let read = 0; read < FOLLOW_UP_READS; read += 1) {
    await deps.wait(FOLLOW_UP_INTERVAL_MS, signal);
    if (signal.aborted) return;
    await deps.readSummary();
    if (signal.aborted) return;
    const latest = deps.summary();
    if (latest !== null && isAnswered(latest, demand, requestedAt)) return;
  }
}

export function abortableWait(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const id = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(id);
        resolve();
      },
      { once: true },
    );
  });
}
