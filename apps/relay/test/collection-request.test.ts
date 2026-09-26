import type { SessionScope } from "@gotry-io/relay-core";
import { beforeEach, describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import type { WebSessionPort } from "../src/account/web-session.ts";
import { createRelayApp } from "../src/app.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import {
  DEVICE_SESSION_SCOPES,
  encodeScopes,
  READER_SESSION_SCOPES,
} from "../src/state/records.ts";
import { testDatabase } from "./support/database.ts";
import { SignedInWebSessionStub, signedOutWebSessions } from "./web-session-stub.ts";

const origin = "https://quota.gotry.io";
const route = `${origin}/api/v6/account/collection-request`;
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const start = new Date("2026-09-26T10:00:00.000Z");
const accountId = "account_demand";

let db: RelayDatabase;
let clock: Date;

beforeEach(async () => {
  db = await testDatabase();
  clock = start;
  await db
    .prepare(
      `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES (?1, 'Quota Tester', ?2, ?2)`,
    )
    .bind(accountId, start.toISOString())
    .run();
});

/**
 * A collection request is a timestamp on the Account
 * ([ADR 0063](../../../docs/decisions/0063-collection-follows-demand-and-activity.md)).
 */
describe("POST /api/v6/account/collection-request", () => {
  it("states the request on the summary, under a new ETag", async () => {
    const app = appFor(new SignedInWebSessionStub(accountId, start));
    const summaryPath = `${origin}/api/v6/account/summary`;
    const before = await app.request(summaryPath);
    expect(
      ((await before.json()) as { collection_requested_at: unknown }).collection_requested_at,
    ).toBeNull();
    const etag = before.headers.get("ETag") ?? "";

    expect(await (await ask(app, fromBrowser())).json()).toEqual({
      protocol_version: 6,
      requested_at: "2026-09-26T10:00:00Z",
      accepted: true,
    });

    const after = await app.request(summaryPath, { headers: { "If-None-Match": etag } });
    expect(after.status).toBe(200);
    expect(after.headers.get("ETag")).not.toBe(etag);
    expect(await after.json()).toMatchObject({ collection_requested_at: "2026-09-26T10:00:00Z" });
  });

  it("folds a request within a minute of the stored one into it", async () => {
    const app = appFor(new SignedInWebSessionStub(accountId, start));
    await ask(app, fromBrowser());

    clock = new Date(start.getTime() + 59_000);
    expect(await (await ask(app, fromBrowser())).json()).toEqual({
      protocol_version: 6,
      requested_at: "2026-09-26T10:00:00Z",
      accepted: false,
    });

    clock = new Date(start.getTime() + 60_000);
    expect(await (await ask(app, fromBrowser())).json()).toEqual({
      protocol_version: 6,
      requested_at: "2026-09-26T10:01:00Z",
      accepted: true,
    });
  });

  it("takes the Mac's session, the phone's read-only one, and a same-origin browser", async () => {
    const mac = await seedSession("mac", "quotabar", DEVICE_SESSION_SCOPES);
    const phone = await seedSession("phone", "ios", READER_SESSION_SCOPES);
    const app = appFor(new SignedInWebSessionStub(accountId, start));

    expect((await ask(app, bearer(mac))).status).toBe(200);
    expect((await ask(app, bearer(phone))).status).toBe(200);
    expect((await ask(app, fromBrowser())).status).toBe(200);
    // A cookie write is the one that has to prove where it came from.
    expect((await ask(app, { "Content-Type": "application/json" })).status).toBe(403);
  });

  it("refuses a caller with no session", async () => {
    const response = await ask(appFor(signedOutWebSessions), fromBrowser());
    expect(response.status).toBe(401);
    const stored = await db
      .prepare("SELECT collection_requested_at FROM accounts WHERE id = ?1")
      .bind(accountId)
      .first("collection_requested_at");
    expect(stored).toBeNull();
  });

  it("limits each session to 30 requests in ten minutes", async () => {
    const phone = await seedSession("phone", "ios", READER_SESSION_SCOPES);
    const mac = await seedSession("mac", "quotabar", DEVICE_SESSION_SCOPES);
    const app = appFor(signedOutWebSessions);
    for (let index = 0; index < 30; index += 1) {
      expect((await ask(app, bearer(phone))).status, `request ${index + 1}`).toBe(200);
    }
    const limited = await ask(app, bearer(phone));
    expect(limited.status).toBe(429);
    expect(await limited.json()).toMatchObject({ error: { code: "rate_limited" } });
    // Another session on the same Account keeps its own budget.
    expect((await ask(app, bearer(mac))).status).toBe(200);
  });
});

function appFor(webSessions: WebSessionPort) {
  const state = new D1AccountState(db);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(db),
    accountService: new AccountService(state, hasher, secret),
    webSessions,
    hasher,
    now: () => clock,
  });
}

function ask(app: ReturnType<typeof createRelayApp>, headers: Record<string, string>) {
  return app.request(route, {
    method: "POST",
    headers,
    body: JSON.stringify({ protocol_version: 6 }),
  });
}

function fromBrowser(): Record<string, string> {
  return { Origin: origin, "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json" };
}

function bearer(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
}

async function seedSession(
  name: string,
  kind: "quotabar" | "ios",
  scopes: readonly SessionScope[],
): Promise<string> {
  const hasher = new SecretHasher(secret);
  const token = `${kind === "quotabar" ? "qb_" : "qia_"}${name.padEnd(43, "x")}`;
  const deviceId = kind === "quotabar" ? `device_${name}` : null;
  if (deviceId) {
    await db
      .prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
      )
      .bind(deviceId, accountId, `installation_${name}`, start.toISOString())
      .run();
  }
  await db
    .prepare(
      `INSERT INTO sessions (
         id, family_id, account_id, device_id, device_generation, client_kind,
         access_token_hash, refresh_token_hash, scopes_json,
         authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
       ) VALUES (?1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?9, ?9)`,
    )
    .bind(
      `session_${name}`,
      accountId,
      deviceId,
      deviceId ? 1 : null,
      kind,
      await hasher.hash(kind === "quotabar" ? "quotabar-access" : "ios-access", token),
      await hasher.hash(kind === "quotabar" ? "quotabar-refresh" : "ios-refresh", `r_${name}`),
      encodeScopes(scopes),
      start.toISOString(),
      new Date(start.getTime() + 60 * 60_000).toISOString(),
    )
    .run();
  return token;
}
