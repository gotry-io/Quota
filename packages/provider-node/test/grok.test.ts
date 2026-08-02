import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  GROK_BILLING_URL,
  GROK_LEGACY_SESSION_SCOPE,
  GROK_OIDC_SCOPE_PREFIX,
  GROK_SOURCE_API,
  parseGrokCredentials,
} from "../src/index.ts";
import { GrokCollector } from "../src/providers/grok/collector.ts";
import { refreshGrokAuthWithCli } from "../src/providers/grok/auth-refresh.ts";
import { mapGrokBillingResponse } from "../src/providers/grok/map.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

const NOW = new Date("2026-08-02T12:00:00.000Z");

describe("grok credentials", () => {
  it("prefers OIDC scope entries with a non-empty key", () => {
    const credentials = parseGrokCredentials(
      {
        [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
          key: "oidc-key",
          user_id: "user_1",
          email: "grok@example.com",
          first_name: "Grok",
          last_name: "User",
        },
        [GROK_LEGACY_SESSION_SCOPE]: {
          key: "legacy-key",
          user_id: "legacy_user",
        },
      },
      "/tmp/grok/auth.json",
    );
    expect(credentials?.userId).toBe("user_1");
    expect(credentials?.accessToken).toBe("oidc-key");
    expect(credentials?.scope.startsWith(GROK_OIDC_SCOPE_PREFIX)).toBe(true);
  });

  it("falls back to legacy sign-in when OIDC key is empty", () => {
    const credentials = parseGrokCredentials(
      {
        [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
          key: "",
          user_id: "broken",
        },
        [GROK_LEGACY_SESSION_SCOPE]: {
          key: "legacy-key",
          user_id: "legacy_user",
        },
      },
      "/tmp/grok/auth.json",
    );
    expect(credentials?.userId).toBe("legacy_user");
  });

  it("selects the OIDC entry with the latest expiry", () => {
    const credentials = parseGrokCredentials(
      {
        [`${GROK_OIDC_SCOPE_PREFIX}fresh-client`]: {
          key: "fresh-key",
          user_id: "fresh-user",
          expires_at: "2026-08-03T00:00:00Z",
        },
        [`${GROK_OIDC_SCOPE_PREFIX}stale-client`]: {
          key: "stale-key",
          user_id: "stale-user",
          expires_at: "2026-08-01T00:00:00Z",
        },
      },
      "/tmp/grok/auth.json",
    );

    expect(credentials?.userId).toBe("fresh-user");
    expect(credentials?.accessToken).toBe("fresh-key");
  });
});

describe("grok CLI auth refresh", () => {
  it.skipIf(process.platform === "win32")(
    "performs a headless cached-token ACP handshake",
    async () => {
      await withTemporaryExecutable(
        `#!/bin/sh
IFS= read -r request
printf '%s\\n' "$request" >> "$GROK_TEST_MARKER"
printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"authMethods":[{"id":"cached_token"},{"id":"grok.com"}],"_meta":{"defaultAuthMethodId":"cached_token"}}}'
IFS= read -r request
printf '%s\\n' "$request" >> "$GROK_TEST_MARKER"
printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"_meta":{}}}'
`,
        async (executable, directory) => {
          const marker = join(directory, "requests.jsonl");
          await expect(
            refreshGrokAuthWithCli({
              homeDirectory: directory,
              environment: {
                GROK_CLI_PATH: executable,
                GROK_TEST_MARKER: marker,
                PATH: "/usr/bin:/bin",
              },
            }),
          ).resolves.toBe(true);

          const requests = (await readFile(marker, "utf8"))
            .trim()
            .split("\n")
            .map((line) => JSON.parse(line) as Record<string, unknown>);
          expect(requests).toHaveLength(2);
          expect(requests[0]).toMatchObject({ method: "initialize" });
          expect(requests[1]).toMatchObject({
            method: "authenticate",
            params: { methodId: "cached_token", _meta: { headless: true } },
          });
        },
      );
    },
  );
});

describe("grok billing mapping", () => {
  it("maps the current credits response and weekly period", () => {
    const mapped = mapGrokBillingResponse({
      config: {
        creditUsagePercent: 8,
        currentPeriod: {
          type: "USAGE_PERIOD_TYPE_WEEKLY",
          start: "2026-07-30T07:33:06Z",
          end: "2026-08-06T07:33:06Z",
        },
      },
    });
    expect(mapped.usable).toBe(true);
    expect(mapped.window).toMatchObject({
      id: "billing_cycle",
      title: "Weekly",
      used_percent: 8,
      duration_seconds: 7 * 24 * 60 * 60,
      resets_at: "2026-08-06T07:33:06Z",
    });
  });

  it("maps the deprecated non-unified account fields documented by Grok Build", () => {
    const mapped = mapGrokBillingResponse({
      config: {
        monthlyLimit: { val: 2000 },
        used: { val: 500 },
        billingPeriodStart: "2026-08-01T00:00:00Z",
        billingPeriodEnd: "2026-09-01T00:00:00Z",
      },
    });
    expect(mapped.usable).toBe(true);
    expect(mapped.window?.id).toBe("billing_cycle");
    expect(mapped.window?.used_percent).toBe(25);
    expect(mapped.window?.duration_seconds).toBe(31 * 24 * 60 * 60);
    expect(mapped.window?.resets_at).toBe("2026-09-01T00:00:00Z");
  });
});

