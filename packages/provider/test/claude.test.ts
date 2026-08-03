import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ClaudeCollector } from "../src/providers/claude/collector.ts";
import { refreshClaudeAuthWithCli } from "../src/providers/claude/auth-refresh.ts";
import {
  CLAUDE_KEYCHAIN_SERVICE,
  hasUserProfileScope,
  loadClaudeCredentials,
  parseClaudeCredentials,
  shouldRefreshClaudeCredentials,
} from "../src/providers/claude/credentials.ts";
import { buildClaudeSnapshot, mapClaudeUsageResponse } from "../src/providers/claude/map.ts";
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
    expect(shouldRefreshClaudeCredentials(credentials!, NOW)).toBe(true);
  });

  it("rejects mcp-only payloads and missing access tokens", () => {
    expect(parseClaudeCredentials({ mcpOAuth: { token: "x" } }, "keychain")).toBeUndefined();
    expect(
      parseClaudeCredentials({ claudeAiOauth: { scopes: ["user:profile"] } }, "file"),
    ).toBeUndefined();
  });

  it("uses refreshed Keychain credentials when file credentials are expired", async () => {
    const credentials = await loadClaudeCredentials({
      homeDirectory: "/home/quota",
      platform: "darwin",
      readJson: async () => claudeCredentials("expired-file-token", "2000-01-01T00:00:00Z"),
      readKeychain: async () =>
        JSON.stringify(claudeCredentials("fresh-keychain-token", "2099-01-01T00:00:00Z")),
    });

    expect(credentials?.accessToken).toBe("fresh-keychain-token");
    expect(credentials?.source).toBe(`macOS Keychain: ${CLAUDE_KEYCHAIN_SERVICE}`);
  });
});

