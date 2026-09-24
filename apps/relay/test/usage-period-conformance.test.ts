import type { DeviceWriterPrincipal, UsageUpload } from "@gotry-io/relay-core";
import { AccountUsagePeriodResponseSchema, USAGE_HOUR_GRID_RULE } from "@gotry-io/quota-protocol";
import { beforeEach, describe, expect, it } from "vitest";
import conformanceJson from "../../../packages/protocol/fixtures/usage-period-conformance.json" with {
  type: "json",
};
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
import { planLocalDateRange } from "../src/local-periods.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { testDatabase } from "./support/database.ts";

type PeriodTotals = { messages: number; total_tokens: number };
type PeriodDay = { date: string; totals: PeriodTotals; cost: { amount_microusd: string | null } };
type PeriodBody = {
  protocol_version: number;
  request: { from: string; to: string; timezone: string };
  bounds: { start: string; end: string; grid: string };
  totals: PeriodTotals;
  cost: { status: string; amount_microusd: string | null; unpriced_rows: number };
  days: PeriodDay[];
  agents?: unknown[];
  coverage: {
    partial: boolean;
    daily_retained_from: string | null;
    hourly_retained_from: string | null;
    truncated_by_retention: boolean;
  };
};

type Expected = {
  bounds?: { start: string; end: string };
  day_dates?: string[];
  omitted_dates?: string[];
  totals?: { messages: number };
  cost_status?: string;
  cost_amount_is_zero?: boolean;
  coverage?: PeriodBody["coverage"];
  etag_stable_next_day?: boolean;
  midnight_hour?: string;
};

type SeedHour = {
  bucket_start_utc: string;
  device?: string;
  model?: string;
  partial?: boolean;
};

type Case = {
  name: string;
  checked_at: string;
  timezone: string;
  from?: string;
  to?: string;
  adjacent?: { from: string; to: string };
  adjacent_expected?: Expected;
  expected?: Expected;
  summary_presets?: Array<{
    key: "today" | "last_7_days" | "last_30_days";
    from: string;
    to: string;
    expected: Expected;
  }>;
  reads?: Array<{ from: string; to: string; expected: Expected }>;
  seed?: { hours?: SeedHour[]; devices?: string[]; every_hour_in_bounds?: boolean };
  delete_devices?: string[];
  delete_account?: boolean;
  run_maintenance?: boolean;
};

const conformance = conformanceJson as unknown as {
  hour_grid_rule: string;
  maximum_local_days: number;
  cases: Case[];
};

const HOUR = 3_600_000;
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const accountId = "account_period";

let db: RelayDatabase;

beforeEach(async () => {
  db = await testDatabase();
  await db.batch(
    [
      "account_usage_folds",
      "usage_daily",
      "usage_hourly",
      "usage_hour_scans",
      "quota_snapshots",
      "devices",
      "accounts",
    ].map((table) => db.prepare(`DELETE FROM ${table}`)),
  );
  await db
    .prepare(`INSERT INTO accounts (id, created_at, updated_at) VALUES (?1, ?2, ?2)`)
    .bind(accountId, "2026-08-10T12:00:00.000Z")
    .run();
});