describe("grok collector", () => {
  it("collects through the fixed official billing API and redacts credentials", async () => {
    let request: HttpRequest | undefined;
    const collector = new GrokCollector({
      clientVersion: "9.8.7",
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      transport: async (input) => {
        request = input;
        return jsonResponse(200, {
          config: {
            creditUsagePercent: 8,
            currentPeriod: {
              type: "USAGE_PERIOD_TYPE_WEEKLY",
              start: "2026-07-30T07:33:06Z",
              end: "2026-08-06T07:33:06Z",
            },
          },
        });
      },
    });
    const snapshot = await collector.collect(grokSession(), { now: NOW });

    expect(snapshot.source).toBe(GROK_SOURCE_API);
    expect(snapshot.windows[0]?.used_percent).toBe(8);
    expect(request?.url).toBe(GROK_BILLING_URL);
    expect(request?.headers).toMatchObject({
      Authorization: "Bearer synthetic-token",
      "User-Agent": "QuotaCLI/9.8.7",
      "X-XAI-Token-Auth": "xai-grok-cli",
      "x-userid": "user_1",
    });
    expect(JSON.stringify(snapshot)).not.toContain("synthetic-token");
    expect(JSON.stringify(snapshot)).not.toContain("grok@example.com");
    expect(JSON.stringify(snapshot)).not.toContain("user_1");
  });

  it("classifies an unauthorized API response without exposing its body", async () => {
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      refreshAuth: async () => false,
      transport: async () => jsonResponse(401, { error: "Bearer synthetic-token" }),
    });
    const collection = collector.collect(grokSession(), { now: NOW });
    await expect(collection).rejects.toMatchObject({
      category: "auth_required",
      source: GROK_SOURCE_API,
    });
    await expect(collection).rejects.not.toThrow(/synthetic-token/);
  });

  it("refreshes expired credentials through Grok before requesting billing", async () => {
    let auth = syntheticAuthPayload("expired-token", "2026-08-01T00:00:00Z");
    let refreshCount = 0;
    const requests: HttpRequest[] = [];
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: async () => auth,
      refreshAuth: async () => {
        refreshCount += 1;
        auth = syntheticAuthPayload("refreshed-token", "2026-08-03T00:00:00Z");
        return true;
      },
      transport: async (input) => {
        requests.push(input);
        return jsonResponse(200, billingPayload());
      },
    });

    await expect(collector.collect(grokSession(), { now: NOW })).resolves.toMatchObject({
      provider: "grok",
      status: "available",
    });
    expect(refreshCount).toBe(1);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.headers?.Authorization).toBe("Bearer refreshed-token");
  });

  it("refreshes and retries once after an unauthorized billing response", async () => {
    let auth = syntheticAuthPayload("rejected-token", "2026-08-03T00:00:00Z");
    let refreshCount = 0;
    const requests: HttpRequest[] = [];
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: async () => auth,
      refreshAuth: async () => {
        refreshCount += 1;
        auth = syntheticAuthPayload("retry-token", "2026-08-03T06:00:00Z");
        return true;
      },
      transport: async (input) => {
        requests.push(input);
        return requests.length === 1
          ? jsonResponse(401, { error: "unauthorized" })
          : jsonResponse(200, billingPayload());
      },
    });

    await expect(collector.collect(grokSession(), { now: NOW })).resolves.toMatchObject({
      provider: "grok",
      status: "available",
    });
    expect(refreshCount).toBe(1);
    expect(requests.map((request) => request.headers?.Authorization)).toEqual([
      "Bearer rejected-token",
      "Bearer retry-token",
    ]);
  });

  it("does not loop when refreshed credentials are also rejected", async () => {
    let auth = syntheticAuthPayload("rejected-token", "2026-08-03T00:00:00Z");
    let refreshCount = 0;
    let requestCount = 0;
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: async () => auth,
      refreshAuth: async () => {
        refreshCount += 1;
        auth = syntheticAuthPayload("still-rejected", "2026-08-03T06:00:00Z");
        return true;
      },
      transport: async () => {
        requestCount += 1;
        return jsonResponse(401, { error: "unauthorized" });
      },
    });

    await expect(collector.collect(grokSession(), { now: NOW })).rejects.toMatchObject({
      category: "auth_required",
    });
    expect(refreshCount).toBe(1);
    expect(requestCount).toBe(2);
  });

  it("rejects malformed billing payloads", async () => {
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      transport: async () => jsonResponse(200, { not: "billing" }),
    });
    await expect(
      collector.collect(
        {
          provider: "grok",
          session_id: "ambient",
          display_label: "Grok",
          credential_source: "/tmp/auth.json",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "error", source: GROK_SOURCE_API });
  });
});

function syntheticAuth(): Promise<unknown> {
  return Promise.resolve(syntheticAuthPayload("synthetic-token"));
}

function syntheticAuthPayload(accessToken: string, expiresAt?: string): unknown {
  return {
    [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
      key: accessToken,
      user_id: "user_1",
      email: "grok@example.com",
      ...(expiresAt ? { expires_at: expiresAt } : {}),
    },
  };
}

function billingPayload(): unknown {
  return {
    config: {
      creditUsagePercent: 8,
      currentPeriod: {
        type: "USAGE_PERIOD_TYPE_WEEKLY",
        start: "2026-07-30T07:33:06Z",
        end: "2026-08-06T07:33:06Z",
      },
    },
  };
}

function grokSession() {
  return {
    provider: "grok" as const,
    session_id: "ambient",
    display_label: "Grok",
    credential_source: "/tmp/auth.json",
  };
}

function jsonResponse(status: number, value: unknown): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(value),
  };
}

async function withTemporaryExecutable(
  contents: string,
  action: (executable: string, directory: string) => Promise<void>,
): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "quota-grok-refresh-"));
  const executable = join(directory, "grok");
  try {
    await writeFile(executable, contents);
    await chmod(executable, 0o755);
    await action(executable, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
