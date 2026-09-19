import { type ChildProcess, execFile as execFileCallback, spawn } from "node:child_process";
import { access, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import {
  type AccountSummary,
  AccountSummarySchema,
  OAuthTokenResponseSchema,
} from "@gotry-io/quota-protocol";
import { afterEach, describe, expect, it } from "vitest";
import { signInReturnTo } from "./native-sign-in.ts";

const execFile = promisify(execFileCallback);

const repoRoot = fileURLToPath(new URL("../../..", import.meta.url));
const relayRoot = join(repoRoot, "apps/relay");
const restoreScript = join(repoRoot, "scripts/relay-sqlite-restore.sh");
const backupScript = join(repoRoot, "scripts/relay-sqlite-backup.sh");
const nodeBundle = join(relayRoot, "dist/node/server.mjs");
const githubMock = pathToFileURL(join(relayRoot, "test/restore-drill-github-mock.mjs")).href;
const sveltekitServer = join(
  repoRoot,
  "apps/web/.svelte-kit/output/server/quota-sveltekit-server.js",
);
const staticDir = join(repoRoot, "apps/web/.svelte-kit/output/client");
const testSecret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const distinctiveInputTokens = 4242;

const tempDirs: string[] = [];
const processes: NodeRelay[] = [];

afterEach(async () => {
  for (const process of processes.splice(0)) {
    await process.stop();
  }
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("restore-drill", () => {
  it("refuses a snapshot that fails integrity_check", async () => {
    const dir = await scratchDir();
    const snapshot = join(dir, "tampered.sqlite");
    const target = join(dir, "target.sqlite");
    await writeFile(snapshot, "this is not a sqlite database\n");
    const result = await run(restoreScript, [snapshot, target]);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/integrity_check/);
    await expect(access(target)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses a snapshot that names a migration the checkout does not have", async () => {
    const dir = await scratchDir();
    const snapshot = join(dir, "future.sqlite");
    const target = join(dir, "target.sqlite");
    await writeLedgerSnapshot(snapshot, "0001_initial.sql", "9999_from_the_future.sql");
    const result = await run(restoreScript, [snapshot, target]);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("snapshot names unknown migration: 9999_from_the_future.sql");
  });

  it("refuses to overwrite a non-empty target unless --force", async () => {
    const dir = await scratchDir();
    const snapshot = join(dir, "ok.sqlite");
    const target = join(dir, "target.sqlite");
    await writeLedgerSnapshot(snapshot, "0001_initial.sql");
    await writeFile(target, "already here");
    const refused = await run(restoreScript, [snapshot, target]);
    expect(refused.status).not.toBe(0);
    expect(refused.stderr).toMatch(/non-empty target/);
    expect(await readFile(target, "utf8")).toBe("already here");

    const forced = await run(restoreScript, ["--force", snapshot, target]);
    expect(forced.status).toBe(0);
    expect(forced.stdout).toMatch(/restored /);
    expect(forced.stdout).toMatch(/overwrite: --force/);
    const names = await sqliteQuery(target, "SELECT name FROM d1_migrations;");
    expect(names).toBe("0001_initial.sql");
  });

  it("restores a snapshot with fewer migrations than the checkout", async () => {
    const dir = await scratchDir();
    const snapshot = join(dir, "old.sqlite");
    const target = join(dir, "target.sqlite");
    await writeLedgerSnapshot(snapshot, "0001_initial.sql");
    const result = await run(restoreScript, [snapshot, target]);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/d1_migrations: 1 in snapshot/);
    expect(result.stdout).toMatch(/start applies any remainder/);
    expect(await sqliteQuery(target, "PRAGMA integrity_check;")).toBe("ok");
  });

  it("boots a second Node Relay from a .backup and serves the same Account summary", {
    timeout: 120_000,
  }, async () => {
    await buildNodeBundle();
    const dir = await scratchDir();
    const liveSqlite = join(dir, "live.sqlite");
    const restoredSqlite = join(dir, "restored.sqlite");
    const backupDir = join(dir, "backups");
    const first = await startNodeRelay(liveSqlite);
    const { accessToken, summary: before } = await seedAccountOverHttp(first.baseUrl);
    expect(before.account.display_label).toBe("restore-drill");
    expect(before.usage.all.totals.input_tokens).toBe(distinctiveInputTokens);

    const backup = await run(backupScript, [liveSqlite, backupDir]);
    expect(backup.status, backup.stderr).toBe(0);
    expect(backup.stdout).toMatch(/wrote /);
    const names = (await readdir(backupDir)).filter((name) => /^relay-\d{8}\.sqlite$/.test(name));
    expect(names, backup.stdout).toHaveLength(1);
    const snapshot = join(backupDir, names[0] ?? "");
    await access(snapshot);

    const restored = await run(restoreScript, [snapshot, restoredSqlite]);
    expect(restored.status, `${restored.stdout}\n${restored.stderr}`).toBe(0);
    expect(restored.stdout).toContain(`restored ${snapshot} to ${restoredSqlite}`);

    const second = await startNodeRelay(restoredSqlite);
    const after = await readSummary(second.baseUrl, accessToken);
    expect(after).toEqual(before);

    const tampered = join(dir, "tampered.sqlite");
    await corruptSqlite(snapshot, tampered);
    const refused = await run(restoreScript, [tampered, join(dir, "should-not-exist.sqlite")]);
    expect(refused.status).not.toBe(0);
    expect(refused.stderr).toMatch(/integrity_check/);
  });
});

async function scratchDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "quota-restore-drill-"));
  tempDirs.push(dir);
  return dir;
}

