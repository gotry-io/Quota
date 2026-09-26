import {
  formatPercent,
  formatWindowTitle,
  observedSnapshotStatus,
  remainingPercent,
  showsPercentMeter,
} from "@gotry-io/quota-model";
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { formatQuotaRemaining, observedSnapshotStatusLabel } from "./format.ts";

type Subscription = AccountSummaryRead["subscriptions"][number];

/**
 * What the quota band says about one subscription.
 *
 * A reading that no longer describes the account says why instead of a number. A subscription
 * whose windows draw no percent meter (wallets, dollars of a limit) prints its first amount.
 * Otherwise the tightest metered window speaks for it: the lowest remaining percent, because that
 * is the one that stops the reader first — the same windows Apple's `TightestWindow` lets compete.
 */
export type QuotaBandItem =
  | { kind: "status"; word: string }
  | { kind: "balance"; amount: string }
  | { kind: "percent"; remaining: number; text: string; window: string }
  | { kind: "none" };

export function quotaBandItem(subscription: Subscription, now: Date): QuotaBandItem {
  const snapshot = subscription.snapshot;
  const status = observedSnapshotStatus(snapshot, now);
  if (status !== "available") {
    return { kind: "status", word: observedSnapshotStatusLabel(status) };
  }
  let tightest: { remaining: number; title: string } | null = null;
  for (const window of snapshot.windows) {
    if (!showsPercentMeter(window)) continue;
    const remaining = remainingPercent(window.used_percent);
    if (tightest === null || remaining < tightest.remaining) {
      tightest = { remaining, title: formatWindowTitle(window.title, window) };
    }
  }
  if (tightest !== null) {
    return {
      kind: "percent",
      remaining: tightest.remaining,
      text: formatPercent(tightest.remaining),
      window: tightest.title,
    };
  }
  const wallet = snapshot.windows[0];
  if (wallet) {
    return { kind: "balance", amount: formatQuotaRemaining(wallet, subscription.provider) };
  }
  return { kind: "none" };
}
