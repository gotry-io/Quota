import { MAXIMUM_USAGE_PERIOD_LEAVES, MODEL_CATALOG } from "@gotry-io/quota-protocol";
import type { StoredUsageDailyRow } from "@gotry-io/relay-core";
import { describe, expect, it } from "vitest";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";
import {
  type AccountUsageBoundary,
  buildAccountUsage,
  buildActivityDays,
} from "../src/usage-summary.ts";

const today = "2026-08-10";

function accountUsage(
  rows: readonly StoredUsageDailyRow[],
  modelCatalog = MODEL_CATALOG,
  boundaries: AccountUsageBoundary[] = [],
) {
  return buildAccountUsage({
    daily: rows,
    boundaries,
    days: {
      today: { from: today, to: today },
      last_7_days: { from: "2026-08-04", to: today },
      last_30_days: { from: "2026-07-12", to: today },
    },
    catalog: PRICING_CATALOG,
    modelCatalog,
  });
}

/** Leaf models of a period, flattened the way a reader walks the tree. */
function leaves(period: ReturnType<typeof accountUsage>["all"]) {
  return period.agents.flatMap((agent) =>
    agent.providers.flatMap((provider) =>
      provider.models.map((model) => ({
        agent: agent.agent,
        provider: provider.provider,
        model: model.model,
        messages: model.totals.messages,
      })),
    ),
  );
}

describe("Account Usage periods", () => {
  it("selects each period by date without pricing a row more than once", () => {
    const rows = Array.from({ length: 796 }, usageRow);
    const usage = accountUsage(rows);

    expect(usage.all.totals.messages).toBe(rows.length);
    expect(usage.all.cost).toMatchObject({
      status: "complete",
      calculated_rows: rows.length,
      unpriced_rows: 0,
    });
    // Each window is a subset of the one outside it, and the tree under a period accounts for
    // every request that period's totals claim.
    expect(usage.today.totals.messages).toBeLessThanOrEqual(usage.last_7_days.totals.messages);
    expect(usage.last_7_days.totals.messages).toBeLessThanOrEqual(
      usage.last_30_days.totals.messages,
    );
    expect(usage.last_30_days.totals.messages).toBeLessThanOrEqual(usage.all.totals.messages);
    for (const period of [usage.today, usage.last_7_days, usage.last_30_days, usage.all]) {
      expect(leaves(period).reduce((total, leaf) => total + leaf.messages, 0)).toBe(
        period.totals.messages,
      );
    }
  });

  it("folds a boundary's hours into the periods that name it and nothing else", () => {
    // The hours between local midnight and the UTC day it cuts belong to `today` alone: every
    // wider period already covers that UTC day through the rollup row beside them.
    const usage = accountUsage([{ ...usageRow(null, 0), date: today }], MODEL_CATALOG, [
      { periods: ["today"], rows: [{ ...usageRow(null, 1), date: "2026-08-09", requests: 4 }] },
      {
        periods: ["today", "last_7_days", "last_30_days"],
        rows: [{ ...usageRow(null, 0), date: "2026-08-11", requests: 2 }],
      },
    ]);

    expect(usage.today.totals.messages).toBe(7);
    expect(usage.last_7_days.totals.messages).toBe(3);
    expect(usage.last_30_days.totals.messages).toBe(3);
    // `all` is the rollup entire, so a boundary row never reaches it twice.
    expect(usage.all.totals.messages).toBe(1);
  });

  it("marks a period partial when any hour behind it was scanned incompletely", () => {
    const partialToday = { ...usageRow(null, 0), date: today, partial_hours: 2 };
    const usage = accountUsage([usageRow(null, 1), partialToday]);
    expect(usage.today.partial).toBe(true);
    expect(usage.all.partial).toBe(true);

    expect(accountUsage([usageRow(null, 1)]).all.partial).toBe(false);
  });

  it("keeps every request when the tree exceeds its leaf bound", () => {
    const rows = Array.from({ length: MAXIMUM_USAGE_PERIOD_LEAVES + 40 }, (_, index) => ({
      ...usageRow(null, index, true),
      date: today,
    }));
    const usage = accountUsage(rows);
    const found = leaves(usage.all);

    expect(found.length).toBeLessThanOrEqual(MAXIMUM_USAGE_PERIOD_LEAVES);
    expect(found.some((leaf) => leaf.model === "other")).toBe(true);
    expect(found.reduce((total, leaf) => total + leaf.messages, 0)).toBe(rows.length);
    expect(usage.all.totals.messages).toBe(rows.length);
  });

  it("normalizes a leaf's model without changing what it totals or costs", () => {
    const row = { ...usageRow(null, 0), model: "GPT-5.5[1m]" };
    const withoutAlias = {
      ...MODEL_CATALOG,
      revision: "model-before-alias",
      models: MODEL_CATALOG.models.map((model) =>
        model.canonical_id === "gpt-5.5" ? { ...model, aliases: [] } : model,
      ),
    };

    const before = accountUsage([row], withoutAlias);
    const after = accountUsage([row]);
    expect(leaves(before.all).map((leaf) => leaf.model)).toEqual(["GPT-5.5[1m]"]);
    expect(leaves(after.all).map((leaf) => leaf.model)).toEqual(["gpt-5.5"]);
    expect(after.all.totals).toEqual(before.all.totals);
    expect(after.all.cost).toEqual(before.all.cost);
    expect(row.model).toBe("GPT-5.5[1m]");
  });

  it("keeps a raw model separate when it collides with a display name", () => {
    const usage = accountUsage([
      { ...usageRow(null, 0), model: "gpt-5.5" },
      { ...usageRow(null, 0), model: "GPT-5.5", service_tier: "priority" },
    ]);
    expect(leaves(usage.all).map((leaf) => leaf.model)).toEqual(["GPT-5.5", "gpt-5.5"]);
  });

  it("keeps opaque punctuation in a leaf's model and refuses text the contract bounds", () => {
    for (const model of ["provider:model[1m]", "😀".repeat(128)]) {
      expect(leaves(accountUsage([{ ...usageRow(null, 0), model }]).all)[0]?.model).toBe(model);
    }
    for (const model of ["😀".repeat(129), "model\nwith-control"]) {
      expect(() => accountUsage([{ ...usageRow(null, 0), model }])).toThrow();
    }
  });
});

