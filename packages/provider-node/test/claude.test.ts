import { describe, expect, it } from "vitest";
import { ClaudeCollector } from "../src/providers/claude/collector.ts";
import {
  CLAUDE_KEYCHAIN_SERVICE,
  hasUserProfileScope,
  parseClaudeCredentials,
} from "../src/providers/claude/credentials.ts";
import { mapClaudeUsageResponse } from "../src/providers/claude/map.ts";
import type { HttpResponse } from "../src/runtime/http.ts";

const NOW = new Date("2026-08-02T12:00:00.000Z");

describe("claude credentials", () => {
  it("parses file-shaped claudeAiOauth credentials", () => {
    const credentials = parseClaudeCredentials(
      {
        claudeAiOauth: {
          accessToken: "claude-access",
          refreshToken: "claude-refresh",
          expiresAt: 1_754_140_800_000,
          scopes: ["user:profile", "user:inference"],
          subscriptionType: "pro",
          rateLimitTier: "default_claude_ai",
        },
      },
      "~/.claude/.credentials.json",
    );
    expect(credentials?.accessToken).toBe("claude-access");
    expect(hasUserProfileScope(credentials!)).toBe(true);
    expect(credentials?.subscriptionType).toBe("pro");
  });

  it("rejects mcp-only payloads and missing access tokens", () => {
    expect(parseClaudeCredentials({ mcpOAuth: { token: "x" } }, "keychain")).toBeUndefined();
    expect(
      parseClaudeCredentials({ claudeAiOauth: { scopes: ["user:profile"] } }, "file"),
    ).toBeUndefined();
  });
});

describe("claude usage mapping", () => {
  it("maps null windows, flat extras, scoped weekly limits, and extra usage", () => {
    const mapped = mapClaudeUsageResponse({
      five_hour: null,
      seven_day: {
        utilization: 41.5,
        resets_at: "2026-08-09T12:00:00Z",
      },
      seven_day_sonnet: {
        utilization: 10,
        resets_at: "2026-08-09T12:00:00Z",
      },
      seven_day_opus: {
        utilization: 20,
        resets_at: "2026-08-09T12:00:00Z",
      },
      seven_day_oauth_apps: {
        utilization: 5,
        resets_at: "2026-08-09T12:00:00Z",
      },
      seven_day_routines: {
        utilization: 3,
        resets_at: "2026-08-03T12:00:00Z",
      },
      extra_usage: {
        is_enabled: true,
        utilization: 12.5,
      },
      limits: [
        {
          kind: "weekly_scoped",
          group: "weekly",
          percent: 55,
          resets_at: "2026-08-09T12:00:00Z",
          is_active: false,
          scope: { model: { id: "claude-sonnet", display_name: "Sonnet" } },
        },
        {
          kind: "weekly_scoped",
          group: "weekly",
          percent: 1,
          scope: { model: { id: "all-models", display_name: "All models" } },
        },
      ],
    });

    expect(mapped.usable).toBe(true);
    const ids = mapped.windows.map((window) => window.id);
    expect(ids).toContain("seven_day");
    expect(ids).toContain("seven_day_sonnet");
    expect(ids).toContain("seven_day_opus");
    expect(ids).toContain("seven_day_oauth_apps");
    expect(ids).toContain("claude-routines");
    expect(ids).toContain("extra_usage");
    expect(ids).toContain("claude-weekly-scoped-claude-sonnet");
    expect(ids).not.toContain("five_hour");
    expect(mapped.windows.find((window) => window.id === "extra_usage")?.used_percent).toBe(12.5);
  });
});

describe("claude collector", () => {
  it("loads credentials from keychain when the file is absent", async () => {
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      platform: "darwin",
      readJson: async () => undefined,
      readKeychain: async (service) => {
        expect(service).toBe(CLAUDE_KEYCHAIN_SERVICE);
        return JSON.stringify({
          claudeAiOauth: {
            accessToken: "claude-access",
            scopes: ["user:profile"],
            subscriptionType: "max",
          },
        });
      },
      transport: async (request) => {
        if (request.url.endsWith("/usage")) {
          return jsonResponse({
            five_hour: { utilization: 8, resets_at: "2026-08-02T17:00:00Z" },
            seven_day: { utilization: 22, resets_at: "2026-08-09T12:00:00Z" },
          });
        }
        return jsonResponse({
          account: { emailAddress: "ada@example.com" },
          organization: { uuid: "org_fixture" },
        });
      },
    });

    const sessions = await collector.discover();
    expect(sessions).toHaveLength(1);
    const snapshot = await collector.collect(sessions[0]!, { now: NOW });
    expect(snapshot.provider).toBe("claude");
    expect(snapshot.account.plan).toBe("max");
    expect(snapshot.account.label).toBe("ad***@example.com");
    expect(snapshot.windows).toHaveLength(2);
    expect(JSON.stringify(snapshot)).not.toContain("claude-access");
    expect(JSON.stringify(snapshot)).not.toContain("ada@example.com");
    expect(JSON.stringify(snapshot)).not.toContain("org_fixture");
  });

  it("keeps usage success when profile enrichment fails", async () => {
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        claudeAiOauth: {
          accessToken: "claude-access",
          scopes: ["user:profile"],
        },
      }),
      transport: async (request) => {
        if (request.url.endsWith("/profile")) {
          return jsonResponse({ error: "nope" }, 500);
        }
        return jsonResponse({
          five_hour: { utilization: 1, resets_at: "2026-08-02T17:00:00Z" },
        });
      },
    });

    const snapshot = await collector.collect(
      {
        provider: "claude",
        session_id: "ambient",
        display_label: "Claude Code",
        credential_source: "file",
      },
      { now: NOW },
    );
    expect(snapshot.windows).toHaveLength(1);
  });

  it("classifies missing user:profile as auth_required", async () => {
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        claudeAiOauth: {
          accessToken: "claude-access",
          scopes: ["user:inference"],
        },
      }),
    });

    await expect(
      collector.collect(
        {
          provider: "claude",
          session_id: "ambient",
          display_label: "Claude Code",
          credential_source: "file",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "auth_required" });
  });

  it("classifies 401 and 429 responses", async () => {
    const unauthorized = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        claudeAiOauth: { accessToken: "claude-access", scopes: ["user:profile"] },
      }),
      transport: async () => jsonResponse({}, 401),
    });
    await expect(
      unauthorized.collect(
        {
          provider: "claude",
          session_id: "ambient",
          display_label: "Claude Code",
          credential_source: "file",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "auth_required" });

    const limited = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        claudeAiOauth: { accessToken: "claude-access", scopes: ["user:profile"] },
      }),
      transport: async () => jsonResponse({}, 429),
    });
    await expect(
      limited.collect(
        {
          provider: "claude",
          session_id: "ambient",
          display_label: "Claude Code",
          credential_source: "file",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "unavailable" });
  });

  it("classifies a non-JSON 401 as auth_required without exposing its body", async () => {
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        claudeAiOauth: { accessToken: "claude-access", scopes: ["user:profile"] },
      }),
      transport: async () => ({
        status: 401,
        headers: new Headers({ "content-type": "text/html" }),
        bodyText: "<html>secret upstream diagnostics</html>",
      }),
    });

    await expect(
      collector.collect(
        {
          provider: "claude",
          session_id: "ambient",
          display_label: "Claude Code",
          credential_source: "file",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({
      category: "auth_required",
      source: "anthropic_oauth_usage_api",
    });
  });
});

function jsonResponse(body: unknown, status = 200): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}