describe("Account usage period conformance", () => {
  it("answers every fixture case as producer", async () => {
    expect(conformance.hour_grid_rule).toBe(USAGE_HOUR_GRID_RULE);
    expect(conformance.maximum_local_days).toBe(366);
    for (const testCase of conformance.cases) {
      await db.batch(
        ["usage_daily", "usage_hourly", "usage_hour_scans", "devices", "accounts"].map((table) =>
          db.prepare(`DELETE FROM ${table}`),
        ),
      );
      const checkedAt = new Date(testCase.checked_at);
      await db
        .prepare(`INSERT INTO accounts (id, created_at, updated_at) VALUES (?1, ?2, ?2)`)
        .bind(accountId, checkedAt.toISOString())
        .run();
      const devices = testCase.seed?.devices ?? ["alpha"];
      for (const name of devices) await addDevice(name, checkedAt);
      const hours = seedHours(testCase);
      const byDevice = new Map<string, SeedHour[]>();
      for (const hour of hours) {
        const device = hour.device ?? devices[0] ?? "alpha";
        const list = byDevice.get(device);
        if (list) list.push(hour);
        else byDevice.set(device, [hour]);
      }
      const usage = new D1UsageState(db);
      for (const [name, deviceHours] of byDevice) {
        for (let index = 0; index < deviceHours.length; index += 64) {
          await usage.recordUsage(
            principal(name, checkedAt),
            upload(
              deviceHours
                .slice(index, index + 64)
                .map((hour, offset) =>
                  hourOf(hour.bucket_start_utc, index + offset + 1, hour.model, hour.partial),
                ),
            ),
            checkedAt.toISOString(),
          );
        }
      }
      if (testCase.run_maintenance) {
        await new D1AccountState(db).performMaintenance(accountMaintenanceInput(checkedAt));
      }
      if (testCase.delete_devices) {
        const state = new D1AccountState(db);
        for (const name of testCase.delete_devices) {
          expect(
            await state.deleteDeviceData(accountId, `device_${name}`, checkedAt.toISOString()),
          ).not.toBeNull();
        }
      }

      const app = signedInApp(checkedAt);
      if (testCase.summary_presets) {
        const summary = (await (
          await app.request(
            `https://quota.gotry.io/api/v6/account/summary?tz=${encodeURIComponent(testCase.timezone)}`,
          )
        ).json()) as { usage: Record<string, { totals: PeriodTotals }> };
        for (const preset of testCase.summary_presets) {
          const body = await readPeriod(app, testCase.timezone, preset.from, preset.to);
          expectPeriod(body, preset.expected, testCase.name, preset.key);
          expect(body.totals.messages, `${testCase.name} ${preset.key} vs summary`).toBe(
            summary.usage[preset.key]?.totals.messages,
          );
          expect(body.totals.total_tokens, `${testCase.name} ${preset.key} vs summary tokens`).toBe(
            summary.usage[preset.key]?.totals.total_tokens,
          );
        }
        continue;
      }

      if (testCase.reads) {
        for (const read of testCase.reads) {
          const body = await readPeriod(app, testCase.timezone, read.from, read.to);
          expectPeriod(body, read.expected, testCase.name, `${read.from}..${read.to}`);
          if (read.expected.etag_stable_next_day) {
            await expectStableEtag(testCase.timezone, read.from, read.to, checkedAt);
          }
        }
        continue;
      }

      if (!testCase.from || !testCase.to || !testCase.expected) {
        throw new Error(`${testCase.name} is missing from/to/expected`);
      }
      const body = await readPeriod(app, testCase.timezone, testCase.from, testCase.to);
      expectPeriod(body, testCase.expected, testCase.name);
      if (testCase.adjacent && testCase.adjacent_expected) {
        const next = await readPeriod(
          app,
          testCase.timezone,
          testCase.adjacent.from,
          testCase.adjacent.to,
        );
        expectPeriod(next, testCase.adjacent_expected, testCase.name, "adjacent");
        expect(body.bounds.end, `${testCase.name} adjacent share`).toBe(next.bounds.start);
        if (testCase.expected.midnight_hour) {
          expect(testCase.expected.midnight_hour < body.bounds.end).toBe(true);
          expect(testCase.expected.midnight_hour >= next.bounds.start).toBe(false);
        }
      }
      if (testCase.delete_account) {
        expect(await new D1AccountState(db).deleteAccountData(accountId)).toBe(true);
        expect(await db.prepare("SELECT COUNT(*) AS n FROM usage_hourly").first("n")).toBe(0);
        expect(await db.prepare("SELECT COUNT(*) AS n FROM usage_daily").first("n")).toBe(0);
      }
    }
  });

  it("refuses a malformed date, a reversed range, a span over 366 days, and an unknown zone", async () => {
    await addDevice("alpha", new Date("2026-08-10T12:00:00Z"));
    const app = signedInApp(new Date("2026-08-10T12:00:00Z"));
    const period = "https://quota.gotry.io/api/v6/account/usage/period";
    expect((await app.request(`${period}?from=2026-13-40&to=2026-08-10&timezone=UTC`)).status).toBe(
      400,
    );
    expect((await app.request(`${period}?from=2026-08-10&to=2026-08-01&timezone=UTC`)).status).toBe(
      400,
    );
    expect((await app.request(`${period}?from=2024-01-01&to=2025-01-01&timezone=UTC`)).status).toBe(
      400,
    );
    expect((await app.request(`${period}?from=2024-01-01&to=2024-12-31&timezone=UTC`)).status).toBe(
      200,
    );
    expect(
      (await app.request(`${period}?from=2026-08-10&to=2026-08-10&timezone=Mars/Olympus_Mons`))
        .status,
    ).toBe(400);
    expect((await app.request(`${period}?from=2026-08-10&to=2026-08-10`)).status).toBe(400);
    expect(
      (await app.request(`${period}?from=2026-08-10&to=2026-08-10&timezone=UTC&breakdown=yes`))
        .status,
    ).toBe(400);
    expect(
      (await app.request(`${period}?from=2026-08-10&to=2026-08-10&timezone=UTC&extra=1`)).status,
    ).toBe(400);
  });

  it("answers 304 from the validator before any Usage SQL", async () => {
    const checkedAt = new Date("2026-08-10T12:00:00Z");
    await addDevice("alpha", checkedAt);
    await new D1UsageState(db).recordUsage(
      principal("alpha", checkedAt),
      upload([hourOf("2026-08-10T10:00:00Z", 1)]),
      checkedAt.toISOString(),
    );
    const statements: string[] = [];
    const app = signedInApp(checkedAt, recordingD1(statements));
    const path =
      "https://quota.gotry.io/api/v6/account/usage/period?from=2026-08-10&to=2026-08-10&timezone=UTC";
    const first = await app.request(path);
    expect(first.status).toBe(200);
    const body = (await first.json()) as PeriodBody;
    expect(AccountUsagePeriodResponseSchema.safeParse(body).success).toBe(true);
    expect(Object.hasOwn(body, "agents")).toBe(false);
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(first.headers.get("Cache-Control")).toBe("private, no-cache");

    statements.length = 0;
    const unchanged = await app.request(path, { headers: { "If-None-Match": etag ?? "" } });
    expect(unchanged.status).toBe(304);
    expect(unchanged.headers.get("ETag")).toBe(etag);
    expect(await unchanged.text()).toBe("");
    expect(statements.join("\n")).not.toMatch(/usage_hourly/);
    expect(statements.join("\n")).not.toMatch(/usage_daily/);

    const withAgents = await app.request(`${path}&breakdown=1`);
    expect(withAgents.status).toBe(200);
    const detailed = (await withAgents.json()) as PeriodBody;
    expect(Array.isArray(detailed.agents)).toBe(true);
    expect(withAgents.headers.get("ETag")).not.toBe(etag);

    await db
      .prepare(
        `INSERT INTO quota_snapshots (
         device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at
       ) VALUES ('device_alpha', 'codex', 'fingerprint_period', ?1, '{}', ?1)`,
      )
      .bind(checkedAt.toISOString())
      .run();
    expect((await app.request(path, { headers: { "If-None-Match": etag ?? "" } })).status).toBe(
      304,
    );

    const bumped = signedInApp(checkedAt, db, { usageFoldVersion: 2 });
    expect((await bumped.request(path, { headers: { "If-None-Match": etag ?? "" } })).status).toBe(
      200,
    );
  });

  it("answers a dense local day without resultLimit when hour-identity rows would overflow", async () => {
    const checkedAt = new Date("2026-08-10T12:00:00Z");
    await addDevice("alpha", checkedAt);
    const models = Array.from({ length: 8 }, (_, index) => `dense-model-${index}`);
    const hours = Array.from({ length: 24 }, (_, hour) =>
      hourOf(`2026-08-10T${String(hour).padStart(2, "0")}:00:00Z`, 1, models[0], false, models),
    );
    await new D1UsageState(db).recordUsage(
      principal("alpha", checkedAt),
      upload(hours),
      checkedAt.toISOString(),
    );
    const usage = new D1UsageState(db);
    const hourly = await usage.queryHourlyUsage(accountId, {
      from: "2026-08-10T00:00:00Z",
      to: "2026-08-11T00:00:00Z",
      limit: 50,
    });
    expect(hourly.truncated).toBe(true);
    expect(hourly.rows.length).toBe(50);

    const path =
      "https://quota.gotry.io/api/v6/account/usage/period?from=2026-08-10&to=2026-08-10&timezone=UTC";
    const grouped = await signedInApp(checkedAt, db, { usageLocalDayLimit: 50 }).request(path);
    expect(grouped.status).toBe(200);
    const body = (await grouped.json()) as PeriodBody;
    expect(body.days.map((day) => day.date)).toEqual(["2026-08-10"]);
    expect(body.totals.messages).toBe(24 * 8);

    const capped = await signedInApp(checkedAt, db, { usageLocalDayLimit: 3 }).request(path);
    expect(capped.status).toBe(413);
  });
});

