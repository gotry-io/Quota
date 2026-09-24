import {
  type AccountSettings,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_QUOTA_HISTORY_POINTS_PER_UPLOAD,
  MAXIMUM_QUOTA_HISTORY_UPLOAD_BYTES,
} from "@gotry-io/quota-protocol";
import { quotaHistoryExpiresAt } from "@gotry-io/quota-model";
import { beforeEach, describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import type { SessionScope } from "@gotry-io/relay-core";
import { D1AccountState, quotaHistoryUploadAnswerSql } from "../src/state/d1-account-state.ts";
import { DEVICE_SESSION_SCOPES, encodeScopes } from "../src/state/records.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { testDatabase } from "./support/database.ts";

let db: RelayDatabase;

const now = new Date("2026-09-21T10:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const fingerprint = "account_test";
const since = "2026-08-22T10:00:00Z";
const policy: AccountSettings = {
  alerts: { reset_reminders: true, pace_alerts: true, thresholds: {} },
  budget: { amount_usd: null, alerts: true },
};

beforeEach(async () => {
  db = await testDatabase();
});

describe("Account quota history", () => {
  it("refuses an upload while the switch is off", async () => {
    const session = await seedDevice("off");
    const response = await upload(session, [point("2026-09-21T10:00:00Z", 40)]);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: {
        code: "history_sync_off",
        message: "Quota history sync is off for this Account.",
      },
    });
    expect(await historyCount("account_off")).toBe(0);
  });

  it("upserts buckets, answers the newest bucket_start per series, and merges on read", async () => {
    const session = await seedDevice("on");
    const app = appFor("account_on");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);

    const first = await upload(session, [
      point("2026-09-21T10:00:00Z", 40),
      point("2026-09-21T10:15:00Z", 42.5),
    ]);
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      series: [
        {
          provider: "codex",
          fingerprint,
          window_id: "five_hour",
          bucket_start: "2026-09-21T10:15:00Z",
          oldest_bucket_start: "2026-09-21T10:00:00Z",
        },
      ],
    });

    const retry = await upload(session, [point("2026-09-21T10:00:00Z", 30)]);
    expect(retry.status).toBe(200);
    expect(await cell("account_on", "2026-09-21T10:00:00Z")).toBe(40);

    const other = await seedDevice("on", { name: "peer", deviceId: "device_on_peer" });
    expect(
      (await upload(other, [point("2026-09-21T10:00:00Z", 50), point("2026-09-21T10:15:00Z", 55)]))
        .status,
    ).toBe(200);

    const read = await app.request(historyUrl());
    expect(read.status).toBe(200);
    expect(read.headers.get("Cache-Control")).toBe("private, no-cache");
    const etag = read.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(await read.json()).toEqual({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      sync: true,
      windows: {
        five_hour: {
          duration_seconds: 18_000,
          points: [
            {
              resets_at: "2026-09-21T15:00:00Z",
              bucket_start: "2026-09-21T10:00:00Z",
              used_percent: 50,
            },
            {
              resets_at: "2026-09-21T15:00:00Z",
              bucket_start: "2026-09-21T10:15:00Z",
              used_percent: 55,
            },
          ],
        },
      },
    });

    const again = await app.request(historyUrl(), { headers: { "If-None-Match": etag ?? "" } });
    expect(again.status).toBe(304);
  });

  it("answers a later oldest bucket after the switch went off and on behind the device", async () => {
    const session = await seedDevice("gap");
    const app = appFor("account_gap");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect(
      (
        await upload(session, [
          point("2026-09-21T09:00:00Z", 30),
          point("2026-09-21T09:15:00Z", 35),
        ])
      ).status,
    ).toBe(200);
    expect((await putSettings(app, { ...policy, history: { sync: false } }, '"1"')).status).toBe(
      200,
    );
    expect((await putSettings(app, { ...policy, history: { sync: true } }, '"2"')).status).toBe(
      200,
    );

    const after = await upload(session, [point("2026-09-21T09:45:00Z", 40)]);
    expect(after.status).toBe(200);
    const body = (await after.json()) as {
      series: { bucket_start: string; oldest_bucket_start: string }[];
    };
    expect(body.series).toEqual([
      expect.objectContaining({
        bucket_start: "2026-09-21T09:45:00Z",
        oldest_bucket_start: "2026-09-21T09:45:00Z",
      }),
    ]);
  });

  it("answers the upload with one search of the primary key on device_id", async () => {
    const plan = await db
      .prepare(`EXPLAIN QUERY PLAN ${quotaHistoryUploadAnswerSql}`)
      .bind("device_plan", "account_plan")
      .all<{ detail: string }>();
    expect(
      plan.results.some((row) =>
        /SEARCH quota_history USING INDEX sqlite_autoindex_quota_history_1 \(device_id=\?\)/.test(
          row.detail,
        ),
      ),
    ).toBe(true);
    expect(plan.results.some((row) => /TEMP B-TREE/.test(row.detail))).toBe(false);
  });

  it("answers empty windows while the switch is off, and refuses extra query keys", async () => {
    await seedAccount("empty");
    const app = appFor("account_empty");
    const off = await app.request(historyUrl());
    expect(off.status).toBe(200);
    expect(await off.json()).toEqual({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      sync: false,
      windows: {},
    });
    expect(
      (
        await app.request(
          `${origin}/api/v6/account/quota-history?provider=codex&fingerprint=${fingerprint}&since=${since}&extra=1`,
        )
      ).status,
    ).toBe(400);
  });

  it("refuses an unaligned bucket_start", async () => {
    const session = await seedDevice("align");
    const app = appFor("account_align");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    const response = await upload(session, [point("2026-09-21T10:00:01Z", 10)]);
    expect(response.status).toBe(400);
  });

  it("accepts one bucket ahead of now and refuses two", async () => {
    const session = await seedDevice("future");
    const app = appFor("account_future");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:15:00Z", 40)])).status).toBe(200);
    const twoAhead = await upload(session, [point("2026-09-21T10:30:00Z", 41)]);
    expect(twoAhead.status).toBe(400);
    expect(await twoAhead.json()).toMatchObject({ error: { code: "invalid_request" } });
    expect(await historyCount("account_future")).toBe(1);
  });

  it("accepts a point exactly at span plus one bucket and refuses one bucket older", async () => {
    const session = await seedDevice("slack");
    const app = appFor("account_slack");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-19T09:45:00Z", 40)])).status).toBe(200);
    const older = await upload(session, [point("2026-09-19T09:30:00Z", 41)]);
    expect(older.status).toBe(400);
    expect(await historyCount("account_slack")).toBe(1);
  });

  it("deletes every uploaded row of the Account when the switch turns off, in the same write", async () => {
    const session = await seedDevice("clear");
    const app = appFor("account_clear");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    expect(await historyCount("account_clear")).toBe(1);

    const stale = await putSettings(app, { ...policy, history: { sync: false } }, '"0"');
    expect(stale.status).toBe(412);
    expect(await historyCount("account_clear")).toBe(1);

    const off = await putSettings(app, { ...policy, history: { sync: false } }, '"1"');
    expect(off.status).toBe(200);
    expect(((await off.json()) as { history: { sync: boolean } }).history).toEqual({ sync: false });
    expect(await historyCount("account_clear")).toBe(0);
  });

  it("refuses a stale non-zero If-Match with 412 on the update path and keeps every quota_history row", async () => {
    const session = await seedDevice("cas");
    const app = appFor("account_cas");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    expect((await putSettings(app, { ...policy, history: { sync: true } }, '"1"')).status).toBe(
      200,
    );
    expect(await historyCount("account_cas")).toBe(1);

    const stale = await putSettings(app, { ...policy, history: { sync: false } }, '"1"');
    expect(stale.status).toBe(412);
    expect(
      ((await stale.json()) as { revision: number; history: { sync: boolean } }).revision,
    ).toBe(2);
    expect(await historyCount("account_cas")).toBe(1);
  });

  it("deletes a Device's rows with the Device, and the Account's rows with the Account", async () => {
    const session = await seedDevice("gone");
    const app = appFor("account_gone");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    expect(await historyCount("account_gone")).toBe(1);

    const deletedDevice = await app.request(
      `${origin}/api/v2/account/devices/${session.deviceId}`,
      {
        method: "DELETE",
        headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" },
      },
    );
    expect(deletedDevice.status).toBe(200);
    expect(await historyCount("account_gone")).toBe(0);

    const again = await seedDevice("gone", { name: "second", deviceId: "device_gone_2" });
    expect((await putSettings(app, { ...policy, history: { sync: true } }, '"1"')).status).toBe(
      200,
    );
    expect((await upload(again, [point("2026-09-21T10:00:00Z", 11)])).status).toBe(200);
    expect(await historyCount("account_gone")).toBe(1);

    const deletedAccount = await app.request(`${origin}/api/v2/account`, {
      method: "DELETE",
      headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" },
    });
    expect(deletedAccount.status).toBe(204);
    expect(await historyCount("account_gone")).toBe(0);
  });

  it("clamps a 30-day since to 48 hours for a five-hour window", async () => {
    await seedAccount("span");
    await db
      .prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_span', 'account_span', 'installation_span', 1, ?1, ?1)`,
      )
      .bind(now.toISOString())
      .run();
    await db.batch([
      insertHistory("five_hour", 18_000, "2026-09-19T09:45:00Z", "2026-09-19T15:00:00Z"),
      insertHistory("five_hour", 18_000, "2026-09-19T10:00:00Z", "2026-09-19T15:00:00Z"),
      insertHistory("weekly", 604_800, "2026-09-18T10:00:00Z", "2026-09-28T00:00:00Z"),
    ]);
    const app = appFor("account_span");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    const read = await app.request(historyUrl());
    expect(read.status).toBe(200);
    const body = (await read.json()) as {
      windows: Record<string, { points: { bucket_start: string }[] }>;
    };
    expect(body.windows.five_hour?.points.map((row) => row.bucket_start)).toEqual([
      "2026-09-19T10:00:00Z",
    ]);
    expect(body.windows.weekly?.points.map((row) => row.bucket_start)).toEqual([
      "2026-09-18T10:00:00Z",
    ]);
  });

  it("sweeps a five-hour row after 48 hours and a weekly row after 28 days", async () => {
    await seedAccount("sweep");
    await db
      .prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_sweep', 'account_sweep', 'installation_sweep', 1, ?1, ?1)`,
      )
      .bind(now.toISOString())
      .run();
    await db.batch([
      insertHistory(
        "five_hour",
        18_000,
        "2026-09-19T09:45:00Z",
        "2026-09-19T15:00:00Z",
        "account_sweep",
        "device_sweep",
      ),
      insertHistory(
        "five_hour",
        18_000,
        "2026-09-19T10:00:00Z",
        "2026-09-19T15:00:00Z",
        "account_sweep",
        "device_sweep",
      ),
      insertHistory(
        "weekly",
        604_800,
        "2026-08-24T09:00:00Z",
        "2026-08-31T00:00:00Z",
        "account_sweep",
        "device_sweep",
      ),
      insertHistory(
        "weekly",
        604_800,
        "2026-08-24T10:00:00Z",
        "2026-08-31T00:00:00Z",
        "account_sweep",
        "device_sweep",
      ),
    ]);
    await new D1AccountState(db).performMaintenance(accountMaintenanceInput(now));
    const remaining = await db
      .prepare(
        `SELECT window_id, bucket_start FROM quota_history
         WHERE account_id = 'account_sweep' ORDER BY window_id, bucket_start`,
      )
      .all<{ window_id: string; bucket_start: string }>();
    expect(remaining.results).toEqual([
      { window_id: "five_hour", bucket_start: "2026-09-19T10:00:00Z" },
      { window_id: "weekly", bucket_start: "2026-08-24T10:00:00Z" },
    ]);
  });

  it("searches quota_history_expires_idx for the sweep and quota_history_read_idx for the read", async () => {
    const sweep = await db
      .prepare(
        `EXPLAIN QUERY PLAN
         DELETE FROM quota_history WHERE rowid IN (
           SELECT rowid FROM quota_history
           WHERE expires_at < ?1
           ORDER BY expires_at ASC LIMIT 5000
         )`,
      )
      .bind(now.toISOString())
      .all<{ detail: string }>();
    expect(
      sweep.results.some(
        (row) => row.detail.includes("quota_history_expires_idx") && /SEARCH/i.test(row.detail),
      ),
    ).toBe(true);

    const read = await db
      .prepare(
        `EXPLAIN QUERY PLAN
         SELECT window_id FROM quota_history
         WHERE account_id = ?1 AND provider = ?2 AND fingerprint = ?3
           AND bucket_start >= ?4`,
      )
      .bind("account_plan", "codex", fingerprint, since)
      .all<{ detail: string }>();
    expect(
      read.results.some(
        (row) => row.detail.includes("quota_history_read_idx") && /SEARCH/i.test(row.detail),
      ),
    ).toBe(true);
  });

  it("rewrites every row of a window to the latest declared duration and expiry", async () => {
    const first = await seedDevice("dur");
    const app = appFor("account_dur");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(first, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    const peer = await seedDevice("dur", { name: "peer", deviceId: "device_dur_peer" });
    expect(
      (
        await upload(peer, [point("2026-09-21T10:00:00Z", 50)], {
          durationSeconds: 604_800,
        })
      ).status,
    ).toBe(200);

    const rows = await db
      .prepare(
        `SELECT duration_seconds, expires_at FROM quota_history
         WHERE account_id = 'account_dur' ORDER BY device_id`,
      )
      .all<{ duration_seconds: number; expires_at: string }>();
    expect(rows.results).toHaveLength(2);
    expect(
      rows.results.every(
        (row) =>
          row.duration_seconds === 604_800 &&
          row.expires_at === quotaHistoryExpiresAt("2026-09-21T10:00:00Z", 604_800),
      ),
    ).toBe(true);

    const read = await app.request(historyUrl());
    expect(
      ((await read.json()) as { windows: { five_hour: { duration_seconds: number } } }).windows
        .five_hour.duration_seconds,
    ).toBe(604_800);
  });

  it("refuses an upload when the Account is already at the row ceiling", async () => {
    const session = await seedDevice("full");
    const app = appFor("account_full", { quotaHistoryRowLimit: 1 });
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)], { app })).status).toBe(200);
    const second = await upload(session, [point("2026-09-21T10:15:00Z", 41)], { app });
    expect(second.status).toBe(413);
    expect(await second.json()).toEqual({
      error: {
        code: "quota_history_full",
        message: "This Account already holds the maximum number of quota-history rows.",
      },
    });
    expect(await historyCount("account_full")).toBe(1);
  });

  it("refuses a generation mismatch with 409 stale_generation", async () => {
    const session = await seedDevice("gen");
    const app = appFor("account_gen");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    const response = await upload(session, [point("2026-09-21T10:00:00Z", 40)], { generation: 2 });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: { code: "stale_generation" } });
    expect(await historyCount("account_gen")).toBe(0);
  });

  it("does not let a device of another Account write or read this Account's series", async () => {
    const owner = await seedDevice("iso_a");
    const other = await seedDevice("iso_b");
    const ownerApp = appFor("account_iso_a");
    const otherApp = appFor("account_iso_b");
    expect((await putSettings(ownerApp, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await putSettings(otherApp, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(owner, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);

    const otherRead = await otherApp.request(historyUrl());
    expect(otherRead.status).toBe(200);
    expect(await otherRead.json()).toEqual({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      sync: true,
      windows: {},
    });
    expect((await upload(other, [point("2026-09-21T10:00:00Z", 99)])).status).toBe(200);
    expect(await cell("account_iso_a", "2026-09-21T10:00:00Z")).toBe(40);
    expect(await historyCount("account_iso_a")).toBe(1);
    expect(await historyCount("account_iso_b")).toBe(1);
  });

  it("refuses an upload from a deleted device the way other device routes do", async () => {
    const session = await seedDevice("revoked");
    const app = appFor("account_revoked");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    const deleted = await app.request(`${origin}/api/v2/account/devices/${session.deviceId}`, {
      method: "DELETE",
      headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" },
    });
    expect(deleted.status).toBe(200);
    const response = await upload(session, [point("2026-09-21T10:15:00Z", 41)]);
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: { code: "unauthorized" } });
  });

  it("refuses 2001 points and a body larger than 256 KiB", async () => {
    const session = await seedDevice("cap");
    const app = appFor("account_cap");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    const tooMany = await upload(
      session,
      Array.from({ length: MAXIMUM_QUOTA_HISTORY_POINTS_PER_UPLOAD + 1 }, () =>
        point("2026-09-21T10:00:00Z", 10),
      ),
    );
    expect(tooMany.status).toBe(400);

    const tooLarge = await app.request(`${origin}/api/v6/device/quota-history`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${session.token}`,
        "Content-Type": "application/json",
      },
      body: "x".repeat(MAXIMUM_QUOTA_HISTORY_UPLOAD_BYTES + 1),
    });
    expect(tooLarge.status).toBe(413);
  });

  it("changes the read ETag when the switch flips or a point is added, not on a no-op re-upload", async () => {
    const session = await seedDevice("etag");
    const app = appFor("account_etag");
    const off = await app.request(historyUrl());
    const offEtag = off.headers.get("ETag");
    expect((await putSettings(app, { ...policy, history: { sync: true } })).status).toBe(200);
    const onEmpty = await app.request(historyUrl());
    const onEmptyEtag = onEmpty.headers.get("ETag");
    expect(onEmptyEtag).not.toBe(offEtag);

    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    const withPoint = await app.request(historyUrl());
    const withPointEtag = withPoint.headers.get("ETag");
    expect(withPointEtag).not.toBe(onEmptyEtag);

    expect((await upload(session, [point("2026-09-21T10:00:00Z", 40)])).status).toBe(200);
    const noop = await app.request(historyUrl());
    expect(noop.headers.get("ETag")).toBe(withPointEtag);
  });
});

function point(bucketStart: string, usedPercent: number) {
  return {
    resets_at: "2026-09-21T15:00:00Z",
    bucket_start: bucketStart,
    used_percent: usedPercent,
  };
}

function historyUrl(): string {
  return `${origin}/api/v6/account/quota-history?provider=codex&fingerprint=${fingerprint}&since=${since}`;
}

function putSettings(
  app: ReturnType<typeof createRelayApp>,
  settings: AccountSettings,
  ifMatch = '"0"',
) {
  return app.request(`${origin}/api/v2/account/settings`, {
    method: "PUT",
    headers: {
      Origin: origin,
      "Sec-Fetch-Site": "same-origin",
      "Content-Type": "application/json",
      "If-Match": ifMatch,
    },
    body: JSON.stringify({ protocol_version: 2, ...settings }),
  });
}

async function upload(
  session: { token: string; generation: number; accountId: string },
  points: ReturnType<typeof point>[],
  extras: {
    durationSeconds?: number;
    generation?: number;
    windowId?: string;
    app?: ReturnType<typeof createRelayApp>;
  } = {},
) {
  const app = extras.app ?? appFor(session.accountId);
  return app.request(`${origin}/api/v6/device/quota-history`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${session.token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      generation: extras.generation ?? session.generation,
      series: [
        {
          provider: "codex",
          fingerprint,
          window_id: extras.windowId ?? "five_hour",
          duration_seconds: extras.durationSeconds ?? 18_000,
          points,
        },
      ],
    }),
  });
}

function insertHistory(
  windowId: string,
  durationSeconds: number,
  bucketStart: string,
  resetsAt: string,
  accountId = "account_span",
  deviceId = "device_span",
) {
  return db
    .prepare(
      `INSERT INTO quota_history (
         device_id, account_id, provider, fingerprint, window_id, resets_at, bucket_start,
         used_percent, duration_seconds, updated_at, expires_at
       ) VALUES (?1, ?2, 'codex', ?3, ?4, ?5, ?6, 10, ?7, ?8, ?9)`,
    )
    .bind(
      deviceId,
      accountId,
      fingerprint,
      windowId,
      resetsAt,
      bucketStart,
      durationSeconds,
      now.toISOString(),
      quotaHistoryExpiresAt(bucketStart, durationSeconds),
    );
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

async function seedDevice(
  accountName: string,
  options: { name?: string; deviceId?: string } = {},
): Promise<{ token: string; generation: number; deviceId: string; accountId: string }> {
  const name = options.name ?? accountName;
  if (options.name === undefined) await seedAccount(accountName);
  const hasher = new SecretHasher(secret);
  const fill = name.replaceAll("_", "x").padEnd(43, "x").slice(0, 43);
  const token = `qb_${fill}`;
  const deviceId = options.deviceId ?? `device_${name}`;
  await db
    .prepare(
      `INSERT INTO devices (
         id, account_id, installation_id_hash, generation, created_at, last_login_at
       ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
    )
    .bind(deviceId, `account_${accountName}`, `installation_${name}`, now.toISOString())
    .run();
  await db
    .prepare(
      `INSERT INTO sessions (
         id, family_id, account_id, device_id, device_generation, client_kind,
         access_token_hash, refresh_token_hash, scopes_json,
         authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
       ) VALUES (?1, ?1, ?2, ?3, 1, 'quotabar', ?4, ?5, ?6, ?7, ?8, ?8, ?7, ?7)`,
    )
    .bind(
      `session_${name}`,
      `account_${accountName}`,
      deviceId,
      await hasher.hash("quotabar-access", token),
      await hasher.hash("quotabar-refresh", `qbr_${fill}`),
      encodeScopes(DEVICE_SESSION_SCOPES as readonly SessionScope[]),
      now.toISOString(),
      new Date(now.getTime() + 60 * 60_000).toISOString(),
    )
    .run();
  return { token, generation: 1, deviceId, accountId: `account_${accountName}` };
}

function appFor(accountId: string, extras: { quotaHistoryRowLimit?: number } = {}) {
  const state = new D1AccountState(db);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(db),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, now),
    hasher,
    now: () => now,
    ...(extras.quotaHistoryRowLimit === undefined
      ? {}
      : { quotaHistoryRowLimit: extras.quotaHistoryRowLimit }),
  });
}

function historyCount(accountId: string): Promise<unknown> {
  return db
    .prepare("SELECT COUNT(*) AS count FROM quota_history WHERE account_id = ?1")
    .bind(accountId)
    .first("count");
}

function cell(accountId: string, bucketStart: string): Promise<unknown> {
  return db
    .prepare(
      `SELECT used_percent FROM quota_history
       WHERE account_id = ?1 AND bucket_start = ?2`,
    )
    .bind(accountId, bucketStart)
    .first("used_percent");
}
