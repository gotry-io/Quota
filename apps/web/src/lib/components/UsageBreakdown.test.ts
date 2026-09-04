import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { agentDisplayName } from "@gotry-io/quota-protocol";
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import UsageBreakdown from "./UsageBreakdown.svelte";

afterEach(cleanup);

function totals(input: number, output: number) {
  return {
    total_tokens: input + output,
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 1,
  };
}

function cost(microusd: string) {
  return {
    mode: "auto" as const,
    basis: "calculated" as const,
    status: "complete" as const,
    amount_microusd: microusd,
    catalog_revision: "2026-08-01",
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [] as string[],
    unpriced: [] as UsagePeriodRead["cost"]["unpriced"],
  };
}

function model(name: string) {
  return { model: name, totals: totals(80, 20), cost: cost("10000") };
}

function period(overrides: Partial<UsagePeriodRead> = {}): UsagePeriodRead {
  return {
    totals: totals(80, 20),
    cost: cost("10000"),
    partial: false,
    agents: [
      {
        agent: "codex",
        providers: [{ provider: "openai", models: [model("gpt-5")] }],
      },
    ],
    ...overrides,
  } as UsagePeriodRead;
}

it("maps agent ids to their display names", () => {
  const agents = ["codex", "claude_code", "grok", "opencode", "pi", "cursor"] as const;
  render(UsageBreakdown, {
    period: period({
      agents: agents.map((agent) => ({
        agent,
        providers: [{ provider: "openai", models: [model(`${agent}-model`)] }],
      })),
    }),
  });

  expect(agentDisplayName("codex")).toBe("Codex");
  expect(agentDisplayName("claude_code")).toBe("Claude Code");
  expect(agentDisplayName("grok")).toBe("Grok");
  expect(agentDisplayName("opencode")).toBe("OpenCode");
  expect(agentDisplayName("pi")).toBe("Pi");
  expect(agentDisplayName("cursor")).toBe("Cursor");
  for (const agent of agents) {
    expect(screen.getByRole("rowheader", { name: agentDisplayName(agent) })).toBeTruthy();
  }
  expect(screen.queryByRole("rowheader", { name: "codex" })).toBeNull();
});

it("shows Other for the overflow model leaf", () => {
  render(UsageBreakdown, {
    period: period({
      agents: [
        {
          agent: "codex",
          providers: [{ provider: "openai", models: [model("other")] }],
        },
      ],
    }),
  });
  expect(screen.getByRole("rowheader", { name: "Other" })).toBeTruthy();
  expect(screen.queryByRole("rowheader", { name: "other" })).toBeNull();
});

it("states the empty period", () => {
  render(UsageBreakdown, { period: period({ agents: [], partial: false }) });
  expect(screen.getByText("No Usage in this period.")).toBeTruthy();
  expect(screen.queryByRole("table")).toBeNull();
});

it("states incomplete hours without replacing the tree", () => {
  render(UsageBreakdown, { period: period({ partial: true }) });
  expect(screen.getByText("Some hours in this period were scanned incompletely.")).toBeTruthy();
  expect(screen.getByRole("rowheader", { name: "Codex" })).toBeTruthy();
  expect(screen.getByRole("rowheader", { name: "gpt-5" })).toBeTruthy();
});

it("folds models past five and expands them", () => {
  const models = ["m1", "m2", "m3", "m4", "m5", "m6", "m7"].map(model);
  render(UsageBreakdown, {
    period: period({
      agents: [{ agent: "codex", providers: [{ provider: "openai", models }] }],
    }),
  });

  expect(screen.getByRole("rowheader", { name: "m5" })).toBeTruthy();
  expect(screen.queryByRole("rowheader", { name: "m6" })).toBeNull();
  const more = screen.getByRole("button", { name: "Show 2 more" });
  expect(more.getAttribute("aria-expanded")).toBe("false");

  more.focus();
  fireEvent.click(more);
  expect(screen.getByRole("rowheader", { name: "m6" })).toBeTruthy();
  expect(screen.getByRole("rowheader", { name: "m7" })).toBeTruthy();
  const fewer = screen.getByRole("button", { name: "Show fewer" });
  expect(fewer.getAttribute("aria-expanded")).toBe("true");
  expect(document.activeElement).toBe(fewer);

  fireEvent.click(fewer);
  expect(screen.queryByRole("rowheader", { name: "m6" })).toBeNull();
  const collapsed = screen.getByRole("button", { name: "Show 2 more" });
  expect(collapsed.getAttribute("aria-expanded")).toBe("false");
  expect(document.activeElement).toBe(collapsed);
});
