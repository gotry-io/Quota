/**
 * Synthetic rollup-plus-boundary period query benchmark.
 *
 * Not part of `pnpm test`. Node's type-strip cannot load `sqlite-database.ts`
 * (parameter properties), so bundle first. From the repository root:
 *
 *   pnpm --filter @gotry-io/quota-relay exec esbuild bench/period-query.bench.ts \
 *     --bundle --platform=node --format=esm --target=node24 --external:better-sqlite3 \
 *     --outfile=/tmp/quota-period-query.mjs
 *   PERIOD_BENCH_MIGRATIONS="$PWD/apps/relay/migrations" node /tmp/quota-period-query.mjs
 *
 * Production approximation (OrbStack / dmit: 1 vCPU, 192 MiB, heap 64 MiB):
 *   docker run --rm --cpus=1 --memory=192m -e NODE_OPTIONS=--max-old-space-size=64 \
 *     -e PERIOD_BENCH_HOST=docker …
 */
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { applyMigrations } from "../src/platform/migrations.ts";
import { SqliteDatabase } from "../src/platform/sqlite-database.ts";
import {
  type LocalDateRangePlan,
  planLocalDateRange,
  planLocalDayWindows,
  planLocalPeriods,
} from "../src/local-periods.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const ACCOUNT_ID = "account_bench";
const DISTRACTOR_ID = "account_other";
const CHECKED_AT = new Date("2026-01-15T18:00:00Z");
const END_UTC_DATE = "2026-01-16";
/** Extra UTC days so a 365-local-day window in UTC−3:30 still sits inside the seed. */
const SEED_DAYS = 370;
const QUERY_DAYS = 365;
const HOUR_STEP = 2;
const AGENTS = ["codex", "claude_code", "grok", "cursor"] as const;
const MODELS = ["gpt-5.6-sol", "claude-opus-5"] as const;
const DEVICE_COUNT = 3;
const QUERY_LIMIT = 100_000;
const ZONES = [
  { name: "UTC+8", tz: "Asia/Singapore" },
  { name: "UTC-3:30", tz: "America/St_Johns" },
] as const;

function migrationsDirectory(): string {
  const fromEnv = process.env.PERIOD_BENCH_MIGRATIONS;
  if (fromEnv) return fromEnv;
  const candidates = [
    fileURLToPath(new URL("../migrations", import.meta.url)),
    join(process.cwd(), "apps/relay/migrations"),
    join(process.cwd(), "migrations"),
  ];
  const found = candidates.find((path) => existsSync(path));
  if (!found) throw new Error("cannot find apps/relay/migrations");
  return found;
}

interface DateWindow {
  from: string;
  to: string;
}

interface HourRange {
  from: string;
  to: string;
}

interface QueryMeasurement {
  host: string;
  zone: string;
  timezone: string;
  kind: string;
  local_from: string;
  local_to: string;
  start: string;
  end: string;
  interior_utc_days: number;
  boundary_ranges: number;
  daily_rows_scanned: number;
  hourly_rows_scanned: number;
  daily_rows_returned: number;
  boundary_rows_returned: number;
  hourly_full_rows_scanned: number;
  hourly_full_rows_returned: number;
  tokens: number;
  truncated: boolean;
  cold_plan_ms: number;
  cold_totals_ms: number;
  cold_hourly_ms: number | null;
  warm_totals_ms: number;
  warm_hourly_ms: number | null;
  rss_after_mb: number;
  peak_rss_mb: number;
  hourly_error: string | null;
}

function rssMb(): number {
  return process.memoryUsage().rss / (1024 * 1024);
}

function elapsedMs(started: bigint): number {
  return Number(process.hrtime.bigint() - started) / 1e6;
}

function utcDate(instant: number): string {
  return new Date(instant).toISOString().slice(0, 10);
}

function utcHour(instant: number): string {
  return `${new Date(instant).toISOString().slice(0, 19)}Z`;
}

function shiftDate(date: string, days: number): string {
  return utcDate(Date.parse(`${date}T00:00:00Z`) + days * DAY);
}

