import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ProviderCollectionError } from "../src/contracts.ts";
import { CodexCollector } from "../src/providers/codex/collector.ts";
import { parseCodexCredentials } from "../src/providers/codex/credentials.ts";
import {
  buildCodexSnapshot,
  CODEX_SOURCE_API,
  CODEX_SOURCE_RPC,
  CODEX_USAGE_URL,
  mapCodexUsageResponse,
} from "../src/providers/codex/map.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

const NOW = new Date("2026-08-02T12:00:00.000Z");

describe("codex credentials", () => {
  it("parses snake_case token fields", () => {
    const credentials = parseCodexCredentials(
      {
        tokens: {
          access_token: "access-snake",
          refresh_token: "refresh-snake",
          id_token: makeJwt({ email: "user@example.com", chatgpt_account_id: "acct_1" }),
          account_id: "acct_1",
        },
        last_refresh: "2026-08-01T00:00:00Z",
      },
      "/tmp/codex/auth.json",
    );
    expect(credentials?.accessToken).toBe("access-snake");
    expect(credentials?.accountId).toBe("acct_1");
    expect(credentials?.hasRefreshToken).toBe(true);
  });

  it("parses camelCase token fields", () => {
    const credentials = parseCodexCredentials(
      {
        tokens: {
          accessToken: "access-camel",
          refreshToken: "refresh-camel",
          accountId: "acct_2",
        },
      },
      "/tmp/codex/auth.json",
    );
    expect(credentials?.accessToken).toBe("access-camel");
    expect(credentials?.accountId).toBe("acct_2");
  });

  it("rejects missing tokens", () => {
    expect(parseCodexCredentials({ tokens: {} }, "/tmp/x")).toBeUndefined();
    expect(parseCodexCredentials({}, "/tmp/x")).toBeUndefined();
  });
});

describe("codex usage mapping", () => {
  it("maps primary secondary and additional windows", () => {
    const mapped = mapCodexUsageResponse({
      plan_type: "plus",
      rate_limit: {
        primary_window: {
          used_percent: 20,
          reset_at: 1_754_140_800,
          limit_window_seconds: 18_000,
        },
        secondary_window: {
          used_percent: 40,
          reset_at: 1_754_572_800,
          limit_window_seconds: 604_800,
        },
      },
      additional_rate_limits: [
        {
          limit_name: "GPT-5.3-Codex-Spark",
          metered_feature: "spark",
          rate_limit: {
            primary_window: {
              used_percent: 10,
              reset_at: 1_754_140_800,
              limit_window_seconds: 18_000,
            },
            secondary_window: {
              used_percent: 15,
              reset_at: 1_754_572_800,
              limit_window_seconds: 604_800,
            },
          },
        },
        {
          limit_name: "Custom Model",
          metered_feature: "custom_model",
          rate_limit: {
            primary_window: {
              used_percent: 5,
              reset_at: 1_754_140_800,
              limit_window_seconds: 18_000,
            },
          },
        },
      ],
    });

    expect(mapped.usable).toBe(true);
    expect(mapped.plan).toBe("plus");
    expect(mapped.windows.map((window) => window.id)).toEqual([
      "five_hour",
      "weekly",
      "codex-spark",
      "codex-spark-weekly",
      "codex-custom-model",
    ]);
    expect(mapped.windows[0]?.used_percent).toBe(20);
    expect(mapped.windows[0]?.duration_seconds).toBe(18_000);
    expect(mapped.windows[0]?.resets_at).toMatch(/Z$/);
  });

  it("keeps usable siblings when one window object is malformed", () => {
    const mapped = mapCodexUsageResponse({
      rate_limit: {
        primary_window: { unexpected: true },
        secondary_window: {
          used_percent: 10,
          reset_at: 1_754_572_800,
          limit_window_seconds: 604_800,
        },
      },
    });
    expect(mapped.malformedSuccess).toBe(false);
    expect(mapped.usable).toBe(true);
    expect(mapped.windows.map((window) => window.id)).toEqual(["weekly"]);
  });

  it("treats explicit null windows as absent, not malformed", () => {
    const mapped = mapCodexUsageResponse({
      rate_limit: {
        primary_window: {
          used_percent: 9,
          reset_at: 1_754_572_800,
          limit_window_seconds: 604_800,
        },
        secondary_window: null,
      },
    });
    expect(mapped.malformedSuccess).toBe(false);
    expect(mapped.usable).toBe(true);
    expect(mapped.windows.map((window) => window.id)).toEqual(["weekly"]);
  });

  it("flags fully unusable present windows as malformed success", () => {
    const mapped = mapCodexUsageResponse({
      rate_limit: {
        primary_window: { unexpected: true },
        secondary_window: { also: "broken" },
      },
    });
    expect(mapped.usable).toBe(false);
    expect(mapped.malformedSuccess).toBe(true);
  });

  it("uses only account ID for global identity and keeps missing identity source-scoped", () => {
    const window = {
      id: "weekly",
      title: "Weekly",
      used_percent: 10,
    };
    const global = buildCodexSnapshot({
      source: CODEX_SOURCE_API,
      windows: [window],
      accountId: "acct_owner",
      email: "owner@example.com",
      plan: "pro",
      now: NOW,
    });
    const repeatedGlobal = buildCodexSnapshot({
      source: CODEX_SOURCE_RPC,
      windows: [window],
      accountId: "acct_owner",
      email: "changed@example.com",
      plan: "team",
      now: NOW,
    });
    const firstSource = buildCodexSnapshot({
      source: CODEX_SOURCE_API,
      windows: [window],
      email: "first@example.com",
      plan: "pro",
      now: NOW,
    });
    const secondSource = buildCodexSnapshot({
      source: CODEX_SOURCE_RPC,
      windows: [window],
      email: "second@example.com",
      plan: "team",
      now: NOW,
    });

    expect(global.account.fingerprint_scope).toBe("global");
    expect(global.account.fingerprint).toBe(repeatedGlobal.account.fingerprint);
    expect(firstSource.account.fingerprint_scope).toBe("source");
    expect(firstSource.account.fingerprint).toBe(secondSource.account.fingerprint);
    expect(JSON.stringify(global)).not.toContain("acct_owner");
    expect(JSON.stringify(global)).not.toContain("owner@example.com");
  });
});

