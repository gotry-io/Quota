import { expect, it } from "vitest";
import { showsProviderStatusDot } from "./provider-status.ts";

it("draws a dot for minor and above, never for none or unknown", () => {
  expect(showsProviderStatusDot("none")).toBe(false);
  expect(showsProviderStatusDot("unknown")).toBe(false);
  expect(showsProviderStatusDot("minor")).toBe(true);
  expect(showsProviderStatusDot("major")).toBe(true);
  expect(showsProviderStatusDot("critical")).toBe(true);
});
