import { cleanup, render } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import { riverData } from "$lib/model-river";
import ModelRiver from "./ModelRiver.svelte";

afterEach(cleanup);

function cell(model: string, tokens: number) {
  return { model, total_tokens: tokens, cost_microusd: String(tokens) };
}

/** Five dates; Sep 3 has no Usage and Sep 5 is today. */
const series = {
  models: [
    { model: "big", provider: "anthropic" },
    { model: "small", provider: "openai" },
  ],
  days: [
    { date: "2026-09-01", partial: false, models: [cell("big", 60), cell("small", 40)] },
    { date: "2026-09-02", partial: false, models: [cell("big", 50), cell("small", 50)] },
    { date: "2026-09-04", partial: false, models: [cell("big", 70), cell("small", 30)] },
    { date: "2026-09-05", partial: true, models: [cell("big", 10)] },
  ],
};
const range = { from: "2026-09-01", to: "2026-09-05" };

function segments(container: HTMLElement, model: string): number {
  const d = container.querySelector(`path.band[data-model="${model}"]`)?.getAttribute("d") ?? "";
  return d.split("Z").filter((part) => part.trim() !== "").length;
}

function draw(mode: "amount" | "share", today = "2026-09-05") {
  return render(ModelRiver, {
    data: riverData(series, range, "tokens", today),
    mode,
    colors: new Map(),
    format: String,
    label: "Tokens by model",
  }).container;
}

it("breaks a Share band over a day with no Usage instead of dipping to zero", () => {
  expect(segments(draw("share"), "big")).toBe(2);
});

it("keeps an Amount band whole, meeting the baseline on the empty day", () => {
  expect(segments(draw("amount"), "big")).toBe(1);
});

it("hatches today as still running, and only when today is in the range", () => {
  expect(draw("amount").querySelector("rect.in-progress")).not.toBeNull();
  cleanup();
  expect(draw("amount", "2026-09-30").querySelector("rect.in-progress")).toBeNull();
});
