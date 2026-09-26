import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { expect, it } from "vitest";
import {
  askingCopy,
  FOLLOW_UP_READS,
  type FollowUpDeps,
  followCollectionDemand,
  staleDemand,
} from "./collection-demand.ts";

const NOW = Date.parse("2026-08-12T09:40:00Z");
const REQUESTED_AT = Date.parse("2026-08-12T09:40:02Z");

function summary(sources: Record<string, Array<[string, number]>>): AccountSummaryRead {
  return {
    devices: [
      { id: "mac_1", platform: "macos" },
      { id: "mac_2", platform: "macos" },
      { id: "phone_1", platform: "ios" },
    ],
    subscriptions: Object.entries(sources).map(([key, rows]) => ({
      key,
      provider: key.split(":")[0],
      sources: rows.map(([device_id, ms]) => ({
        device_id,
        observed_at: new Date(ms).toISOString(),
      })),
    })),
  } as unknown as AccountSummaryRead;
}

const stale = summary({ claude: [["mac_1", NOW - 600_000]] });
const answered = summary({ claude: [["mac_1", REQUESTED_AT + 20_000]] });

function relay(reads: AccountSummaryRead[], requestedAt: number | null) {
  let current = stale;
  const calls = { requests: 0, reads: 0, waiting: [] as number[] };
  const deps: FollowUpDeps = {
    summary: () => current,
    requestCollection: async () => {
      calls.requests += 1;
      return requestedAt;
    },
    readSummary: async () => {
      current = reads[Math.min(calls.reads, reads.length - 1)] ?? current;
      calls.reads += 1;
    },
    wait: async () => {},
    now: () => NOW,
    onWaiting: (macs) => calls.waiting.push(macs),
  };
  return { deps, calls };
}

it("asks about a Mac reading older than two minutes or its provider's floor, never another device's", () => {
  const demand = staleDemand(
    summary({
      "codex:fresh": [["mac_1", NOW - 60_000]],
      "codex:old": [["mac_2", NOW - 121_000]],
      "claude:inside-floor": [["mac_1", NOW - 179_000]],
      "claude:old": [["mac_1", NOW - 181_000]],
      "codex:phone": [["phone_1", NOW - 600_000]],
      "codex:covered": [
        ["mac_1", NOW - 600_000],
        ["mac_2", NOW],
      ],
    }),
    NOW,
  );
  expect(demand && [...demand.keys]).toEqual(["codex:old", "claude:old"]);
  expect(demand?.macCount).toBe(2);
  expect(staleDemand(summary({ "codex:fresh": [["mac_1", NOW - 60_000]] }), NOW)).toBeNull();
  expect(askingCopy(1)).toBe("Asking your Mac…");
  expect(askingCopy(2)).toBe("Asking your Macs…");
});

it("follows the summary until the Mac answers, and gives up after three minutes", async () => {
  const quick = relay([stale, answered], REQUESTED_AT);
  await followCollectionDemand(quick.deps, new AbortController().signal);
  expect(quick.calls).toEqual({ requests: 1, reads: 2, waiting: [1] });

  const never = relay([stale], REQUESTED_AT);
  await followCollectionDemand(never.deps, new AbortController().signal);
  expect(never.calls.reads).toBe(FOLLOW_UP_READS);
});

it("says nothing when Relay refuses, and stops reading once the tab is hidden", async () => {
  const refused = relay([stale], null);
  await followCollectionDemand(refused.deps, new AbortController().signal);
  expect(refused.calls).toEqual({ requests: 1, reads: 0, waiting: [] });

  const hidden = new AbortController();
  const background = relay([stale], REQUESTED_AT);
  background.deps.wait = async () => {
    hidden.abort();
  };
  await followCollectionDemand(background.deps, hidden.signal);
  expect(background.calls.reads).toBe(0);
});
