import {
  ACCOUNT_SETTINGS_UNSET_UPDATED_AT,
  type AccountSettings,
  type AccountSettingsResponse,
  DEFAULT_ACCOUNT_SETTINGS,
  MAXIMUM_ACCOUNT_SETTINGS_SELECTORS,
} from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import type { SessionScope } from "@gotry-io/relay-core";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import {
  DEVICE_SESSION_SCOPES,
  encodeScopes,
  READER_SESSION_SCOPES,
} from "../src/state/records.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { testDatabase } from "./support/database.ts";

let db: RelayDatabase;

const now = new Date("2026-09-21T10:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const webRequest = {
  headers: {
    Origin: origin,
    "Sec-Fetch-Site": "same-origin",
    "Content-Type": "application/json",
    "If-Match": '"0"',
  },
};

const writtenSettings = {
  alerts: {
    reset_reminders: true,
    pace_alerts: true,
    thresholds: { a1b2c3d4e5f6: [20, 10] },
  },
  budget: { amount_usd: "250.00", alerts: true },
};

beforeEach(async () => {
  db = await testDatabase();
});

describe("Account settings", () => {
  it("answers the default document at revision 0 when nothing has been written", async () => {
    await seedAccount("empty");
    const response = await appFor("account_empty").request(`${origin}/api/v2/account/settings`);

    expect(response.status).toBe(200);
    expect(response.headers.get("ETag")).toBe('"0"');
    expect(response.headers.get("Cache-Control")).toBe("private, no-cache");
    expect(await response.json()).toEqual({
      protocol_version: 2,
      revision: 0,
      updated_at: ACCOUNT_SETTINGS_UNSET_UPDATED_AT,
      ...DEFAULT_ACCOUNT_SETTINGS,
    });
  });

  it("writes, answers 304, and returns the current document on a stale If-Match", async () => {
    await seedAccount("owner");
    const app = appFor("account_owner");

    const written = await put(app, writtenSettings);
    expect(written.status).toBe(200);
    expect(written.headers.get("ETag")).toBe('"1"');
    const body = (await written.json()) as AccountSettingsResponse;
    expect(body).toEqual({
      protocol_version: 2,
      revision: 1,
      updated_at: now.toISOString(),
      ...writtenSettings,
      history: { sync: false },
    });

    const again = await app.request(`${origin}/api/v2/account/settings`, {
      headers: { "If-None-Match": '"1"' },
    });
    expect(again.status).toBe(304);

    const stale = await put(app, writtenSettings, { ifMatch: '"0"' });
    expect(stale.status).toBe(412);
    expect(stale.headers.get("ETag")).toBe('"1"');
    expect(await stale.json()).toEqual(body);
  });

  it("stores a budget amount in one spelling, whoever wrote it", async () => {
    await seedAccount("owner");
    const app = appFor("account_owner");
    // Swift can only write cents; the website writes what was typed. The stored document must
    // not depend on which of them saved last.
    for (const [sent, stored, ifMatch] of [
      ["0.5", "0.50", '"0"'],
      ["1000000", "1000000.00", '"1"'],
      ["0250.5", "250.50", '"2"'],
    ] as const) {
      const written = await put(
        app,
        { ...writtenSettings, budget: { amount_usd: sent, alerts: true } },
        { ifMatch },
      );
      expect(written.status, sent).toBe(200);
      const body = (await written.json()) as AccountSettingsResponse;
      expect(body.budget.amount_usd, sent).toBe(stored);
    }
  });

  it("refuses a write with no If-Match", async () => {
    await seedAccount("match");
    const response = await appFor("account_match").request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: {
        Origin: origin,
        "Sec-Fetch-Site": "same-origin",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ protocol_version: 2, ...writtenSettings }),
    });
    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({
      error: { code: "precondition_required", message: "If-Match is required." },
    });
  });

  it("takes the write from a browser at this origin, and refuses one without Origin", async () => {
    await seedAccount("origin");
    const app = appFor("account_origin");
    const crossOrigin = await app.request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: { "Content-Type": "application/json", "If-Match": '"0"' },
      body: JSON.stringify({ protocol_version: 2, ...writtenSettings }),
    });
    expect(crossOrigin.status).toBe(403);
    expect(await storedSettings("account_origin")).toBe(0);

    expect((await put(app, writtenSettings)).status).toBe(200);
    expect(await storedSettings("account_origin")).toBe(1);
  });

  it("lets a quotabar session and an ios session write without Origin", async () => {
    await seedAccount("native");
    const hasher = new SecretHasher(secret);
    const quotabar = await seedNativeSession({
      name: "quotabar",
      accountId: "account_native",
      kind: "quotabar",
      scopes: DEVICE_SESSION_SCOPES,
      hasher,
    });
    const ios = await seedNativeSession({
      name: "ios",
      accountId: "account_native",
      kind: "ios",
      scopes: READER_SESSION_SCOPES,
      hasher,
    });
    const app = appFor("account_native");

    const fromMac = await app.request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${quotabar.token}`,
        "Content-Type": "application/json",
        "If-Match": '"0"',
      },
      body: JSON.stringify({ protocol_version: 2, ...writtenSettings }),
    });
    expect(fromMac.status).toBe(200);
    expect(((await fromMac.json()) as AccountSettingsResponse).revision).toBe(1);

    const next = {
      ...writtenSettings,
      budget: { amount_usd: "75.50", alerts: true },
    };
    const fromPhone = await app.request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${ios.token}`,
        "Content-Type": "application/json",
        "If-Match": '"1"',
      },
      body: JSON.stringify({ protocol_version: 2, ...next }),
    });
    expect(fromPhone.status).toBe(200);
    expect(((await fromPhone.json()) as AccountSettingsResponse).budget.amount_usd).toBe("75.50");
  });

  it("refuses a session that does not carry account:settings", async () => {
    await seedAccount("noscope");
    const hasher = new SecretHasher(secret);
    const reader = await seedNativeSession({
      name: "noscope",
      accountId: "account_noscope",
      kind: "ios",
      scopes: ["account:read"],
      hasher,
    });
    const response = await appFor("account_noscope").request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${reader.token}`,
        "Content-Type": "application/json",
        "If-Match": '"0"',
      },
      body: JSON.stringify({ protocol_version: 2, ...writtenSettings }),
    });
    expect(response.status).toBe(403);
    expect(await storedSettings("account_noscope")).toBe(0);
  });

  it("keeps account:settings across a refresh", async () => {
    await seedAccount("rotate");
    const hasher = new SecretHasher(secret);
    const session = await seedNativeSession({
      name: "rotate",
      accountId: "account_rotate",
      kind: "ios",
      scopes: READER_SESSION_SCOPES,
      hasher,
    });
    const state = new D1AccountState(db);
    const rotated = await state.refreshSession({
      refresh_token_hash: session.refreshHash,
      new_access_token_hash: await hasher.hash("ios-access", `qia_${"n".repeat(43)}`),
      new_refresh_token_hash: await hasher.hash("ios-refresh", `qiar_${"n".repeat(43)}`),
      access_expires_at: new Date(now.getTime() + 15 * 60_000).toISOString(),
      refresh_expires_at: new Date(now.getTime() + 90 * 24 * 60_000).toISOString(),
      refreshed_at: now.toISOString(),
    });
    expect(rotated?.scopes).toEqual([...READER_SESSION_SCOPES]);
  });

  it("rate limits writes per Account", async () => {
    await seedAccount("limited");
    const app = appFor("account_limited");
    let ifMatch = '"0"';
    for (let index = 0; index < 30; index += 1) {
      const response = await put(app, writtenSettings, { ifMatch });
      expect(response.status, `write ${index + 1}`).toBe(200);
      const body = (await response.json()) as AccountSettingsResponse;
      ifMatch = `"${body.revision}"`;
    }
    const limited = await put(app, writtenSettings, { ifMatch });
    expect(limited.status).toBe(429);
    expect(await limited.json()).toMatchObject({ error: { code: "rate_limited" } });
  });

  it("refuses a body over the route limit, a 257th selector, and an unknown field", async () => {
    await seedAccount("rules");
    const app = appFor("account_rules");

    const tooLarge = await app.request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      headers: {
        ...webRequest.headers,
        "Content-Length": String(70 * 1024),
      },
      body: "x".repeat(70 * 1024),
    });
    expect(tooLarge.status).toBe(413);

    const tooMany = Object.fromEntries(
      Array.from({ length: MAXIMUM_ACCOUNT_SETTINGS_SELECTORS + 1 }, (_, index) => [
        index.toString(16).padStart(12, "0"),
        [20, 10],
      ]),
    );
    const capped = await put(app, {
      alerts: { reset_reminders: true, pace_alerts: true, thresholds: tooMany },
      budget: { amount_usd: null, alerts: true },
    });
    expect(capped.status).toBe(400);

    const unknown = await app.request(`${origin}/api/v2/account/settings`, {
      method: "PUT",
      ...webRequest,
      body: JSON.stringify({ protocol_version: 2, ...writtenSettings, enabled: false }),
    });
    expect(unknown.status).toBe(400);
    expect(await storedSettings("account_rules")).toBe(0);
  });

  it("leaves history unchanged when a write omits it, and does not turn it off by omission", async () => {
    await seedAccount("history");
    const app = appFor("account_history");
    const on = await put(app, { ...writtenSettings, history: { sync: true } });
    expect(on.status).toBe(200);
    expect(((await on.json()) as AccountSettingsResponse).history).toEqual({ sync: true });

    const omitted = await put(app, writtenSettings, { ifMatch: '"1"' });
    expect(omitted.status).toBe(200);
    expect(((await omitted.json()) as AccountSettingsResponse).history).toEqual({ sync: true });
  });

  it("deletes the settings row with the Account", async () => {
    await seedAccount("gone");
    const app = appFor("account_gone");
    expect((await put(app, writtenSettings)).status).toBe(200);
    expect(await storedSettings("account_gone")).toBe(1);

    const deleted = await app.request(`${origin}/api/v2/account`, {
      method: "DELETE",
      headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" },
    });
    expect(deleted.status).toBe(204);
    expect(await storedSettings("account_gone")).toBe(0);
  });
});

function put(
  app: ReturnType<typeof createRelayApp>,
  settings: AccountSettings,
  options: { ifMatch?: string } = {},
) {
  return app.request(`${origin}/api/v2/account/settings`, {
    method: "PUT",
    headers: { ...webRequest.headers, "If-Match": options.ifMatch ?? '"0"' },
    body: JSON.stringify({ protocol_version: 2, ...settings }),
  });
}

async function seedAccount(name: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO accounts (id, display_label, created_at, updated_at)
       VALUES ('account_${name}', 'Quota Tester', ?1, ?1)`,
    )
    .bind(now.toISOString())
    .run();
}

