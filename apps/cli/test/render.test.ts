import type { QuotaCollectionReport } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import { renderText } from "../src/render.ts";

describe("text rendering", () => {
  it("groups quota data with a remaining meter and partial marker", () => {
    const report: QuotaCollectionReport = {
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "openrouter",
          outcome: "success",
          message: "Some provider sessions could not be collected.",
          snapshots: [
            {
              provider: "openrouter",
              account: {
                fingerprint: "openrouter_01",
                fingerprint_scope: "source",
                label: "OpenRouter ···test",
                plan: "API key",
              },
              windows: [
                {
                  id: "key_monthly",
                  title: "Monthly budget",
                  used_percent: 25,
                  remaining_value: 75,
                  limit_value: 100,
                  value_unit: "usd",
                  resets_at: "2026-09-01T00:00:00Z",
                },
              ],
              source: "openrouter_api",
              status: "available",
              observed_at: "2026-08-02T12:00:00Z",
            },
          ],
        },
      ],
    };

    const output = renderText(report);
    expect(output).toContain("┌─ OpenRouter ────");
    expect(output).toContain("└────");
    expect(output).toContain("OpenRouter ···test · API key");
    expect(output).toContain("████");
    expect(output).toContain("75% left · $75 / $100 · 25% used");
    expect(output).toContain("Resets 2026-09-01T00:00:00Z");
    expect(output).toContain("Partial result");
  });

  it("renders a unitless balance without inventing a percent meter", () => {
    const report: QuotaCollectionReport = {
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "deepseek",
          outcome: "success",
          snapshots: [
            {
              provider: "deepseek",
              account: { fingerprint: "deepseek_01", fingerprint_scope: "source" },
              windows: [
                {
                  id: "balance_cny",
                  title: "CNY balance",
                  used_percent: 0,
                  remaining_value: 3.96,
                },
              ],
              source: "deepseek_balance_api",
              status: "available",
              observed_at: "2026-08-02T12:00:00Z",
            },
          ],
        },
      ],
    };

    const output = renderText(report);
    expect(output).toContain("CNY balance");
    expect(output).toContain("3.96 remaining");
    expect(output).not.toContain("100% left");
    expect(output).not.toContain("█");
  });

  it("renders an empty auto-selection with a doctor recovery hint", () => {
    const output = renderText({
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
      results: [],
    });
    expect(output).toContain("No configured providers found");
    expect(output).toContain("quotacli doctor");
  });

  it("strips provider-owned control characters from terminal text", () => {
    const output = renderText({
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "litellm",
          outcome: "success",
          snapshots: [
            {
              provider: "litellm",
              account: {
                fingerprint: "litellm_01",
                fingerprint_scope: "source",
                label: "\u001B[31mInjected\naccount",
              },
              windows: [{ id: "personal", title: "Personal\rBudget", used_percent: 10 }],
              source: "litellm_budget_api",
              status: "available",
              observed_at: "2026-08-02T12:00:00Z",
            },
          ],
        },
      ],
    });

    expect(output).toContain("Injected account");
    expect(output).toContain("Personal Budget");
    expect(output).not.toContain("\u001B");
    expect(output).not.toContain("31m");
    expect(output).not.toContain("Injected\naccount");
  });
});
