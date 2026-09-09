import { type LeaderboardResponse, MODEL_CATALOG } from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createWebDocumentPort } from "../src/account/web-document-port.ts";
import { createRelayApp } from "../src/app.ts";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub, signedOutWebSessions } from "./web-session-stub.ts";
import type { RelayDatabase, RelayStatement } from "../src/platform/database.ts";
import { testDatabase } from "./support/database.ts";

let db: RelayDatabase;

const now = new Date("2026-09-06T12:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const webRequest = {
  headers: { Origin: origin, "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json" },
};

beforeEach(async () => {
  db = await testDatabase();
  // The board is one answer over every listed profile at once, so each case needs the store to
  // hold only what it published. Deleting the Accounts takes their devices, rollup rows, and
  // profiles with them.
  await db.batch([db.prepare("DELETE FROM usage_daily"), db.prepare("DELETE FROM accounts")]);
});

describe("the board a listed page appears on", () => {
  it("ranks only the pages that asked for it, and carries nothing a page does not", async () => {
    // Two days inside the window against one, so the order is the fold rather than the seeding.
    await publish("first", "first-handle", { onLeaderboard: true }, [
      "2026-09-06",
      "2026-09-05",
      "2026-03-01",
    ]);
    await publish("second", "second-handle", { onLeaderboard: true }, ["2026-09-06"]);
    // Published, but not listed: the switch is what puts a page on the board.
    await publish("shy", "shy-handle", {}, ["2026-09-06", "2026-09-05"]);
    // Listed, then taken down: `enabled` still gates the read.
    await publish("down", "down-handle", { onLeaderboard: true }, ["2026-09-06", "2026-09-05"]);
    expect((await put(appFor("account_down"), "down-handle", { enabled: false })).status).toBe(200);

    const response = await appFor("account_first").request(`${origin}/api/v6/public/leaderboard`);
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
    const body = (await response.json()) as LeaderboardResponse;

    expect(Object.keys(body).sort()).toEqual([
      "entries",
      "generated_at",
      "period",
      "protocol_version",
    ]);
    expect(body.period).toBe("30d");
    // The March day is outside the window, so it counts for neither the totals nor the order.
    expect(body.entries).toEqual([
      { handle: "first-handle", total_tokens: 24, messages: 2, rank: 1 },
      { handle: "second-handle", total_tokens: 12, messages: 1, rank: 2 },
    ]);

    const serialized = JSON.stringify(body);
    for (const forbidden of ["cost", "model", "provider", "agent", "device", "account"]) {
      expect(serialized, forbidden).not.toContain(forbidden);
    }
  });

  it("answers only the one period it has, and refuses any other question", async () => {
    const app = appFor("account_asking");
    expect((await app.request(`${origin}/api/v6/public/leaderboard?period=30d`)).status).toBe(200);
    for (const query of ["?period=7d", "?period=", "?limit=10", "?period=30d&limit=10"]) {
      const response = await app.request(`${origin}/api/v6/public/leaderboard${query}`);
      expect(response.status, query).toBe(400);
      expect(await response.json()).toEqual({
        error: { code: "invalid_request", message: "The request is invalid." },
      });
    }
  });

  it("answers a held validator with 304 and reads no Usage to do it", async () => {
    await publish("etag", "ranked", { onLeaderboard: true }, ["2026-09-06"]);
    const statements: string[] = [];
    const app = appFor("account_etag", recordingD1(statements));

    const first = await app.request(`${origin}/api/v6/public/leaderboard`);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(((await first.json()) as LeaderboardResponse).entries).toEqual([
      { handle: "ranked", total_tokens: 12, messages: 1, rank: 1 },
    ]);

    statements.length = 0;
    const second = await app.request(`${origin}/api/v6/public/leaderboard`, {
      headers: { "If-None-Match": etag ?? "" },
    });

    expect(second.status).toBe(304);
    expect(second.headers.get("Cache-Control")).toBe("public, max-age=300");
    expect(statements.filter((sql) => sql.includes("usage_daily"))).toEqual([]);

    // A page joining the board is a different board, so the validator it was holding is stale.
    await publish("late", "late-arrival", { onLeaderboard: true }, ["2026-09-06"]);
    const third = await app.request(`${origin}/api/v6/public/leaderboard`, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(third.status).toBe(200);
  });

  it("names the reader's own handle to the document that renders the board", async () => {
    await publish("mine", "mine", { onLeaderboard: true }, ["2026-09-06"]);
    await publish("theirs", "theirs", { onLeaderboard: true }, ["2026-09-06", "2026-09-05"]);

    const signedIn = await portFor(new SignedInWebSessionStub("account_mine", now)).readLeaderboard(
      new Headers(),
    );
    expect(signedIn.board.entries.map((entry) => entry.handle)).toEqual(["theirs", "mine"]);
    expect(signedIn.viewerHandle).toBe("mine");

    const anonymous = await portFor(signedOutWebSessions).readLeaderboard(new Headers());
    expect(anonymous.board.entries).toEqual(signedIn.board.entries);
    expect(anonymous.viewerHandle).toBeNull();
  });
});

function portFor(webSessions: Parameters<typeof createWebDocumentPort>[0]["webSessions"]) {
  return createWebDocumentPort({
    webSessions,
    state: new D1AccountState(db),
    usageState: new D1UsageState(db),
    catalog: PRICING_CATALOG,
    modelCatalog: MODEL_CATALOG,
    now: () => now,
  });
}

interface ProfileOptions {
  enabled?: boolean;
  onLeaderboard?: boolean;
}

/** One Account with a device, a published handle, and one rollup row per named UTC day. */
async function publish(
  name: string,
  handle: string,
  options: ProfileOptions,
  dates: readonly string[],
): Promise<void> {
  await db.batch([
    db
      .prepare(
        `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES ('account_${name}', 'Quota Tester', ?1, ?1)`,
      )
      .bind(now.toISOString()),
    db
      .prepare(
        `INSERT INTO devices (
         id, account_id, installation_id_hash, generation, created_at, last_login_at
       ) VALUES ('device_${name}', 'account_${name}', 'installation_${name}', 1, ?1, ?1)`,
      )
      .bind(now.toISOString()),
  ]);
  await db.batch(dates.map((date) => dailyRow(name, date)));
  expect((await put(appFor(`account_${name}`), handle, options)).status).toBe(200);
}

function put(app: ReturnType<typeof createRelayApp>, handle: string, options: ProfileOptions = {}) {
  return app.request(`${origin}/api/v2/account/profile`, {
    method: "PUT",
    ...webRequest,
    body: JSON.stringify({
      protocol_version: 2,
      profile: {
        handle,
        enabled: options.enabled ?? true,
        show_models: true,
        show_cost: false,
        on_leaderboard: options.onLeaderboard ?? false,
      },
    }),
  });
}

function dailyRow(name: string, date: string): RelayStatement {
  return db
    .prepare(
      `INSERT INTO usage_daily (
       device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
       service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
       cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
       output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
       source_cost_microusd, source_cost_covered_requests, partial_hours
     ) VALUES (
       'device_${name}', ?1, 'codex', 'anthropic_direct', 'agent_default', 'claude-opus-5',
       'le_128k', 'unknown', 'unknown', 'unknown', 10, 0,
       0, 0, 0, 2, 0, 1, 0, 0, NULL, 0, 0
     )`,
    )
    .bind(date);
}

function appFor(accountId: string, database: RelayDatabase = db) {
  const state = new D1AccountState(database);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(database),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, now),
    hasher,
    now: () => now,
  });
}

function recordingD1(statements: string[]): RelayDatabase {
  return new Proxy(db, {
    get(target, property, receiver) {
      if (property === "prepare") {
        return (sql: string) => {
          statements.push(sql);
          return target.prepare(sql);
        };
      }
      const value = Reflect.get(target, property, receiver);
      return typeof value === "function"
        ? (value as (...args: never[]) => unknown).bind(target)
        : value;
    },
  });
}