describe("codex collector", () => {
  it("collects via the fixed usage API host", async () => {
    const seen: HttpRequest[] = [];
    const collector = new CodexCollector({
      homeDirectory: "/home/quota",
      environment: {},
      readJson: async (path) => {
        if (path.endsWith("auth.json")) {
          return {
            tokens: {
              access_token: "test-access-token",
              account_id: "acct_fixture",
            },
          };
        }
        return undefined;
      },
      transport: async (request) => {
        seen.push(request);
        return jsonResponse({
          plan_type: "pro",
          rate_limit: {
            primary_window: {
              used_percent: 12,
              reset_at: 1_754_140_800,
              limit_window_seconds: 18_000,
            },
            secondary_window: {
              used_percent: 33,
              reset_at: 1_754_572_800,
              limit_window_seconds: 604_800,
            },
          },
        });
      },
    });

    const sessions = await collector.discover();
    expect(Object.keys(sessions[0] ?? {}).sort()).toEqual(
      ["credential_source", "display_label", "provider", "session_id"].sort(),
    );
    const snapshot = await collector.collect(sessions[0]!, { now: NOW });
    expect(seen[0]?.url).toBe(CODEX_USAGE_URL);
    expect(seen[0]?.headers?.Authorization).toBe("Bearer test-access-token");
    expect(seen[0]?.headers?.["ChatGPT-Account-Id"]).toBe("acct_fixture");
    expect(snapshot.source).toBe(CODEX_SOURCE_API);
    expect(snapshot.account.fingerprint_scope).toBe("global");
    expect(snapshot.account.plan).toBe("pro");
    expect(snapshot.windows).toHaveLength(2);
    expect(JSON.stringify(snapshot)).not.toContain("test-access-token");
    expect(JSON.stringify(snapshot)).not.toContain("acct_fixture");
  });

  it("falls back to app-server RPC when the API is unavailable", async () => {
    const collector = new CodexCollector({
      homeDirectory: "/home/quota",
      environment: {},
      readJson: async () => ({
        tokens: { access_token: "test-access-token", account_id: "acct_fixture" },
      }),
      transport: async () => {
        throw new ProviderCollectionError("unavailable", "network down");
      },
      resolveCodexExecutable: async () => undefined,
    });

    await expect(
      collector.collect(
        {
          provider: "codex",
          session_id: "ambient",
          display_label: "Codex",
          credential_source: "/tmp/auth.json",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({
      category: "unavailable",
      source: CODEX_SOURCE_RPC,
    });
  });

  it("does not fall back on malformed API success payloads", async () => {
    const collector = new CodexCollector({
      homeDirectory: "/home/quota",
      environment: {},
      readJson: async () => ({
        tokens: { access_token: "test-access-token" },
      }),
      transport: async () =>
        jsonResponse({
          rate_limit: {
            primary_window: { broken: true },
          },
        }),
      resolveCodexExecutable: async () => {
        throw new Error("RPC should not run");
      },
    });

    await expect(
      collector.collect(
        {
          provider: "codex",
          session_id: "ambient",
          display_label: "Codex",
          credential_source: "/tmp/auth.json",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({
      category: "error",
      source: CODEX_SOURCE_API,
    });
  });

  it("reports auth_required on 401", async () => {
    const collector = new CodexCollector({
      homeDirectory: "/home/quota",
      readJson: async () => ({
        tokens: { access_token: "test-access-token" },
      }),
      transport: async () => jsonResponse({ error: "nope" }, 401),
      resolveCodexExecutable: async () => undefined,
    });

    await expect(
      collector.collect(
        {
          provider: "codex",
          session_id: "ambient",
          display_label: "Codex",
          credential_source: "/tmp/auth.json",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "auth_required", source: CODEX_SOURCE_API });
  });

  it.skipIf(process.platform === "win32")(
    "lets the official app-server recover an unauthorized direct token",
    async () => {
      await withTemporaryExecutable(
        `#!/bin/sh
printf '%s\n' "$*" > "$CODEX_TEST_ARGS"
while IFS= read -r request; do
  case "$request" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":17,"resetsAt":1754140800,"windowDurationMins":300},"secondary":{"usedPercent":31,"resetsAt":1754572800,"windowDurationMins":10080}}}}'
      ;;
    *'"method":"account/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"account":{"email":"rpc@example.com","planType":"plus"}}}'
      ;;
  esac
done
`,
        async (executable, directory) => {
          const argsPath = join(directory, "args.txt");
          const collector = new CodexCollector({
            homeDirectory: directory,
            environment: {
              CODEX_CLI_PATH: executable,
              CODEX_TEST_ARGS: argsPath,
              PATH: "/usr/bin:/bin",
            },
            readJson: async () => ({
              tokens: { access_token: "expired-access", account_id: "acct_fixture" },
            }),
            transport: async () => jsonResponse({ error: "expired" }, 401),
          });

          const snapshot = await collector.collect(
            {
              provider: "codex",
              session_id: "ambient",
              display_label: "Codex",
              credential_source: "/tmp/auth.json",
            },
            { now: NOW },
          );

          expect(snapshot.source).toBe(CODEX_SOURCE_RPC);
          expect(snapshot.windows.map((window) => window.used_percent)).toEqual([17, 31]);
          expect(await readFile(argsPath, "utf8")).toBe("-s read-only -a untrusted app-server\n");
          expect(JSON.stringify(snapshot)).not.toContain("expired-access");
          expect(JSON.stringify(snapshot)).not.toContain("rpc@example.com");
        },
      );
    },
  );
});

function jsonResponse(body: unknown, status = 200): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}

function makeJwt(payload: Record<string, unknown>): string {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${header}.${body}.sig`;
}

// Keep RPC source constant referenced for greppable coverage.
void CODEX_SOURCE_RPC;

async function withTemporaryExecutable(
  contents: string,
  action: (executable: string, directory: string) => Promise<void>,
): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "quota-codex-rpc-"));
  const executable = join(directory, "codex");
  try {
    await writeFile(executable, contents);
    await chmod(executable, 0o755);
    await action(executable, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
