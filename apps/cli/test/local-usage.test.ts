import type { BillingAgent } from "@gotry-io/quota-protocol";
import type { NormalizedUsageEvent, UsageScanResult } from "@gotry-io/quota-provider";
import { describe, expect, it, vi } from "vitest";
import { collectLocalUsage, type LocalUsageDependencies } from "../src/account/local-usage.ts";

describe("local Usage", () => {
  it("collects and calculates a typed report without an account session", async () => {
    const dependencies = dependenciesWithEvents({
      codex: [event("codex", "2026-08-10T02:10:00Z", 12)],
      claude_code: [event("claude_code", "2026-08-09T01:10:00Z", 8)],
    });

    const report = await collectLocalUsage(new Date("2026-08-10T02:30:00Z"), dependencies);

    expect(report).toMatchObject({
      protocol_version: 2,
      aggregation_timezone: "UTC",
      range: { from: "2026-07-12", to: "2026-08-10" },
      status: "partial",
      totals: { input_tokens: 20, output_tokens: 4, requests: 2 },
      cost: { status: "unavailable", unpriced_rows: 2 },
    });
    expect(report.breakdowns.map((item) => item.key)).toEqual(["codex", "claude_code"]);
    expect(dependencies.scan).toHaveBeenCalledTimes(2);
  });

  it("reports unavailable instead of fabricating zero Usage when every scan fails", async () => {
    const dependencies = dependenciesWithEvents({ codex: [], claude_code: [] });
    vi.mocked(dependencies.scan).mockRejectedValue(new Error("unreadable"));

    const report = await collectLocalUsage(new Date("2026-08-10T02:30:00Z"), dependencies);

    expect(report).toMatchObject({
      status: "unavailable",
      aggregation_timezone: null,
      totals: null,
      cost: null,
      coverage: [],
    });
  });
});

function dependenciesWithEvents(
  events: Record<BillingAgent, NormalizedUsageEvent[]>,
): LocalUsageDependencies & { scan: ReturnType<typeof vi.fn> } {
  return {
    aggregationTimezone: () => "UTC",
    pricingCatalog: async () => null,
    scan: vi.fn(async (agent: BillingAgent, startAt: string, endAt: string) =>
      scanResult(agent, startAt, endAt, events[agent]),
    ),
  };
}

function scanResult(
  agent: BillingAgent,
  startAt: string,
  endAt: string,
  events: readonly NormalizedUsageEvent[],
): UsageScanResult {
  return {
    records: events.map((value, index) => ({
      event: value,
      cursor: {
        source_file_id: `opaque-${agent}-${index}`,
        byte_offset: index,
        record_hash: `hash-${agent}-${index}`,
      },
    })),
    coverage: { agent, start_at: startAt, end_at: endAt, status: "complete", reasons: [] },
    scanned_source_count: 1,
  };
}

function event(agent: BillingAgent, occurredAt: string, inputTokens: number): NormalizedUsageEvent {
  return {
    occurred_at: occurredAt,
    agent,
    model: agent === "codex" ? "gpt-5.6" : "claude-sonnet-4-6",
    billing_channel: agent === "codex" ? "openai_direct" : "anthropic_direct",
    channel_source: "agent_default",
    input_tokens: inputTokens,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 2,
    reasoning_tokens: 1,
    requests: 1,
    context_bucket: "le_128k",
    service_tier: "standard",
    speed: "standard",
    inference_geo: "global",
    billable_tools: {},
    source_cost_covered_requests: 0,
  };
}