function wallClock(clock: Intl.DateTimeFormat, instant: number): number {
  const parts = clock.formatToParts(instant);
  const field = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === type)?.value);
  return Date.UTC(
    field("year"),
    field("month") - 1,
    field("day"),
    field("hour"),
    field("minute"),
    field("second"),
  );
}

function localDateAt(clock: Intl.DateTimeFormat, instant: number): string {
  return utcDate(wallClock(clock, instant));
}

function zoneClock(timezone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function hoursIn(plan: LocalDateRangePlan): string[] {
  const hours: string[] = [];
  if (plan.days) {
    for (
      let day = Date.parse(`${plan.days.from}T00:00:00Z`);
      day <= Date.parse(`${plan.days.to}T00:00:00Z`);
      day += DAY
    ) {
      for (let hour = day; hour < day + DAY; hour += HOUR) hours.push(utcHour(hour));
    }
  }
  for (const edge of plan.boundaries) {
    for (let hour = Date.parse(edge.from); hour < Date.parse(edge.to); hour += HOUR) {
      hours.push(utcHour(hour));
    }
  }
  return hours.sort();
}

function assertSameHours(left: string[], right: string[], label: string): void {
  if (left.length !== right.length || left.some((hour, index) => hour !== right[index])) {
    throw new Error(`${label}: hour-grid mismatch (${left.length} vs ${right.length})`);
  }
}

function interiorDayCount(window: DateWindow | null): number {
  if (!window) return 0;
  return (
    Math.round(
      (Date.parse(`${window.to}T00:00:00Z`) - Date.parse(`${window.from}T00:00:00Z`)) / DAY,
    ) + 1
  );
}

async function countDaily(
  database: SqliteDatabase,
  accountId: string,
  window: DateWindow | null,
): Promise<number> {
  if (!window) return 0;
  const count = await database
    .prepare(
      `SELECT COUNT(*) AS n
       FROM usage_daily AS daily
       INNER JOIN devices ON devices.id = daily.device_id
       WHERE devices.account_id = ?1 AND devices.deleted_at IS NULL
         AND daily.utc_date >= ?2 AND daily.utc_date <= ?3`,
    )
    .bind(accountId, window.from, window.to)
    .first<number>("n");
  return Number(count ?? 0);
}

async function countHourly(
  database: SqliteDatabase,
  accountId: string,
  range: HourRange,
): Promise<number> {
  const count = await database
    .prepare(
      `SELECT COUNT(*) AS n
       FROM usage_hourly AS hourly
       INNER JOIN devices ON devices.id = hourly.device_id
       WHERE devices.account_id = ?1 AND devices.deleted_at IS NULL
         AND hourly.bucket_start_utc >= ?2 AND hourly.bucket_start_utc < ?3`,
    )
    .bind(accountId, range.from, range.to)
    .first<number>("n");
  return Number(count ?? 0);
}

function seedFile(path: string): {
  hourly_rows: number;
  daily_rows: number;
  first_utc: string;
  last_utc: string;
} {
  const db = new Database(path);
  db.pragma("foreign_keys = ON");
  db.pragma("synchronous = OFF");
  const now = CHECKED_AT.toISOString();
  db.prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)").run(
    ACCOUNT_ID,
    now,
    now,
  );
  db.prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)").run(
    DISTRACTOR_ID,
    now,
    now,
  );
  const insertDevice = db.prepare(
    `INSERT INTO devices (id, account_id, installation_id_hash, generation, created_at, last_login_at)
     VALUES (?, ?, ?, 1, ?, ?)`,
  );
  for (let index = 0; index < DEVICE_COUNT; index += 1) {
    insertDevice.run(`device_${index}`, ACCOUNT_ID, `installation_${index}`, now, now);
  }
  insertDevice.run("device_other", DISTRACTOR_ID, "installation_other", now, now);

  const insertHour = db.prepare(
    `INSERT INTO usage_hourly (
       device_id, agent, bucket_start_utc, scan_version, partial,
       billing_channel, channel_source, model, context_bucket, service_tier, speed, inference_geo,
       input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
       cache_write_inferred_tokens, output_tokens, reasoning_tokens, requests,
       web_search_requests, web_fetch_requests, source_cost_microusd, source_cost_covered_requests
     ) VALUES (
       ?, ?, ?, 1, 0,
       'openai_direct', 'agent_default', ?, 'le_128k', 'unknown', 'unknown', 'unknown',
       ?, 0, 0, 0, 0, ?, 0, 1, 0, 0, NULL, 0
     )`,
  );

  const lastInstant = Date.parse(`${END_UTC_DATE}T00:00:00Z`) + DAY;
  const firstInstant = lastInstant - SEED_DAYS * DAY;
  const seed = db.transaction(() => {
    let hourly = 0;
    for (let day = firstInstant; day < lastInstant; day += DAY) {
      for (let hour = 0; hour < 24; hour += HOUR_STEP) {
        const bucket = utcHour(day + hour * HOUR);
        for (let device = 0; device < DEVICE_COUNT; device += 1) {
          for (const agent of AGENTS) {
            for (const [modelIndex, model] of MODELS.entries()) {
              const tokens = 10 + ((day / DAY + hour + device + modelIndex) % 17);
              insertHour.run(`device_${device}`, agent, bucket, model, tokens, 2);
              hourly += 1;
            }
          }
        }
      }
    }
    const distractorFrom = lastInstant - 30 * DAY;
    for (let day = distractorFrom; day < lastInstant; day += DAY) {
      insertHour.run("device_other", "codex", utcHour(day), "gpt-5.6-sol", 99, 2);
    }
    return hourly;
  });
  const hourlyRows = seed();
  db.exec(
    `INSERT INTO usage_daily (
       device_id, utc_date, agent, billing_channel, channel_source, model,
       context_bucket, service_tier, speed, inference_geo,
       input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
       cache_write_inferred_tokens, output_tokens, reasoning_tokens, requests,
       web_search_requests, web_fetch_requests, source_cost_microusd, source_cost_covered_requests,
       partial_hours
     )
     SELECT
       device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel, channel_source, model,
       context_bucket, service_tier, speed, inference_geo,
       SUM(input_tokens), SUM(cache_read_tokens), SUM(cache_write_5m_tokens),
       SUM(cache_write_1h_tokens), SUM(cache_write_inferred_tokens), SUM(output_tokens),
       SUM(reasoning_tokens), SUM(requests), SUM(web_search_requests), SUM(web_fetch_requests),
       NULL, SUM(source_cost_covered_requests), SUM(partial)
     FROM usage_hourly
     GROUP BY
       device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel, channel_source, model,
       context_bucket, service_tier, speed, inference_geo`,
  );
  db.exec("ANALYZE");
  const dailyRows = Number(
    (db.prepare("SELECT COUNT(*) AS n FROM usage_daily").get() as { n: number }).n,
  );
  db.pragma("synchronous = NORMAL");
  db.close();
  return {
    hourly_rows: hourlyRows,
    daily_rows: dailyRows,
    first_utc: utcDate(firstInstant),
    last_utc: END_UTC_DATE,
  };
}