function seedHours(testCase: Case): SeedHour[] {
  if (testCase.seed?.hours) return testCase.seed.hours;
  if (!testCase.seed?.every_hour_in_bounds || !testCase.from || !testCase.to) return [];
  const plan = planLocalDateRange(testCase.timezone, testCase.from, testCase.to);
  const hours: SeedHour[] = [];
  for (let instant = Date.parse(plan.start); instant < Date.parse(plan.end); instant += HOUR) {
    hours.push({
      bucket_start_utc: `${new Date(instant).toISOString().slice(0, 19)}Z`,
    });
  }
  return hours;
}

function expectPeriod(body: PeriodBody, expected: Expected, name: string, label = ""): void {
  const tag = label ? `${name} ${label}` : name;
  expect(body.protocol_version, tag).toBe(6);
  expect(body.bounds.grid, tag).toBe(USAGE_HOUR_GRID_RULE);
  if (expected.bounds) expect(body.bounds, tag).toMatchObject(expected.bounds);
  if (expected.day_dates) {
    expect(
      body.days.map((day) => day.date),
      tag,
    ).toEqual(expected.day_dates);
  }
  if (expected.omitted_dates) {
    const dates = new Set(body.days.map((day) => day.date));
    for (const date of expected.omitted_dates)
      expect(dates.has(date), `${tag} ${date}`).toBe(false);
  }
  if (expected.totals) expect(body.totals.messages, tag).toBe(expected.totals.messages);
  if (expected.cost_status) expect(body.cost.status, tag).toBe(expected.cost_status);
  if (expected.cost_amount_is_zero === false) {
    expect(body.cost.amount_microusd, tag).not.toBe("0");
    expect(body.cost.unpriced_rows, tag).toBeGreaterThan(0);
  }
  if (expected.coverage) expect(body.coverage, tag).toEqual(expected.coverage);
}

