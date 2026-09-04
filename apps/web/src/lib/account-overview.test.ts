import { remainingPercent } from "@gotry-io/quota-model";
import type { AccountSummaryRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import { afterEach, expect, it, vi } from "vitest";
import {
  accountStatusLine,
  devicesSummaryLine,
  githubLoginFromLabel,
  meterTone,
  meterToneForUsedPercent,
  providerMarkHue,
  subscriptionCardMeta,
  topUsageModel,
} from "./account-overview.ts";

afterEach(() => {
  vi.useRealTimers();
});

const emptyPeriod: UsagePeriodRead = {
  totals: {
    total_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 0,
  },
  cost: {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: "0",
    catalog_revision: "catalog_1",
    calculated_rows: 0,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
  },
  partial: false,
  agents: [],
};

type ModelLeaf = UsagePeriodRead["agents"][number]["providers"][number]["models"][number];

function model(name: string, tokens: number): ModelLeaf {
  return {
    model: name,
    totals: { ...emptyPeriod.totals, total_tokens: tokens, input_tokens: tokens, output_tokens: 0 },
    cost: emptyPeriod.cost,
  };
}

it("classifies remaining-quota meter thresholds", () => {
  expect(meterTone(100)).toBe("good");
  expect(meterTone(40)).toBe("good");
  expect(meterTone(39.9)).toBe("warn");
  expect(meterTone(15)).toBe("warn");
  expect(meterTone(14.9)).toBe("critical");
  expect(meterTone(0)).toBe("critical");
  expect(meterToneForUsedPercent(32)).toBe("good");
  expect(remainingPercent(32)).toBe(68);
});

it("hashes a provider id to a stable hue", () => {
  expect(providerMarkHue("codex")).toBe(providerMarkHue("codex"));
  expect(providerMarkHue("codex")).not.toBe(providerMarkHue("claude"));
  expect(providerMarkHue("codex")).toBeGreaterThanOrEqual(0);
  expect(providerMarkHue("codex")).toBeLessThan(360);
});

it("treats GitHub logins as avatar keys and rejects fallback labels", () => {
  expect(githubLoginFromLabel("octocat")).toBe("octocat");
  expect(githubLoginFromLabel("Account")).toBeNull();
  expect(githubLoginFromLabel("GitHub account")).toBeNull();
  expect(githubLoginFromLabel("Ada Lovelace")).toBeNull();
});

it("picks the 30-day model with the most tokens", () => {
  const period: UsagePeriodRead = {
    ...emptyPeriod,
    agents: [
      {
        agent: "codex",
        providers: [
          {
            provider: "openai",
            models: [model("gpt-5.5", 100), model("gpt-5.6-sol", 400), model("other", 50)],
          },
        ],
      },
    ],
  };
  expect(topUsageModel(period)).toBe("gpt-5.6-sol");
  expect(topUsageModel(emptyPeriod)).toBe("—");
  expect(topUsageModel(null)).toBe("—");
});

it("names account freshness and how many devices are reporting", () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T09:40:00Z"));
  const summary = {
    protocol_version: 6,
    account: { account_id: "a", display_label: "octocat", created_at: "2026-01-01T00:00:00Z" },
    devices: [
      {
        id: "device_1",
        display_name: "Studio Mac",
        platform: "macos",
        last_seen_at: "2026-08-12T09:31:00Z",
        last_observed_at: "2026-08-12T09:30:00Z",
      },
      {
        id: "device_2",
        display_name: "Kitchen Mac",
        platform: "macos",
        last_seen_at: "2026-08-12T02:00:00Z",
        last_observed_at: "2026-08-12T02:00:00Z",
      },
    ],
    subscriptions: [],
    usage: {
      today: emptyPeriod,
      last_7_days: emptyPeriod,
      last_30_days: emptyPeriod,
      all: emptyPeriod,
    },
    pricing_revision: "p",
    model_catalog_revision: "m",
  } as AccountSummaryRead;

  expect(accountStatusLine(summary)).toBe("Updated 9m ago · 2 devices reporting");
  expect(devicesSummaryLine(summary.devices)).toBe(
    "2 devices · all reporting · Kitchen Mac · Idle",
  );
  expect(devicesSummaryLine([])).toBe("No devices yet");
  expect(subscriptionCardMeta("Studio Mac", "2026-08-12T09:39:00Z")).toBe("Studio Mac · 1m ago");
});