async function queryTotals(
  usage: D1UsageState,
  plan: LocalDateRangePlan,
): Promise<{
  tokens: number;
  dailyReturned: number;
  boundaryReturned: number;
  truncated: boolean;
}> {
  const daily = plan.days
    ? await usage.queryDailyUsage(ACCOUNT_ID, {
        from: plan.days.from,
        to: plan.days.to,
        limit: QUERY_LIMIT,
      })
    : { rows: [], truncated: false };
  const boundary =
    plan.boundaries.length === 0
      ? { ranges: [], truncated: false }
      : await usage.queryBoundaryHours(ACCOUNT_ID, {
          ranges: plan.boundaries,
          limit: QUERY_LIMIT,
        });
  let tokens = 0;
  for (const row of daily.rows) tokens += row.input_tokens + row.output_tokens;
  for (const rows of boundary.ranges) {
    for (const row of rows) tokens += row.input_tokens + row.output_tokens;
  }
  return {
    tokens,
    dailyReturned: daily.rows.length,
    boundaryReturned: boundary.ranges.reduce((sum, rows) => sum + rows.length, 0),
    truncated: daily.truncated || boundary.truncated,
  };
}

async function queryLocalDays(
  usage: D1UsageState,
  timezone: string,
  localFrom: string,
  localTo: string,
): Promise<{ returned: number; tokens: number }> {
  const windows = planLocalDayWindows(timezone, localFrom, localTo);
  const localDays = await usage.queryLocalDayUsage(ACCOUNT_ID, {
    windows,
    limit: QUERY_LIMIT,
  });
  if (localDays.truncated) throw new Error("local-day query truncated");
  let tokens = 0;
  for (const row of localDays.rows) tokens += row.input_tokens + row.output_tokens;
  return { returned: localDays.rows.length, tokens };
}