async function readPeriod(
  app: ReturnType<typeof signedInApp>,
  timezone: string,
  from: string,
  to: string,
  breakdown = false,
): Promise<PeriodBody> {
  const params = new URLSearchParams({ from, to, timezone });
  if (breakdown) params.set("breakdown", "1");
  const response = await app.request(
    `https://quota.gotry.io/api/v6/account/usage/period?${params.toString()}`,
  );
  expect(response.status, `${timezone} ${from}..${to}`).toBe(200);
  const body = (await response.json()) as PeriodBody;
  expect(AccountUsagePeriodResponseSchema.safeParse(body).success, `${from}..${to}`).toBe(true);
  return body;
}

async function expectStableEtag(
  timezone: string,
  from: string,
  to: string,
  checkedAt: Date,
): Promise<void> {
  const path = `https://quota.gotry.io/api/v6/account/usage/period?from=${from}&to=${to}&timezone=${encodeURIComponent(timezone)}`;
  const first = await signedInApp(checkedAt).request(path);
  expect(first.status).toBe(200);
  const etag = first.headers.get("ETag");
  const nextDay = new Date(checkedAt.getTime() + 86_400_000);
  const later = await signedInApp(nextDay).request(path, {
    headers: { "If-None-Match": etag ?? "" },
  });
  expect(later.status).toBe(304);
  expect(later.headers.get("ETag")).toBe(etag);
}

async function addDevice(name: string, at: Date): Promise<void> {
  await db
    .prepare(
      `INSERT INTO devices (
       id, account_id, installation_id_hash, generation, created_at, last_login_at
     ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
    )
    .bind(`device_${name}`, accountId, `installation_${name}`, at.toISOString())
    .run();
}

function principal(name: string, at: Date): DeviceWriterPrincipal {
  return {
    session_id: `session_${name}`,
    family_id: `family_${name}`,
    account_id: accountId,
    device_id: `device_${name}`,
    device_generation: 1,
    client_kind: "quotabar",
    scopes: ["account:read", "device:write"],
    authenticated_at: at.toISOString(),
  };
}

function hourOf(
  bucket: string,
  scanVersion: number,
  model = "gpt-5.6-sol",
  partial = false,
  models: readonly string[] = [model],
) {
  return {
    bucket_start_utc: bucket,
    scan_version: scanVersion,
    partial,
    rows: models.map((item) => ({
      agent: "codex" as const,
      billing_channel: "openai_direct" as const,
      channel_source: "agent_default" as const,
      model: item,
      context_bucket: "le_128k" as const,
      service_tier: "unknown",
      speed: "unknown",
      inference_geo: "unknown",
      input_tokens: 10,
      cache_read_tokens: 0,
      cache_write_5m_tokens: 0,
      cache_write_1h_tokens: 0,
      cache_write_inferred_tokens: 0,
      output_tokens: 2,
      reasoning_tokens: 0,
      requests: 1,
      web_search_requests: 0,
      web_fetch_requests: 0,
      source_cost_covered_requests: 0,
    })),
  };
}

function upload(hours: ReturnType<typeof hourOf>[]): UsageUpload {
  return { protocol_version: 6, generation: 1, agent: "codex", hours };
}

function signedInApp(
  readAt: Date,
  database: RelayDatabase = db,
  extras: { usageFoldVersion?: number; usageLocalDayLimit?: number } = {},
) {
  const state = new D1AccountState(database);
  const hasher = new SecretHasher(secret);
  return createRelayApp({
    state,
    usageState: new D1UsageState(database),
    accountService: new AccountService(state, hasher, secret),
    webSessions: new SignedInWebSessionStub(accountId, readAt),
    hasher,
    now: () => readAt,
    ...extras,
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