describe("claude CLI auth refresh", () => {
  it.skipIf(process.platform !== "darwin")(
    "touches only the interactive status path in a PTY",
    async () => {
      await withTemporaryExecutable(
        `#!/bin/sh
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$CLAUDE_TEST_MARKER"
  case "$line" in
    *'/status'*) exit 0 ;;
  esac
done
`,
        async (executable, directory) => {
          const marker = join(directory, "commands.txt");
          await expect(
            refreshClaudeAuthWithCli({
              homeDirectory: directory,
              environment: {
                CLAUDE_CLI_PATH: executable,
                CLAUDE_CONFIG_DIR: "/dev/null",
                CLAUDE_TEST_MARKER: marker,
                PATH: "/usr/bin:/bin",
              },
              platform: "darwin",
            }),
          ).resolves.toBe(true);

          expect(await readFile(marker, "utf8")).toContain("/status");
        },
      );
    },
  );
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

  it("uses organization ID as the only global identity", () => {
    const windows = [{ id: "five_hour", title: "5 hour", used_percent: 4 }];
    const organization = buildClaudeSnapshot({
      windows,
      organizationId: "org_owner",
      email: "owner@example.com",
      plan: "max",
      now: NOW,
    });
    const repeatedOrganization = buildClaudeSnapshot({
      windows,
      organizationId: "org_owner",
      email: "changed@example.com",
      plan: "pro",
      now: NOW,
    });
    const emailOnly = buildClaudeSnapshot({
      windows,
      email: "owner@example.com",
      plan: "max",
      now: NOW,
    });
    const noProfile = buildClaudeSnapshot({ windows, plan: "pro", now: NOW });

    expect(organization.account.fingerprint_scope).toBe("global");
    expect(organization.account.fingerprint).toBe(repeatedOrganization.account.fingerprint);
    expect(emailOnly.account.fingerprint_scope).toBe("source");
    expect(emailOnly.account.fingerprint).toBe(noProfile.account.fingerprint);
    expect(JSON.stringify(organization)).not.toContain("org_owner");
    expect(JSON.stringify(organization)).not.toContain("owner@example.com");
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
    expect(snapshot.account.fingerprint_scope).toBe("global");
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
    expect(snapshot.account.fingerprint_scope).toBe("source");
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
    let credentialReads = 0;
    const unauthorized = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => {
        credentialReads += 1;
        return {
          claudeAiOauth: { accessToken: "claude-access", scopes: ["user:profile"] },
        };
      },
      transport: async () => jsonResponse({}, 401),
      refreshAuth: async () => true,
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
    expect(credentialReads).toBe(2);

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
      refreshAuth: async () => false,
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

  it("refreshes expiring credentials before requesting usage", async () => {
    let credentials = claudeCredentials("expiring-token", "2026-08-02T12:00:30Z");
    let refreshCount = 0;
    const authorizations: string[] = [];
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => credentials,
      refreshAuth: async () => {
        refreshCount += 1;
        credentials = claudeCredentials("refreshed-token", "2026-08-02T18:00:00Z");
        return true;
      },
      transport: async (request) => {
        authorizations.push(request.headers?.Authorization ?? "");
        return request.url.endsWith("/usage")
          ? jsonResponse({
              five_hour: { utilization: 7, resets_at: "2026-08-02T17:00:00Z" },
            })
          : jsonResponse({});
      },
    });

    await expect(collector.collect(claudeSession(), { now: NOW })).resolves.toMatchObject({
      provider: "claude",
      status: "available",
    });
    expect(refreshCount).toBe(1);
    expect(authorizations).toEqual(["Bearer refreshed-token", "Bearer refreshed-token"]);
  });

  it("refreshes and retries once after an unauthorized usage response", async () => {
    let credentials = claudeCredentials("rejected-token", "2026-08-02T18:00:00Z");
    let refreshCount = 0;
    let usageCount = 0;
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => credentials,
      refreshAuth: async () => {
        refreshCount += 1;
        credentials = claudeCredentials("retry-token", "2026-08-03T00:00:00Z");
        return true;
      },
      transport: async (request) => {
        if (request.url.endsWith("/profile")) {
          return jsonResponse({});
        }
        usageCount += 1;
        return usageCount === 1
          ? jsonResponse({}, 401)
          : jsonResponse({
              five_hour: { utilization: 9, resets_at: "2026-08-02T17:00:00Z" },
            });
      },
    });

    await expect(collector.collect(claudeSession(), { now: NOW })).resolves.toMatchObject({
      provider: "claude",
      status: "available",
    });
    expect(refreshCount).toBe(1);
    expect(usageCount).toBe(2);
  });

  it("does not loop when Claude rejects the refreshed token", async () => {
    let credentials = claudeCredentials("rejected-token", "2026-08-02T18:00:00Z");
    let refreshCount = 0;
    let usageCount = 0;
    const collector = new ClaudeCollector({
      homeDirectory: "/home/quota",
      readJson: async () => credentials,
      refreshAuth: async () => {
        refreshCount += 1;
        credentials = claudeCredentials("still-rejected", "2026-08-03T00:00:00Z");
        return true;
      },
      transport: async () => {
        usageCount += 1;
        return jsonResponse({}, 401);
      },
    });

    await expect(collector.collect(claudeSession(), { now: NOW })).rejects.toMatchObject({
      category: "auth_required",
      source: "anthropic_oauth_usage_api",
    });
    expect(refreshCount).toBe(1);
    expect(usageCount).toBe(2);
  });
});

function jsonResponse(body: unknown, status = 200): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}

function claudeCredentials(accessToken: string, expiresAt: string): unknown {
  return {
    claudeAiOauth: {
      accessToken,
      refreshToken: "synthetic-refresh-token",
      expiresAt: new Date(expiresAt).getTime(),
      scopes: ["user:profile", "user:inference"],
    },
  };
}

function claudeSession() {
  return {
    provider: "claude" as const,
    session_id: "ambient",
    display_label: "Claude Code",
    credential_source: "file",
  };
}

async function withTemporaryExecutable(
  contents: string,
  action: (executable: string, directory: string) => Promise<void>,
): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "quota-claude-refresh-"));
  const executable = join(directory, "claude");
  try {
    await writeFile(executable, contents);
    await chmod(executable, 0o755);
    await action(executable, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