function storedSettings(accountId: string): Promise<unknown> {
  return db
    .prepare("SELECT COUNT(*) AS count FROM account_settings WHERE account_id = ?1")
    .bind(accountId)
    .first("count");
}

async function seedNativeSession(input: {
  name: string;
  accountId: string;
  kind: "quotabar" | "ios";
  scopes: readonly SessionScope[];
  hasher: SecretHasher;
}): Promise<{ token: string; refreshHash: string }> {
  const accessPrefix = input.kind === "quotabar" ? "qb_" : "qia_";
  const refreshPrefix = input.kind === "quotabar" ? "qbr_" : "qiar_";
  const accessDomain = input.kind === "quotabar" ? "quotabar-access" : "ios-access";
  const refreshDomain = input.kind === "quotabar" ? "quotabar-refresh" : "ios-refresh";
  const fill = input.name.replaceAll("_", "x").padEnd(43, "x").slice(0, 43);
  const token = `${accessPrefix}${fill}`;
  const refresh = `${refreshPrefix}${fill}`;
  let deviceId: string | null = null;
  let generation: number | null = null;
  if (input.kind === "quotabar") {
    deviceId = `device_${input.name}`;
    generation = 1;
    await db
      .prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
      )
      .bind(deviceId, input.accountId, `installation_${input.name}`, now.toISOString())
      .run();
  }
  const refreshHash = await input.hasher.hash(refreshDomain, refresh);
  await db
    .prepare(
      `INSERT INTO sessions (
         id, family_id, account_id, device_id, device_generation, client_kind,
         access_token_hash, refresh_token_hash, scopes_json,
         authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
       ) VALUES (?1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?9, ?9)`,
    )
    .bind(
      `session_${input.name}`,
      input.accountId,
      deviceId,
      generation,
      input.kind,
      await input.hasher.hash(accessDomain, token),
      refreshHash,
      encodeScopes(input.scopes),
      now.toISOString(),
      new Date(now.getTime() + 60 * 60_000).toISOString(),
    )
    .run();
  return { token, refreshHash };
}

function appFor(accountId: string) {
  const state = new D1AccountState(db);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(db),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, now),
    hasher,
    now: () => now,
  });
}
