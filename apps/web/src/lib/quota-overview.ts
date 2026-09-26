import {
  formatWindowTitle,
  isBalanceOnly,
  observedSnapshotStatus,
  quotaPace,
  remainingPercent,
} from "@gotry-io/quota-model";
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import { meterTone, type MeterTone } from "./account-overview.ts";
import { type AgentTreeView, foldModelRows, type ModelRow } from "./model-usage.ts";
import { localDate } from "./usage-period.ts";

/**
 * The Quota page's reading of the summary: the tightest window, the even-pace tick, the next
 * seven days of resets, and which models used a window.
 */
type Subscription = AccountSummaryRead["subscriptions"][number];
type QuotaWindow = Subscription["snapshot"]["windows"][number];

export type TightestWindow = {
  subscription: Subscription;
  window: QuotaWindow;
  remaining: number;
  /** `Codex Weekly`: the provider's name and the window's title. */
  name: string;
};

/** Windows with a percent that means remaining: not wallets. */
function percentWindows(subscription: Subscription): QuotaWindow[] {
  return subscription.snapshot.windows.filter((window) => !isBalanceOnly(window));
}

export function isCurrent(subscription: Subscription, now: Date): boolean {
  return observedSnapshotStatus(subscription.snapshot, now) === "available";
}

/** The lowest remaining across every current subscription, the one that stops the reader first. */
export function tightestWindow(
  subscriptions: readonly Subscription[],
  now: Date,
): TightestWindow | null {
  let tightest: TightestWindow | null = null;
  for (const subscription of subscriptions) {
    if (!isCurrent(subscription, now)) continue;
    for (const window of percentWindows(subscription)) {
      const remaining = remainingPercent(window.used_percent);
      if (tightest === null || remaining < tightest.remaining) {
        tightest = {
          subscription,
          window,
          remaining,
          name: `${providerDisplayName(subscription.provider)} ${formatWindowTitle(window.title, window)}`,
        };
      }
    }
  }
  return tightest;
}

/**
 * Where remaining would stand now at an even burn rate, 0–100, or null where the pace rule does
 * not answer (ADR 0035): no cadence or reset, a balance, or too little elapsed or used.
 */
export function evenPaceRemaining(window: QuotaWindow, now: Date): number | null {
  if (quotaPace(window, now).kind === "none") return null;
  const resetsAt = Date.parse(window.resets_at ?? "");
  const cadence = window.duration_seconds ?? 0;
  if (!Number.isFinite(resetsAt) || cadence <= 0) return null;
  const elapsed = (now.getTime() - (resetsAt - cadence * 1_000)) / (cadence * 1_000);
  return Math.max(0, Math.min(100, 100 - elapsed * 100));
}

export type ResetMark = {
  at: number;
  titles: string[];
  /** The band of the lowest window that refills at this instant. */
  tone: MeterTone;
};

export type ResetLane = { key: string; provider: string; name: string; resets: ResetMark[] };

export const RESET_HORIZON_MS = 7 * 86_400_000;

/**
 * One lane per current subscription with a refill in the next seven days, one mark per instant.
 * Windows that refill within the same hour share a mark, coloured by the lowest of them.
 */
export function nextResets(subscriptions: readonly Subscription[], now: Date): ResetLane[] {
  const lanes: ResetLane[] = [];
  for (const subscription of subscriptions) {
    if (!isCurrent(subscription, now)) continue;
    const marks = new Map<number, { at: number; titles: string[]; remaining: number }>();
    for (const window of subscription.snapshot.windows) {
      const at = Date.parse(window.resets_at ?? "");
      if (!Number.isFinite(at) || at <= now.getTime() || at > now.getTime() + RESET_HORIZON_MS) {
        continue;
      }
      const hour = Math.round(at / 3_600_000);
      const mark = marks.get(hour) ?? { at, titles: [], remaining: 100 };
      mark.titles.push(formatWindowTitle(window.title, window));
      mark.remaining = Math.min(mark.remaining, remainingPercent(window.used_percent));
      marks.set(hour, mark);
    }
    if (marks.size === 0) continue;
    lanes.push({
      key: subscription.key,
      provider: subscription.provider,
      name: providerDisplayName(subscription.provider),
      resets: [...marks.values()]
        .sort((left, right) => left.at - right.at)
        .map((mark) => ({ at: mark.at, titles: mark.titles, tone: meterTone(mark.remaining) })),
    });
  }
  return lanes;
}

/**
 * The agents whose Usage a subscription's windows are spent by. A provider without an agent of
 * its own (a credit or API key) has no attribution. Kept here rather than in the catalog while
 * only this estimate reads it.
 */
const SUBSCRIPTION_AGENTS: Readonly<Record<string, readonly string[]>> = {
  codex: ["codex"],
  claude: ["claude_code"],
  grok: ["grok"],
  cursor: ["cursor"],
  gemini: ["gemini"],
  copilot: ["copilot"],
  antigravity: ["antigravity"],
  opencode_go: ["opencode"],
};

export function subscriptionAgents(provider: string): readonly string[] {
  return SUBSCRIPTION_AGENTS[provider] ?? [];
}

/** Windows at least a day long have enough hourly Usage behind them to split by model. */
export const ATTRIBUTION_MINIMUM_SECONDS = 86_400;

/**
 * The local dates since a window opened, or null for a window too short to estimate, one with no
 * reset, or one that opened more than a year ago.
 */
export function windowAttributionRange(
  window: QuotaWindow,
  now: Date,
): { from: string; to: string } | null {
  const cadence = window.duration_seconds ?? 0;
  const resetsAt = Date.parse(window.resets_at ?? "");
  if (cadence < ATTRIBUTION_MINIMUM_SECONDS || !Number.isFinite(resetsAt)) return null;
  const opened = new Date(resetsAt - cadence * 1_000);
  if (opened.getTime() > now.getTime() || now.getTime() - opened.getTime() > 365 * 86_400_000) {
    return null;
  }
  return { from: localDate(opened), to: localDate(now) };
}

export type WindowShare = { row: ModelRow; share: number };

/**
 * An estimate of what used a window: the period tree since it opened, kept to the agents that
 * spend it, split by model. Whole local days, so the first day may include hours before it opened.
 */
export function windowAttribution(agents: AgentTreeView, provider: string): WindowShare[] {
  const spenders = new Set(subscriptionAgents(provider));
  const rows = foldModelRows(agents.filter((agent) => spenders.has(agent.agent)));
  const total = rows.reduce((sum, row) => sum + row.totals.total_tokens, 0);
  if (total <= 0) return [];
  return rows.map((row) => ({ row, share: row.totals.total_tokens / total }));
}