async function measureRange(input: {
  host: string;
  path: string;
  zoneName: string;
  timezone: string;
  kind: string;
  localFrom: string;
  localTo: string;
  peak: { value: number };
}): Promise<QueryMeasurement> {
  const planStarted = process.hrtime.bigint();
  const plan = planLocalDateRange(input.timezone, input.localFrom, input.localTo);
  const planMs = elapsedMs(planStarted);

  const open = () => {
    const database = new SqliteDatabase(input.path);
    return { database, usage: new D1UsageState(database) };
  };

  const handle = open();
  let localPeak = rssMb();
  input.peak.value = Math.max(input.peak.value, localPeak);

  const coldTotalsStarted = process.hrtime.bigint();
  const coldTotals = await queryTotals(handle.usage, plan);
  const coldTotalsMs = elapsedMs(coldTotalsStarted);
  localPeak = Math.max(localPeak, rssMb());

  let coldHourlyMs: number | null = null;
  let warmHourlyMs: number | null = null;
  let hourlyReturned = 0;
  let hourlyError: string | null = null;
  try {
    const coldHourlyStarted = process.hrtime.bigint();
    const coldHourly = await queryLocalDays(
      handle.usage,
      input.timezone,
      input.localFrom,
      input.localTo,
    );
    coldHourlyMs = elapsedMs(coldHourlyStarted);
    localPeak = Math.max(localPeak, rssMb());
    hourlyReturned = coldHourly.returned;
    if (coldHourly.tokens !== coldTotals.tokens) {
      throw new Error(
        `${input.kind} ${input.timezone}: totals ${coldTotals.tokens} != local-day ${coldHourly.tokens}`,
      );
    }
    const warmHourlyStarted = process.hrtime.bigint();
    await queryLocalDays(handle.usage, input.timezone, input.localFrom, input.localTo);
    warmHourlyMs = elapsedMs(warmHourlyStarted);
    localPeak = Math.max(localPeak, rssMb());
  } catch (error) {
    hourlyError = error instanceof Error ? error.message : String(error);
  }

  const warmTotalsStarted = process.hrtime.bigint();
  const warmTotals = await queryTotals(handle.usage, plan);
  const warmTotalsMs = elapsedMs(warmTotalsStarted);
  const rssAfter = rssMb();
  localPeak = Math.max(localPeak, rssAfter);
  input.peak.value = Math.max(input.peak.value, localPeak);

  const dailyScanned = await countDaily(handle.database, ACCOUNT_ID, plan.days);
  let hourlyScanned = 0;
  for (const edge of plan.boundaries) {
    hourlyScanned += await countHourly(handle.database, ACCOUNT_ID, edge);
  }
  const fullScanned = await countHourly(handle.database, ACCOUNT_ID, {
    from: plan.start,
    to: plan.end,
  });
  handle.database.close();

  if (warmTotals.tokens !== coldTotals.tokens) {
    throw new Error(`${input.kind} ${input.timezone}: cold/warm token mismatch`);
  }
  return {
    host: input.host,
    zone: input.zoneName,
    timezone: input.timezone,
    kind: input.kind,
    local_from: input.localFrom,
    local_to: input.localTo,
    start: plan.start,
    end: plan.end,
    interior_utc_days: interiorDayCount(plan.days),
    boundary_ranges: plan.boundaries.length,
    daily_rows_scanned: dailyScanned,
    hourly_rows_scanned: hourlyScanned,
    daily_rows_returned: coldTotals.dailyReturned,
    boundary_rows_returned: coldTotals.boundaryReturned,
    hourly_full_rows_scanned: fullScanned,
    hourly_full_rows_returned: hourlyReturned,
    tokens: coldTotals.tokens,
    truncated: coldTotals.truncated,
    cold_plan_ms: planMs,
    cold_totals_ms: coldTotalsMs,
    cold_hourly_ms: coldHourlyMs,
    warm_totals_ms: warmTotalsMs,
    warm_hourly_ms: warmHourlyMs,
    rss_after_mb: rssAfter,
    peak_rss_mb: localPeak,
    hourly_error: hourlyError,
  };
}

