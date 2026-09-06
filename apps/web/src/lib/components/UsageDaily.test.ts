import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import { usageDailyRows } from "$lib/usage-metrics.ts";
import UsageDaily from "./UsageDaily.svelte";

afterEach(cleanup);

function day(date: string, input: number, cacheRead: number, output: number, amount: string) {
  return {
    date,
    totals: {
      total_tokens: input + output,
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cacheRead,
      cache_write_input_tokens: 0,
      reasoning_tokens: Math.floor(output / 2),
      messages: 3,
    },
    cost: { amount_microusd: amount, status: "complete", basis: "calculated" },
    partial: false,
  };
}

function rows() {
  return usageDailyRows(
    [day("2026-09-04", 800, 600, 200, "40000"), day("2026-09-05", 400, 100, 100, "20000")],
    "7d",
    "2026-09-05",
  );
}

it("keeps the daily table behind a disclosure and names every column", async () => {
  render(UsageDaily, { rows: rows() });

  expect(screen.queryByRole("table")).toBeNull();
  const toggle = screen.getByRole("button", { name: "Show daily breakdown" });
  expect(toggle.getAttribute("aria-expanded")).toBe("false");

  await fireEvent.click(toggle);

  for (const column of ["Date", "Total", "In", "Out", "Cached", "Reasoning", "Messages", "Cost"]) {
    expect(screen.getByRole("columnheader", { name: column })).toBeTruthy();
  }
  expect(screen.getByRole("rowheader", { name: "2026-09-05" })).toBeTruthy();
  // Seven days of the period, including the five nothing was reported for.
  expect(screen.getAllByRole("row").length).toBe(8);
});

it("switches what the bars measure without redrawing the table", async () => {
  render(UsageDaily, { rows: rows() });

  const tokens = screen.getByRole("button", { name: "Tokens" });
  const cost = screen.getByRole("button", { name: "Cost" });
  expect(tokens.getAttribute("aria-pressed")).toBe("true");
  expect(screen.getByText("Cached input")).toBeTruthy();

  await fireEvent.click(cost);

  expect(cost.getAttribute("aria-pressed")).toBe("true");
  expect(tokens.getAttribute("aria-pressed")).toBe("false");
  // A cost bar is one amount, so the token legend goes with the segments it described.
  expect(screen.queryByText("Cached input")).toBeNull();
});

it("says so when a period reported no Usage at all", () => {
  render(UsageDaily, { rows: usageDailyRows([], "7d", "2026-09-05") });
  expect(screen.getByText("No Usage on these days.")).toBeTruthy();
});