describe("Account Usage activity", () => {
  it("answers one entry per UTC date that has Usage, in date order", () => {
    const rows = [
      { ...usageRow(null, 0), date: "2026-08-10" },
      { ...usageRow(null, 1), date: "2026-08-08" },
      { ...usageRow(null, 2), date: "2026-08-08", model: "gpt-5.6-luna" },
    ];
    const days = buildActivityDays({ rows, catalog: PRICING_CATALOG });

    expect(days.map((day) => day.date)).toEqual(["2026-08-08", "2026-08-10"]);
    expect(days[0]?.totals.messages).toBe(2);
    expect(days[1]?.totals.messages).toBe(1);
    expect(days.every((day) => day.partial === false)).toBe(true);
  });

  it("reports a day as partial when an hour behind it came up short", () => {
    const days = buildActivityDays({
      rows: [{ ...usageRow(null, 0), date: "2026-08-10", partial_hours: 1 }],
      catalog: PRICING_CATALOG,
    });
    expect(days[0]?.partial).toBe(true);
  });
});

function usageRow(_: unknown, index = 0, uniqueModel = false): StoredUsageDailyRow {
  const codex = index % 2 === 0;
  return {
    device_id: "device-production-sized",
    date: `2026-07-${String(12 + (Math.floor(index / 34) % 20)).padStart(2, "0")}`,
    agent: codex ? "codex" : "claude_code",
    billing_channel: codex ? "openai_direct" : "anthropic_direct",
    channel_source: "agent_default",
    model: uniqueModel ? `model-${index}` : codex ? "gpt-5.6-sol" : "claude-opus-4-6",
    context_bucket: "le_128k",
    service_tier: "unknown",
    speed: "unknown",
    inference_geo: "unknown",
    input_tokens: 100,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 50,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
    partial_hours: 0,
  };
}
