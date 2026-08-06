import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { QuotaCollectionReportSchema } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import { collectionExitCode, collectQuotaReport } from "../src/collection.ts";
import { ProviderCollectionError, type ProviderCollector } from "../src/contracts.ts";

const NOW = new Date("2026-08-02T12:00:00.000Z");

describe("collection report", () => {
  it("preserves provider order and partial success", async () => {
    const report = await collectQuotaReport({
      now: NOW,
      collectors: {
        codex: successCollector("codex", "chatgpt_usage_api"),
        claude: failingCollector("claude", "auth_required", "Sign in again"),
        grok: successCollector("grok", "grok_billing_api"),
        openrouter: successCollector("openrouter", "openrouter_api"),
        deepseek: successCollector("deepseek", "deepseek_balance_api"),
        kimi: successCollector("kimi", "kimi_code_usages_api"),
        litellm: successCollector("litellm", "litellm_budget_api"),
      },
    });

    const validated = QuotaCollectionReportSchema.parse(report);
    expect(validated.results.map((result) => result.provider)).toEqual([
      "codex",
      "claude",
      "grok",
      "openrouter",
      "deepseek",
      "kimi",
      "litellm",
    ]);
    expect(validated.results[0]?.outcome).toBe("success");
    expect(validated.results[1]?.outcome).toBe("auth_required");
    expect(validated.results[2]?.outcome).toBe("success");
    expect(validated.results[3]?.outcome).toBe("success");
    expect(validated.results[4]?.outcome).toBe("success");
    expect(validated.results[5]?.outcome).toBe("success");
    expect(validated.results[6]?.outcome).toBe("success");
    expect(collectionExitCode(validated)).toBe(1);
    expect(JSON.stringify(validated)).not.toMatch(/Bearer |eyJ|access_token|refresh_token/i);
  });

  it("returns exit code 0 when every requested provider succeeds", async () => {
    const report = await collectQuotaReport({
      providers: ["codex"],
      now: NOW,
      collectors: {
        codex: successCollector("codex", "chatgpt_usage_api"),
      },
    });
    expect(collectionExitCode(report)).toBe(0);
  });

  it("returns exit code 1 when a successful result has no fresh snapshot", () => {
    const staleSnapshot = {
      ...snapshotFixture("codex", "chatgpt_usage_api"),
      status: "stale" as const,
    };
    const report = QuotaCollectionReportSchema.parse({
      schema_version: 1,
      captured_at: NOW.toISOString().replace(/\.\d{3}Z$/, "Z"),
      results: [{ provider: "codex", outcome: "success", snapshots: [staleSnapshot] }],
    });

    expect(collectionExitCode(report)).toBe(1);
  });

  it("isolates collector exceptions per provider", async () => {
    const report = await collectQuotaReport({
      providers: ["codex", "claude"],
      now: NOW,
      collectors: {
        codex: {
          provider: "codex",
          discover: async () => {
            throw new Error("boom with Bearer super-secret-token");
          },
          collect: async () => {
            throw new Error("unreachable");
          },
        },
        claude: successCollector("claude", "anthropic_oauth_usage_api"),
      },
    });
    expect(report.results[0]?.outcome).toBe("error");
    expect(report.results[0]?.message).not.toContain("super-secret-token");
    expect(report.results[1]?.outcome).toBe("success");
  });

  it("freezes context.now and captured_at only when options.now is set", async () => {
    const unfrozen: Array<Date | undefined> = [];
    const unfrozenReport = await collectQuotaReport({
      providers: ["codex", "claude"],
      collectors: {
        codex: contextProbeCollector("codex", "chatgpt_usage_api", unfrozen),
        claude: contextProbeCollector("claude", "anthropic_oauth_usage_api", unfrozen),
      },
    });
    expect(unfrozen).toEqual([undefined, undefined]);
    expect(unfrozenReport.captured_at).not.toBe(NOW.toISOString().replace(/\.\d{3}Z$/, "Z"));

    const frozen: Array<Date | undefined> = [];
    const frozenReport = await collectQuotaReport({
      providers: ["codex"],
      now: NOW,
      collectors: {
        codex: contextProbeCollector("codex", "chatgpt_usage_api", frozen),
      },
    });
    expect(frozen).toEqual([NOW]);
    expect(frozenReport.captured_at).toBe(NOW.toISOString().replace(/\.\d{3}Z$/, "Z"));
  });
});

function successCollector(
  provider: "codex" | "claude" | "grok" | "openrouter" | "deepseek" | "kimi" | "litellm",
  source: string,
): ProviderCollector {
  const snapshot = snapshotFixture(provider, source);
  return {
    provider,
    discover: async () => [
      {
        provider,
        session_id: "ambient",
        display_label: provider,
        credential_source: "fixture",
      },
    ],
    collect: async () => snapshot,
  };
}

function snapshotFixture(
  provider: "codex" | "claude" | "grok" | "openrouter" | "deepseek" | "kimi" | "litellm",
  source: string,
): QuotaSnapshot {
  return {
    provider,
    account: { fingerprint: `${provider}-fp`, fingerprint_scope: "source" },
    windows: [{ id: "five_hour", title: "5 hour", used_percent: 10 }],
    source,
    status: "available",
    observed_at: NOW.toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
}

function failingCollector(
  provider: "codex" | "claude" | "grok" | "openrouter" | "deepseek" | "kimi" | "litellm",
  category: "auth_required" | "unavailable" | "unsupported" | "error",
  message: string,
): ProviderCollector {
  return {
    provider,
    discover: async () => [
      {
        provider,
        session_id: "ambient",
        display_label: provider,
        credential_source: "fixture",
      },
    ],
    collect: async () => {
      throw new ProviderCollectionError(category, message);
    },
  };
}

function contextProbeCollector(
  provider: "codex" | "claude" | "grok" | "openrouter" | "deepseek" | "kimi" | "litellm",
  source: string,
  sink: Array<Date | undefined>,
): ProviderCollector {
  return {
    provider,
    discover: async () => [
      {
        provider,
        session_id: "ambient",
        display_label: provider,
        credential_source: "fixture",
      },
    ],
    collect: async (_session, context = {}) => {
      sink.push(context.now);
      return snapshotFixture(provider, source);
    },
  };
}
