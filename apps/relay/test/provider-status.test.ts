import { describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import {
  parseStatuspageV2,
  PROVIDER_STATUS_CACHE_MILLISECONDS,
  readProviderStatus,
  statuspageV2Endpoints,
} from "../src/provider-status.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { testDatabase } from "./support/database.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";

const now = new Date("2026-09-06T12:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";

function memoryCache(): Cache {
  const store = new Map<string, Response>();
  return {
    async match(request) {
      const url = request instanceof Request ? request.url : String(request);
      return store.get(url)?.clone();
    },
    async put(request, response) {
      const url = request instanceof Request ? request.url : String(request);
      store.set(url, response.clone());
    },
  } as Cache;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("provider status pages", () => {
  it("lists only catalog statuspage_v2 URLs", () => {
    expect(statuspageV2Endpoints()).toEqual([
      { id: "codex", url: "https://status.openai.com/api/v2/status.json" },
      { id: "claude", url: "https://status.claude.com/api/v2/status.json" },
      { id: "kimi", url: "https://status.moonshot.cn/api/v2/status.json" },
      { id: "cursor", url: "https://status.cursor.com/api/v2/status.json" },
    ]);
  });

  it("parses indicator and description only", () => {
    expect(
      parseStatuspageV2({
        page: { id: "abc" },
        status: { indicator: "minor", description: "Partial System Outage" },
      }),
    ).toEqual({ indicator: "minor", description: "Partial System Outage" });
    expect(
      parseStatuspageV2({ status: { indicator: "maintenance", description: "Scheduled" } }),
    ).toBeNull();
  });

  it("polls each feed and answers unknown when a poll fails with nothing cached", async () => {
    const pages = new Map<string, Response>([
      [
        "https://status.openai.com/api/v2/status.json",
        jsonResponse({ status: { indicator: "minor", description: "Partial System Outage" } }),
      ],
      ["https://status.claude.com/api/v2/status.json", jsonResponse({ error: true }, 500)],
    ]);
    const body = await readProviderStatus({
      fetch: (async (input) => {
        const url = String(input);
        return pages.get(url) ?? jsonResponse({ error: true }, 500);
      }) as typeof fetch,
      cache: memoryCache(),
      now,
    });
    expect(body.providers.map((row) => row.id)).toEqual(["codex", "claude", "kimi", "cursor"]);
    expect(body.providers[0]).toMatchObject({
      id: "codex",
      indicator: "minor",
      description: "Partial System Outage",
      checked_at: now.toISOString(),
    });
    expect(body.providers[1]).toMatchObject({
      id: "claude",
      indicator: "unknown",
      description: "",
    });
  });

  it("keeps the last reading when a later poll fails", async () => {
    const cache = memoryCache();
    const ok = jsonResponse({
      status: { indicator: "major", description: "Major Service Outage" },
    });
    await readProviderStatus({
      fetch: (async () => ok.clone()) as typeof fetch,
      cache,
      now,
    });
    const later = new Date(now.getTime() + PROVIDER_STATUS_CACHE_MILLISECONDS + 1);
    const body = await readProviderStatus({
      fetch: (async () => jsonResponse({ error: true }, 500)) as typeof fetch,
      cache,
      now: later,
    });
    expect(body.providers[0]).toMatchObject({
      id: "codex",
      indicator: "major",
      description: "Major Service Outage",
      checked_at: now.toISOString(),
    });
  });

  it("answers GET /api/v2/providers/status with no session", async () => {
    const db = await testDatabase();
    const state = new D1AccountState(db);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(db),
      accountService: new AccountService(state, hasher, secret),
      webSessions: new SignedInWebSessionStub("account_status", now),
      hasher,
      now: () => now,
      providerStatusCache: memoryCache(),
      providerStatusFetch: (async () =>
        jsonResponse({
          status: { indicator: "none", description: "All Systems Operational" },
        })) as typeof fetch,
    });
    const response = await app.request("https://quota.gotry.io/api/v2/providers/status");
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=600");
    const body = (await response.json()) as {
      providers: Array<{ id: string; indicator: string }>;
    };
    expect(body.providers).toHaveLength(4);
    expect(body.providers.every((row) => row.indicator === "none")).toBe(true);
    expect(
      (await app.request("https://quota.gotry.io/api/v2/providers/status?unexpected=1")).status,
    ).toBe(400);
  });
});
