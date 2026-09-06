import { PUBLIC_ACTIVITY_DAYS, type PublicUsageResponse } from "@gotry-io/quota-protocol";
import { expect, it } from "vitest";
import {
  buildPublicActivityModel,
  handleProblem,
  hasUsage,
  publicProfileSummary,
  sharePercent,
} from "./public-profile.ts";
import { shareCardModel } from "./share-card.ts";

it("says why a handle cannot be published, and nothing when it can", () => {
  expect(handleProblem("kyle")).toBeNull();
  expect(handleProblem("kyle-2")).toBeNull();
  expect(handleProblem("")).toBe("Choose a handle to publish this page.");
  expect(handleProblem("my")).toBe("That handle is reserved.");
  expect(handleProblem("support")).toBe("That handle is reserved.");
  expect(handleProblem("Kyle")).toMatch(/lowercase letters/);
  expect(handleProblem("ab")).toMatch(/3 to 30/);
});

it("draws a full year of Sunday-first weeks, with absent days at level 0", () => {
  const model = buildPublicActivityModel(
    [
      { date: "2026-09-06", level: 4 },
      { date: "2026-09-01", level: 2 },
    ],
    "2026-09-06",
  );

  expect(model.to).toBe("2026-09-06");
  expect(model.from).toBe("2025-09-07");
  expect(model.cells.length % 7).toBe(0);
  expect(model.cells.length / 7).toBe(model.weeks);
  expect(model.cells.filter((cell) => !cell.outside)).toHaveLength(PUBLIC_ACTIVITY_DAYS);
  expect(model.cells.find((cell) => cell.date === "2026-09-06")?.level).toBe(4);
  expect(model.cells.find((cell) => cell.date === "2026-09-01")?.level).toBe(2);
  expect(model.cells.find((cell) => cell.date === "2026-09-02")?.level).toBe(0);
  // Padding days after today are inert rather than empty cells with a level of their own.
  expect(model.cells.at(-1)?.outside).toBe(true);
});

it("prints a share as a percentage, keeping a tenth only when there is one", () => {
  expect(sharePercent(1_000)).toBe("100%");
  expect(sharePercent(500)).toBe("50%");
  expect(sharePercent(125)).toBe("12.5%");
  expect(sharePercent(0)).toBe("0%");
});

it("summarizes a page in one sentence that names no account, device, or quota", () => {
  const summary = publicProfileSummary(profile());
  expect(summary).toBe(
    "kyle used 11.4M tokens across 4.1K coding-agent messages in the last 30 days, on Quota.",
  );
  for (const forbidden of ["device", "quota.gotry.io/my", "account", "remaining"]) {
    expect(summary.toLowerCase()).not.toContain(forbidden);
  }
});

it("knows a period with nothing in it", () => {
  expect(hasUsage(profile().last_30_days)).toBe(true);
  expect(
    hasUsage({
      totals: { total_tokens: 0, input_tokens: 0, output_tokens: 0, messages: 0 },
      providers: [],
    }),
  ).toBe(false);
});

it("builds a share card from the last 30 days, and names cost only when the page does", () => {
  const card = shareCardModel(profile());
  expect(card.handle).toBe("kyle");
  expect(card.url).toBe("https://quota.gotry.io/u/kyle");
  expect(card.period).toBe("Last 30 days");
  expect(card.stats).toEqual([
    { label: "Tokens", value: "11.4M" },
    { label: "Messages", value: "4.1K" },
    { label: "API-equivalent", value: "$8.50" },
  ]);
  expect(card.bars).toEqual([
    { label: "Anthropic", permille: 560, share: "56%" },
    { label: "OpenAI", permille: 440, share: "44%" },
  ]);

  const quiet = profile();
  delete quiet.last_30_days.cost;
  expect(shareCardModel(quiet).stats.map((stat) => stat.label)).toEqual(["Tokens", "Messages"]);
});

function profile(): PublicUsageResponse {
  return {
    protocol_version: 6,
    handle: "kyle",
    published_at: "2026-06-01T09:00:00Z",
    generated_at: "2026-09-06T12:00:00Z",
    last_30_days: {
      totals: {
        total_tokens: 11_420_000,
        input_tokens: 8_640_000,
        output_tokens: 2_780_000,
        messages: 4_120,
      },
      cost: { amount_microusd: "8503200", status: "complete" },
      providers: [
        { provider: "anthropic", total_tokens: 6_400_000, share_permille: 560 },
        { provider: "openai", total_tokens: 5_020_000, share_permille: 440 },
      ],
    },
    all: {
      totals: {
        total_tokens: 96_300_000,
        input_tokens: 72_100_000,
        output_tokens: 24_200_000,
        messages: 38_400,
      },
      providers: [{ provider: "anthropic", total_tokens: 96_300_000, share_permille: 1_000 }],
    },
    activity: [{ date: "2026-09-06", level: 4 }],
  };
}
