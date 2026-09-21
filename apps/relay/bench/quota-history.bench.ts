/**
 * Synthetic quota-history upload and merged-read benchmark.
 *
 * Not part of `pnpm test`. Node's type-strip cannot load `sqlite-database.ts`
 * (parameter properties), so bundle first. From the repository root:
 *
 *   pnpm --filter @gotry-io/quota-relay exec esbuild bench/quota-history.bench.ts \
 *     --bundle --platform=node --format=esm --target=node24 --external:better-sqlite3 \
 *     --outfile=bench/quota-history.generated.mjs
 *
 * Two-phase: seed unconstrained, measure in a fresh process. The 192 MiB shape is the
 * measure half only:
 *
 *   PERIOD_BENCH_MIGRATIONS="$PWD/apps/relay/migrations" \
 *     QUOTA_HISTORY_BENCH_PHASE=seed QUOTA_HISTORY_BENCH_DB=/tmp/quota-history.sqlite \
 *     pnpm --filter @gotry-io/quota-relay exec node bench/quota-history.generated.mjs
 *   docker run --rm --cpus=1 --memory=192m --memory-swap=192m \
 *     --network none \
 *     -e NODE_OPTIONS=--max-old-space-size=64 \
 *     -e PERIOD_BENCH_HOST=docker \
 *     -e QUOTA_HISTORY_BENCH_PHASE=measure \
 *     -e QUOTA_HISTORY_BENCH_DB=/data/quota-history.sqlite \
 *     -v /tmp/quota-history.sqlite:/data/quota-history.sqlite \
 *     -v "$PWD/apps/relay/bench/quota-history.generated.mjs":/bench.mjs \
 *     -v "$PWD/node_modules/better-sqlite3":/node_modules/better-sqlite3 \
 *     node:24-bookworm-slim node /bench.mjs
 *
 * Pre-span 259 200-row measure (reviewer, `node:24-bookworm-slim`, `--cpus=1
 * --memory=192m --memory-swap=192m`, `NODE_OPTIONS=--max-old-space-size=64`):
 * read p50 15.07 ms / p95 33.64 ms (8 640 points), upload p50 26.03 / p95 34.26 ms,
 * peak RSS 99.8 MiB.
 */
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { applyMigrations } from "../src/platform/migrations.ts";
import { SqliteDatabase } from "../src/platform/sqlite-database.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import type { DeviceWriterPrincipal } from "@gotry-io/relay-core";
import { quotaHistoryExpiresAt, quotaHistorySpanSeconds } from "@gotry-io/quota-model";
import { MANAGED_DATA_PROTOCOL_VERSION, quotaHistoryBucketSeconds } from "@gotry-io/quota-protocol";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const ACCOUNT_ID = "account_bench";
const CHECKED_AT = new Date("2026-09-21T10:00:00Z");
const SUBSCRIPTIONS = 10;
const DEVICES = 3;
const WINDOWS = [
  { id: "five_hour", duration: 18_000 },
  { id: "weekly", duration: 604_800 },
  { id: "monthly", duration: 2_592_000 },
] as const;
const READ_ITERS = 21;
const UPLOAD_ITERS = 11;
const PROVIDERS = ["codex", "claude", "cursor", "grok", "gemini"] as const;

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

function rssMb(): number {
  return process.memoryUsage().rss / (1024 * 1024);
}

function elapsedMs(started: bigint): number {
  return Number(process.hrtime.bigint() - started) / 1e6;
}

function percentile(values: number[], fraction: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * fraction) - 1));
  return sorted[index] ?? 0;
}