function printTable(
  rows: QueryMeasurement[],
  columns: { key: keyof QueryMeasurement; label: string }[],
): void {
  const body = rows.map((row) =>
    columns.map((column) => {
      const value = row[column.key];
      return typeof value === "number" && !Number.isInteger(value)
        ? value.toFixed(1)
        : String(value);
    }),
  );
  const widths = columns.map((column, index) =>
    Math.max(column.label.length, ...body.map((line) => (line[index] ?? "").length)),
  );
  const format = (cells: string[]) =>
    `| ${cells.map((cell, index) => cell.padStart(widths[index] ?? 0)).join(" | ")} |`;
  console.log(format(columns.map((column) => column.label)));
  console.log(`| ${widths.map((width) => "-".repeat(width)).join(" | ")} |`);
  for (const line of body) console.log(format(line));
}

function rangeKinds(timezone: string): { kind: string; from: string; to: string }[] {
  const localToday = localDateAt(zoneClock(timezone), CHECKED_AT.getTime());
  return [
    { kind: "1-day", from: localToday, to: localToday },
    { kind: "7-day", from: shiftDate(localToday, -6), to: localToday },
    { kind: "30-day", from: shiftDate(localToday, -29), to: localToday },
    { kind: "365-day", from: shiftDate(localToday, -(QUERY_DAYS - 1)), to: localToday },
    { kind: "custom-14d", from: shiftDate(localToday, -40), to: shiftDate(localToday, -27) },
  ];
}

function verifyPresetIdentity(timezone: string): void {
  const preset = planLocalPeriods(timezone, CHECKED_AT);
  const today = planLocalDateRange(timezone, preset.localDate, preset.localDate);
  const seven = planLocalDateRange(timezone, shiftDate(preset.localDate, -6), preset.localDate);
  const thirty = planLocalDateRange(timezone, shiftDate(preset.localDate, -29), preset.localDate);
  const presetHours = (key: "today" | "last_7_days" | "last_30_days") => {
    const window = preset.days[key];
    const hours: string[] = [];
    if (window) {
      for (
        let day = Date.parse(`${window.from}T00:00:00Z`);
        day <= Date.parse(`${window.to}T00:00:00Z`);
        day += DAY
      ) {
        for (let hour = day; hour < day + DAY; hour += HOUR) hours.push(utcHour(hour));
      }
    }
    for (const edge of preset.boundaries) {
      if (!edge.periods.includes(key)) continue;
      for (let hour = Date.parse(edge.range.from); hour < Date.parse(edge.range.to); hour += HOUR) {
        hours.push(utcHour(hour));
      }
    }
    return hours.sort();
  };
  assertSameHours(hoursIn(today), presetHours("today"), `${timezone} today == custom`);
  assertSameHours(hoursIn(seven), presetHours("last_7_days"), `${timezone} 7d == custom`);
  assertSameHours(hoursIn(thirty), presetHours("last_30_days"), `${timezone} 30d == custom`);
}

