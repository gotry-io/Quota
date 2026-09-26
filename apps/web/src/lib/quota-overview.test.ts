import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { expect, it } from "vitest";
import { nextResets, windowAttribution, windowAttributionRange } from "./quota-overview.ts";

type Subscription = AccountSummaryRead["subscriptions"][number];

const now = new Date("2026-09-26T12:00:00Z");
const hours = (value: number) => new Date(now.getTime() + value * 3_600_000).toISOString();

function subscription(
  windows: Array<{ id: string; used: number; resets: string; duration: number }>,
): Subscription {
  return {
    key: "claude|fp|global|",
    provider: "claude",
    snapshot: {
      provider: "claude",
      account: { fingerprint: "fp", fingerprint_scope: "global" },
      windows: windows.map((window) => ({
        id: window.id,
        title: window.id,
        used_percent: window.used,
        resets_at: window.resets,
        duration_seconds: window.duration,
      })),
      status: "available",
      observed_at: now.toISOString(),
    },
    sources: [],
  } as unknown as Subscription;
}

it("puts windows that refill in the same hour on one ring coloured by the lowest, and leaves out the week after", () => {
  const lanes = nextResets(
    [
      subscription([
        { id: "Weekly", used: 30, resets: hours(50), duration: 604_800 },
        { id: "Weekly Opus", used: 90, resets: hours(50.2), duration: 604_800 },
        { id: "5 Hours", used: 10, resets: hours(3), duration: 18_000 },
        { id: "Monthly", used: 10, resets: hours(24 * 8), duration: 2_592_000 },
      ]),
    ],
    now,
  );
  expect(lanes[0]?.resets.map((mark) => [mark.titles, mark.tone])).toEqual([
    [["5 Hours"], "good"],
    [["Weekly", "Weekly Opus"], "critical"],
  ]);
});

it("estimates a window from its own agents' Usage only, and not for a window under a day", () => {
  const leaf = (model: string, tokens: number) => ({
    model,
    totals: {
      total_tokens: tokens,
      input_tokens: tokens,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      reasoning_tokens: 0,
      messages: 1,
    },
    cost: { amount_microusd: null, status: "unavailable" },
  });
  const shares = windowAttribution(
    [
      {
        agent: "claude_code",
        providers: [{ provider: "anthropic", models: [leaf("opus", 300), leaf("haiku", 100)] }],
      },
      { agent: "opencode", providers: [{ provider: "anthropic", models: [leaf("opus", 5_000)] }] },
    ],
    "claude",
  );
  expect(shares.map((item) => [item.row.model, item.share])).toEqual([
    ["opus", 0.75],
    ["haiku", 0.25],
  ]);
  const window = {
    id: "w",
    title: "w",
    used_percent: 1,
    resets_at: hours(3),
    duration_seconds: 18_000,
  };
  expect(windowAttributionRange(window, now)).toBeNull();
});