async function writeLedgerSnapshot(path: string, ...names: string[]): Promise<void> {
  const inserts = names
    .map((name) => `INSERT INTO d1_migrations (name) VALUES ('${name}');`)
    .join("\n");
  await execFile("sqlite3", [
    path,
    `CREATE TABLE d1_migrations(
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       name TEXT UNIQUE,
       applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
     );
     ${inserts}`,
  ]);
}

async function sqliteQuery(path: string, sql: string): Promise<string> {
  const { stdout } = await execFile("sqlite3", ["-readonly", path, sql], { encoding: "utf8" });
  return stdout.trim();
}

async function corruptSqlite(source: string, dest: string): Promise<void> {
  const bytes = Uint8Array.from(await readFile(source));
  bytes[0] ^= 0xff;
  await writeFile(dest, bytes);
}

async function run(
  command: string,
  args: string[],
): Promise<{ status: number; stdout: string; stderr: string }> {
  try {
    const { stdout, stderr } = await execFile(command, args, { encoding: "utf8" });
    return { status: 0, stdout, stderr };
  } catch (error) {
    const failure = error as {
      code?: number | string;
      stdout?: string;
      stderr?: string;
      message: string;
    };
    const status = typeof failure.code === "number" ? failure.code : 1;
    return { status, stdout: failure.stdout ?? "", stderr: failure.stderr ?? failure.message };
  }
}

async function buildNodeBundle(): Promise<void> {
  try {
    await access(sveltekitServer);
  } catch {
    throw new Error(
      "restore-drill needs a website build at apps/web/.svelte-kit/output/server/quota-sveltekit-server.js (pnpm --filter @gotry-io/quota-web build)",
    );
  }
  await execFile("pnpm", ["run", "build:node"], {
    cwd: relayRoot,
    encoding: "utf8",
    timeout: 60_000,
  });
}

class NodeRelay {
  constructor(
    private readonly child: ChildProcess,
    readonly baseUrl: string,
    private readonly logs: string[],
  ) {}

  async stop(): Promise<void> {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.child.kill("SIGKILL");
      }, 3_000);
      this.child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
      this.child.kill("SIGTERM");
    });
  }

  dump(): string {
    return this.logs.join("");
  }
}

