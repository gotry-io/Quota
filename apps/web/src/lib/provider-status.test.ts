import { expect, it, vi } from "vitest";
import { fetchProviderStatus, showsProviderStatusDot } from "./provider-status.ts";

it("draws a dot for minor and above, never for none or unknown", () => {
  expect(showsProviderStatusDot("none")).toBe(false);
  expect(showsProviderStatusDot("unknown")).toBe(false);
  expect(showsProviderStatusDot("minor")).toBe(true);
  expect(showsProviderStatusDot("major")).toBe(true);
  expect(showsProviderStatusDot("critical")).toBe(true);
});

it("returns the catalog rows a status read names", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      return new Response(
        JSON.stringify({
          providers: [
            {
              id: "codex",
              indicator: "minor",
              description: "Partial System Outage",
              checked_at: "2026-09-06T00:00:00Z",
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }),
  );
  expect(await fetchProviderStatus()).toEqual([
    {
      id: "codex",
      indicator: "minor",
      description: "Partial System Outage",
      checked_at: "2026-09-06T00:00:00Z",
    },
  ]);
  vi.unstubAllGlobals();
});
