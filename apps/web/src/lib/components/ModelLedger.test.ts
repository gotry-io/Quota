import { cleanup, render, screen, within } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import { foldModelRows } from "$lib/model-usage";
import ModelLedger from "./ModelLedger.svelte";

afterEach(cleanup);

function leaf(model: string, tokens: number) {
  return {
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
    cost: { amount_microusd: String(tokens), status: "complete" },
  };
}

const current = foldModelRows([
  {
    agent: "claude_code",
    providers: [{ provider: "anthropic", models: [leaf("sonnet", 500), leaf("opus", 200)] }],
  },
  { agent: "opencode", providers: [{ provider: "anthropic", models: [leaf("sonnet", 100)] }] },
  {
    agent: "codex",
    providers: [
      {
        provider: "openai",
        models: [leaf("m3", 60), leaf("m4", 50), leaf("m5", 40), leaf("m6", 30), leaf("m7", 20)],
      },
    ],
  },
]);
const previous = foldModelRows([
  {
    agent: "claude_code",
    providers: [{ provider: "anthropic", models: [leaf("sonnet", 300), leaf("opus", 700)] }],
  },
]);

function mount(limit: number | null) {
  return render(ModelLedger, {
    rows: current,
    previous,
    colors: new Map(),
    limit,
    caption: "Models",
    rowHref: (row: { model: string }) => `/my/models?model=${row.model}`,
    moreHref: "/my/models",
  });
}

it("merges one model across the agents that sent to it and names both", () => {
  mount(null);
  const row = screen.getByRole("rowheader", { name: /^sonnet/ }).closest("tr") as HTMLElement;
  expect(within(row).getByText("Claude Code")).toBeTruthy();
  expect(within(row).getByText("OpenCode")).toBeTruthy();
  expect(within(row).getByText("600")).toBeTruthy();
  expect(screen.getAllByRole("rowheader", { name: /^sonnet/ })).toHaveLength(1);
});

it("states each share's move in points against the previous period, and a model it lacked as New", () => {
  mount(null);
  const cells = (name: RegExp) =>
    (
      (screen.getByRole("rowheader", { name }).closest("tr") as HTMLElement).textContent ?? ""
    ).replace(/\s+/g, " ");
  // sonnet: 600 / 1000 now against 300 / 1000 before.
  expect(cells(/^sonnet/)).toContain("↑ 30 pts");
  expect(cells(/^opus/)).toContain("↓ 50 pts");
  expect(cells(/^m3/)).toContain("New");
});

it("shows six rows and folds the rest into N more models with their total", () => {
  mount(6);
  expect(screen.getAllByRole("rowheader")).toHaveLength(7);
  const more = screen.getByRole("link", { name: "1 more model" });
  expect(more.closest("tr")?.textContent).toContain("20");
});