async function startNodeRelay(sqlitePath: string): Promise<NodeRelay> {
  const port = await freePort();
  const logs: string[] = [];
  const env = { ...process.env };
  delete env.NODE_OPTIONS;
  const child = spawn(process.execPath, ["--import", githubMock, nodeBundle], {
    cwd: repoRoot,
    env: {
      ...env,
      PORT: String(port),
      RELAY_SQLITE_PATH: sqlitePath,
      RELAY_STATIC_DIR: staticDir,
      GITHUB_CLIENT_ID: "test-github-client-id",
      GITHUB_CLIENT_SECRET: testSecret,
      APPLE_SIGNIN_TEAM_ID: "test-team",
      APPLE_SIGNIN_SERVICES_ID: "test-services",
      APPLE_SIGNIN_KEY_ID: "test-key-id",
      APPLE_SIGNIN_PRIVATE_KEY: "test-private-key",
      IDENTITY_SUBJECT_KEY: testSecret,
      QUOTA_INSTALLATION_KEY: testSecret,
      QUOTA_SESSION_HASH_KEY: testSecret,
      RESEND_API_KEY: testSecret,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout?.on("data", (chunk: Buffer) => {
    logs.push(chunk.toString());
  });
  child.stderr?.on("data", (chunk: Buffer) => {
    logs.push(chunk.toString());
  });
  const relay = new NodeRelay(child, `http://127.0.0.1:${port}`, logs);
  processes.push(relay);
  const exited = new Promise<never>((_, reject) => {
    child.once("exit", (code, signal) => {
      reject(
        new Error(
          `QuotaRelay exited before ready (code=${code} signal=${signal}): ${logs.join("")}`,
        ),
      );
    });
  });
  try {
    await Promise.race([waitForHealth(relay.baseUrl), exited]);
  } catch (error) {
    await relay.stop();
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`${detail}\n${relay.dump()}`);
  }
  child.removeAllListeners("exit");
  return relay;
}

async function waitForHealth(baseUrl: string): Promise<void> {
  const deadline = Date.now() + 20_000;
  let last: unknown;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/healthz`);
      if (response.ok) return;
      last = await response.text();
    } catch (error) {
      last = error;
    }
    await sleep(100);
  }
  throw new Error(`QuotaRelay did not become ready at ${baseUrl}: ${String(last)}`);
}

async function seedAccountOverHttp(
  baseUrl: string,
): Promise<{ accessToken: string; summary: AccountSummary }> {
  const started = await fetch(`${baseUrl}/api/auth/github/start`, { redirect: "manual" });
  expect(started.status).toBe(302);
  const authorize = new URL(started.headers.get("location") ?? "");
  const state = authorize.searchParams.get("state") ?? "";
  const handoff = cookie(started, "__Host-quota_oauth");
  expect(handoff).toBeTruthy();

  const callback = await fetch(
    `${baseUrl}/api/auth/github/callback?code=restore-drill&state=${encodeURIComponent(state)}`,
    { redirect: "manual", headers: { Cookie: `__Host-quota_oauth=${handoff}` } },
  );
  expect(callback.status).toBe(302);
  const session = cookie(callback, "__Host-quota_session");
  expect(session).toBeTruthy();

  const tokens = await loginQuotabar(baseUrl, session ?? "");
  const hour = currentUtcHour();
  const uploaded = await fetch(`${baseUrl}/api/v6/device/usage`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${tokens.session.access_token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      protocol_version: 6,
      generation: tokens.device_generation,
      agent: "codex",
      hours: [
        {
          bucket_start_utc: hour,
          scan_version: 1,
          partial: false,
          rows: [
            {
              agent: "codex",
              billing_channel: "openai_direct",
              channel_source: "agent_default",
              model: "gpt-5.6-sol",
              context_bucket: "le_128k",
              service_tier: "unknown",
              speed: "unknown",
              inference_geo: "unknown",
              input_tokens: distinctiveInputTokens,
              cache_read_tokens: 0,
              cache_write_5m_tokens: 0,
              cache_write_1h_tokens: 0,
              cache_write_inferred_tokens: 0,
              output_tokens: 7,
              reasoning_tokens: 0,
              requests: 1,
              web_search_requests: 0,
              web_fetch_requests: 0,
              source_cost_covered_requests: 0,
            },
          ],
        },
      ],
    }),
  });
  expect(uploaded.status).toBe(200);
  expect(await uploaded.json()).toMatchObject({ accepted: [hour], ignored: [] });

  const summary = await readSummary(baseUrl, tokens.session.access_token);
  return { accessToken: tokens.session.access_token, summary };
}

async function loginQuotabar(baseUrl: string, sessionCookie: string) {
  const { verifier, challenge } = await pkcePair();
  const authorizeUrl = new URL("/oauth/v2/authorize", baseUrl);
  authorizeUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: "quotabar",
    redirect_uri: "http://127.0.0.1:43210/callback",
    state: "client-state-123456789",
    code_challenge: challenge,
    code_challenge_method: "S256",
  }).toString();
  const started = await fetch(authorizeUrl, { redirect: "manual" });
  expect(started.status).toBe(302);
  const complete = await fetch(`${baseUrl}${signInReturnTo(started)}`, {
    redirect: "manual",
    headers: { Cookie: `__Host-quota_session=${sessionCookie}` },
  });
  expect(complete.status).toBe(302);
  const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
  const exchanged = await fetch(`${baseUrl}/oauth/v2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: "quotabar",
      code,
      code_verifier: verifier,
      redirect_uri: "http://127.0.0.1:43210/callback",
      installation_id: "4a7f950d-89ea-4f64-a7c1-b4aeb46a67f8",
      device_display_name: "Restore Drill Mac",
      platform: "macos",
    }),
  });
  expect(exchanged.status).toBe(200);
  return OAuthTokenResponseSchema.parse(await exchanged.json());
}

async function readSummary(baseUrl: string, accessToken: string): Promise<AccountSummary> {
  const response = await fetch(`${baseUrl}/api/v6/account/summary`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  expect(response.status).toBe(200);
  return AccountSummarySchema.parse(await response.json());
}

function cookie(response: Response, name: string): string | undefined {
  for (const raw of response.headers.getSetCookie()) {
    if (raw.startsWith(`${name}=`)) {
      return raw.slice(name.length + 1).split(";")[0];
    }
  }
  return undefined;
}

async function pkcePair() {
  const verifier = "a".repeat(43);
  const challengeBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(challengeBuffer)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
  return { verifier, challenge };
}

function currentUtcHour(): string {
  const ms = Math.floor(Date.now() / 3_600_000) * 3_600_000;
  return new Date(ms).toISOString().replace(".000Z", "Z");
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("could not bind a loopback port"));
        return;
      }
      const port = address.port;
      server.close((error) => {
        if (error) reject(error);
        else resolve(port);
      });
    });
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