async function main(): Promise<void> {
  const host = process.env.PERIOD_BENCH_HOST ?? "mac";
  const peak = { value: rssMb() };
  const directory = await mkdtemp(join(tmpdir(), "quota-period-bench-"));
  const path = join(directory, "relay.sqlite");
  const started = process.hrtime.bigint();

  const migrated = new SqliteDatabase(path);
  await applyMigrations(migrated, migrationsDirectory());
  migrated.close();
  const seed = seedFile(path);
  peak.value = Math.max(peak.value, rssMb());
  const seedMs = elapsedMs(started);

  for (const zone of ZONES) verifyPresetIdentity(zone.tz);

  const singaporeToday = planLocalDateRange("Asia/Singapore", "2026-01-16", "2026-01-16");
  const stJohnsToday = planLocalDateRange("America/St_Johns", "2026-01-15", "2026-01-15");
  if (singaporeToday.start !== "2026-01-15T16:00:00Z") {
    throw new Error(`UTC+8 today should start 16:00Z, got ${singaporeToday.start}`);
  }
  if (stJohnsToday.start !== "2026-01-15T04:00:00Z") {
    throw new Error(
      `UTC-3:30 hour-grid should assign 03:30Z midnight to the previous day (start 04:00Z), got ${stJohnsToday.start}`,
    );
  }

  const rows: QueryMeasurement[] = [];
  for (const zone of ZONES) {
    for (const range of rangeKinds(zone.tz)) {
      rows.push(
        await measureRange({
          host,
          path,
          zoneName: zone.name,
          timezone: zone.tz,
          kind: range.kind,
          localFrom: range.from,
          localTo: range.to,
          peak,
        }),
      );
    }
  }

  const hoursPerDay = 24 / HOUR_STEP;
  const measuredHourly = SEED_DAYS * hoursPerDay * DEVICE_COUNT * AGENTS.length * MODELS.length;
  console.log(`host=${host} node=${process.version} pid=${process.pid}`);
  console.log(
    `cardinalities: accounts=2 (1 measured + 1 distractor) devices=${DEVICE_COUNT} agents=${AGENTS.length} models=${MODELS.length} seed_days=${SEED_DAYS} query_days=${QUERY_DAYS} hours_per_day=${hoursPerDay} measured_hourly_rows=${measuredHourly} seeded_hourly_rows=${seed.hourly_rows} daily_rows=${seed.daily_rows} utc=${seed.first_utc}..${seed.last_utc} checked_at=${CHECKED_AT.toISOString()} seed_ms=${seedMs.toFixed(0)} process_peak_rss_mb=${peak.value.toFixed(1)}`,
  );
  console.log(
    "totals = usage_daily interior UTC days + usage_hourly boundary ranges (period totals). hourly = SQL GROUP BY local-day window (days[]).",
  );

  printTable(rows, [
    { key: "zone", label: "zone" },
    { key: "kind", label: "range" },
    { key: "interior_utc_days", label: "interior d" },
    { key: "daily_rows_scanned", label: "daily scan" },
    { key: "hourly_rows_scanned", label: "edge hr scan" },
    { key: "daily_rows_returned", label: "daily ret" },
    { key: "boundary_rows_returned", label: "edge ret" },
    { key: "cold_totals_ms", label: "cold tot ms" },
    { key: "warm_totals_ms", label: "warm tot ms" },
    { key: "hourly_full_rows_scanned", label: "span hr rows" },
    { key: "hourly_full_rows_returned", label: "local-day ret" },
    { key: "cold_hourly_ms", label: "cold day ms" },
    { key: "warm_hourly_ms", label: "warm day ms" },
    { key: "peak_rss_mb", label: "peak RSS" },
  ]);
  console.log("BEGIN_JSON");
  console.log(JSON.stringify({ host, seed, peak_rss_mb: peak.value, rows }, null, 2));
  console.log("END_JSON");

  await rm(directory, { recursive: true, force: true });
}

await main();