function canonical(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function fingerprintFor(index: number): string {
  return `fp${index.toString().padStart(4, "0")}`;
}

function principal(deviceIndex: number): DeviceWriterPrincipal {
  return {
    session_id: `session_${deviceIndex}`,
    family_id: `family_${deviceIndex}`,
    account_id: ACCOUNT_ID,
    device_id: `device_${deviceIndex}`,
    device_generation: 1,
    client_kind: "quotabar",
    scopes: ["account:read", "device:write", "account:settings"],
    authenticated_at: CHECKED_AT.toISOString(),
  };
}

async function seed(database: SqliteDatabase): Promise<void> {
  const stamp = CHECKED_AT.toISOString();
  await database
    .prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?1, ?2, ?2)")
    .bind(ACCOUNT_ID, stamp)
    .run();
  await database
    .prepare(
      `INSERT INTO account_settings (account_id, revision, settings_json, created_at, updated_at)
       VALUES (?1, 1, ?2, ?3, ?3)`,
    )
    .bind(
      ACCOUNT_ID,
      JSON.stringify({
        alerts: { reset_reminders: true, pace_alerts: true, thresholds: {} },
        budget: { amount_usd: null, alerts: true },
        history: { sync: true },
      }),
      stamp,
    )
    .run();
  for (let device = 0; device < DEVICES; device += 1) {
    await database
      .prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES (?1, ?2, ?3, 1, ?4, ?4)`,
      )
      .bind(`device_${device}`, ACCOUNT_ID, `installation_${device}`, stamp)
      .run();
  }
  const insert = database.prepare(
    `INSERT INTO quota_history (
       device_id, account_id, provider, fingerprint, window_id, resets_at, bucket_start,
       used_percent, duration_seconds, updated_at, expires_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
  );
  const chunk = 2_000;
  let pending = [];
  for (let device = 0; device < DEVICES; device += 1) {
    for (let sub = 0; sub < SUBSCRIPTIONS; sub += 1) {
      const provider = PROVIDERS[sub % PROVIDERS.length] ?? "codex";
      const fingerprint = fingerprintFor(sub);
      for (const window of WINDOWS) {
        const span = quotaHistorySpanSeconds(window.duration);
        const step = quotaHistoryBucketSeconds(window.duration) * 1_000;
        const start = CHECKED_AT.getTime() - span * 1_000;
        const resetsAt = canonical(CHECKED_AT.getTime() + window.duration * 1_000);
        for (let instant = start, bucket = 0; instant < CHECKED_AT.getTime(); instant += step) {
          pending.push(
            insert.bind(
              `device_${device}`,
              ACCOUNT_ID,
              provider,
              fingerprint,
              window.id,
              resetsAt,
              canonical(instant),
              (bucket % 100) + device,
              window.duration,
              stamp,
              quotaHistoryExpiresAt(canonical(instant), window.duration),
            ),
          );
          bucket += 1;
          if (pending.length >= chunk) {
            await database.batch(pending);
            pending = [];
          }
        }
      }
    }
  }
  if (pending.length > 0) await database.batch(pending);
}

async function main(): Promise<void> {
  const host = process.env.PERIOD_BENCH_HOST ?? "local";
  // Seeding a quarter of a million rows builds large arrays in this process; measured in the same
  // process, that is what the peak RSS reports, not what a read costs. QUOTA_HISTORY_BENCH_DB names
  // a database file that outlives the run, and QUOTA_HISTORY_BENCH_PHASE picks one half: `seed`
  // writes it (run unconstrained), `measure` opens it in a fresh process under the 192 MiB / 64 MiB
  // heap shape. With neither set, both halves run here as before.
  const phase = process.env.QUOTA_HISTORY_BENCH_PHASE ?? "both";
  const kept = process.env.QUOTA_HISTORY_BENCH_DB;
  const dir = kept ? "" : await mkdtemp(join(tmpdir(), "quota-history-bench-"));
  const path = kept ?? join(dir, "relay.sqlite");
  const database = new SqliteDatabase(path);
  if (phase !== "measure") await applyMigrations(database, migrationsDirectory());
  const peak = { value: rssMb() };
  if (phase !== "measure") {
    console.log(
      `host=${host} seeding ${SUBSCRIPTIONS}×${DEVICES}×${WINDOWS.length} windows by span…`,
    );
  }
  const seedStarted = process.hrtime.bigint();
  if (phase !== "measure") await seed(database);
  const seedMs = elapsedMs(seedStarted);
  if (phase === "seed") {
    console.log(`seeded into ${path}; run the measure phase against it`);
    return;
  }
  peak.value = Math.max(peak.value, rssMb());
  const rows = await database.prepare("SELECT COUNT(*) AS n FROM quota_history").first<number>("n");
  console.log(`seeded ${rows} rows in ${seedMs.toFixed(0)} ms rss=${rssMb().toFixed(1)} MiB`);

  const state = new D1AccountState(database);
  const readMs: number[] = [];
  for (let iter = 0; iter < READ_ITERS; iter += 1) {
    const started = process.hrtime.bigint();
    const merged = await state.readQuotaHistory(
      ACCOUNT_ID,
      "codex",
      fingerprintFor(0),
      canonical(CHECKED_AT.getTime() - 30 * DAY),
      canonical(CHECKED_AT.getTime()),
    );
    readMs.push(elapsedMs(started));
    peak.value = Math.max(peak.value, rssMb());
    if (iter === 0) console.log(`read points=${merged.length}`);
  }

  const uploadMs: number[] = [];
  const writer = principal(0);
  const uploadSpan = quotaHistorySpanSeconds(18_000);
  const uploadStep = quotaHistoryBucketSeconds(18_000) * 1_000;
  const points = Array.from({ length: uploadSpan / (uploadStep / 1_000) }, (_, index) => ({
    resets_at: "2026-09-21T15:00:00Z",
    bucket_start: canonical(CHECKED_AT.getTime() - index * uploadStep),
    used_percent: index % 101,
  }));
  for (let iter = 0; iter < UPLOAD_ITERS; iter += 1) {
    const started = process.hrtime.bigint();
    const written = await state.recordQuotaHistory(
      writer,
      {
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
        generation: 1,
        series: [
          {
            provider: "codex",
            fingerprint: fingerprintFor(0),
            window_id: "five_hour",
            duration_seconds: 18_000,
            points,
          },
        ],
      },
      CHECKED_AT.toISOString(),
      50_000,
    );
    uploadMs.push(elapsedMs(started));
    peak.value = Math.max(peak.value, rssMb());
    if (written.outcome !== "written") {
      throw new Error(`upload ${written.outcome}`);
    }
  }

  const warmRead = readMs.slice(1);
  const warmUpload = uploadMs.slice(1);
  console.log(
    [
      `read_p50_ms=${percentile(warmRead, 0.5).toFixed(2)}`,
      `read_p95_ms=${percentile(warmRead, 0.95).toFixed(2)}`,
      `upload_p50_ms=${percentile(warmUpload, 0.5).toFixed(2)}`,
      `upload_p95_ms=${percentile(warmUpload, 0.95).toFixed(2)}`,
      `peak_rss_mb=${peak.value.toFixed(1)}`,
      `rss_after_mb=${rssMb().toFixed(1)}`,
    ].join(" "),
  );
  database.close();
  if (dir) await rm(dir, { recursive: true, force: true });
}

await main();
