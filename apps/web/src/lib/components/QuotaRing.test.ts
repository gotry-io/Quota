import { cleanup, render } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import QuotaRing from "./QuotaRing.svelte";

afterEach(cleanup);

function arc(remaining: number): { dash: string | null; ring: string } | null {
  const { container } = render(QuotaRing, { remaining });
  const svg = container.querySelector("svg");
  const path = container.querySelector(".quota-ring-arc");
  const ring = svg?.getAttribute("class") ?? "";
  cleanup();
  return path ? { dash: path.getAttribute("stroke-dasharray"), ring } : null;
}

it("draws no arc at zero, half the ring at 50, and the whole ring at 100, in the band's colour", () => {
  // A round cap on an empty dash is still a dot, so zero draws nothing at all.
  expect(arc(0)).toBeNull();
  expect(arc(50)).toEqual({ dash: "50 100", ring: expect.stringContaining("quota-ring-good") });
  expect(arc(100)).toEqual({ dash: "100 100", ring: expect.stringContaining("quota-ring-good") });
  expect(arc(39)?.ring).toContain("quota-ring-warn");
  expect(arc(14)?.ring).toContain("quota-ring-critical");
});
