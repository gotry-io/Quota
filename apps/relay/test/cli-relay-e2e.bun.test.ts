import { describe, expect, it } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  ControllerSnapshotListResponseSchema,
  DeviceListResponseSchema,
} from "@gotry-io/quota-protocol";
import { createRelayApp } from "../src/app.ts";
import { selfHostedRelayInfo } from "../src/config.ts";
import { bootstrapSelfHostedController } from "../src/self-hosted-bootstrap.ts";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

const repositoryRoot = resolve(import.meta.dir, "../../..");
const cliMainPath = join(repositoryRoot, "apps", "cli", "src", "main.ts");
const commandTimeoutMilliseconds = 15_000;

interface CLIProcess {
  exited: Promise<number>;
  stdout: ReadableStream<Uint8Array>;
  stderr: ReadableStream<Uint8Array>;
  kill(signal?: number): void;
}

interface CLIResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

interface StoredRelayCredential {
  relay_url: string;
  instance_id: string;
  device_id: string;
  device_token: string;
  last_sequence: number;
}

describe("QuotaCLI relay against self-hosted QuotaRelay", () => {
  it("pairs with an initial empty heartbeat push and unpairs through real HTTP", async () => {
    const temporaryDirectory = await mkdtemp(join(tmpdir(), "quota-cli-relay-e2e-"));
    const databasePath = join(temporaryDirectory, "relay.db");
    const xdgConfigHome = join(temporaryDirectory, "config");
    const isolatedHome = join(temporaryDirectory, "home");
    const emptyBin = join(temporaryDirectory, "empty-bin");
    const providerRoots = {
      codex: join(temporaryDirectory, "codex"),
      claude: join(temporaryDirectory, "claude"),
      grok: join(temporaryDirectory, "grok"),
    };
    const platformPreload = join(temporaryDirectory, "non-darwin-preload.ts");
    const controllerToken = `synthetic-controller-token-${crypto.randomUUID()}`;
    const instanceID = `cli-e2e-${crypto.randomUUID()}`;
    const activeProcesses = new Set<CLIProcess>();
    let server: ReturnType<typeof Bun.serve> | undefined;

    try {
      await Promise.all([
        mkdir(xdgConfigHome, { recursive: true, mode: 0o700 }),
        mkdir(isolatedHome, { recursive: true, mode: 0o700 }),
        mkdir(emptyBin, { recursive: true, mode: 0o700 }),
        mkdir(providerRoots.codex, { recursive: true, mode: 0o700 }),
        mkdir(providerRoots.claude, { recursive: true, mode: 0o700 }),
        mkdir(providerRoots.grok, { recursive: true, mode: 0o700 }),
      ]);
      await writeFile(
        platformPreload,
        'Object.defineProperty(process, "platform", { value: "linux" });\n',
        { mode: 0o600 },
      );

      const state = new SQLiteRelayState(databasePath);
      await state.initialize();
      await bootstrapSelfHostedController(state, controllerToken, new Date());
      const app = createRelayApp({ state, relayInfo: selfHostedRelayInfo(instanceID) });
      server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch });
      const relayOrigin = `http://127.0.0.1:${server.port}`;
      const environment = isolatedCLIEnvironment({
        xdgConfigHome,
        isolatedHome,
        emptyBin,
        providerRoots,
      });

      let resolveUserCode: (value: string) => void = () => undefined;
      const userCodePromise = new Promise<string>((resolvePromise) => {
        resolveUserCode = resolvePromise;
      });
      const pairProcess = spawnCLI(
        ["relay", "pair", "--relay", relayOrigin],
        environment,
        platformPreload,
        activeProcesses,
      );
      const pairStdout = collectText(pairProcess.stdout, (line) => {
        if (line.startsWith("Pairing code: ")) {
          resolveUserCode(line.slice("Pairing code: ".length));
        }
      });
      const pairStderr = collectText(pairProcess.stderr);
      const userCode = await withTimeout(
        userCodePromise,
        5_000,
        "QuotaCLI did not emit a pairing code in time.",
      );

      const approval = await relayRequest(relayOrigin, "/api/v1/pairings/approve", {
        method: "POST",
        headers: bearerJSONHeaders(controllerToken),
        body: JSON.stringify({ user_code: userCode }),
      });
      expect(approval.status).toBe(204);

      const pairExitCode = await waitForExit(pairProcess, activeProcesses);
      const pairOutput = {
        exitCode: pairExitCode,
        stdout: await pairStdout,
        stderr: await pairStderr,
      };
      expect(pairOutput.exitCode).toBe(0);
      assertBearerMaterialAbsent(pairOutput, [controllerToken]);

      const credentialPath = join(xdgConfigHome, "quotacli", "device.json");
      const pairedCredential = await readCredential(credentialPath);
      assertBearerMaterialAbsent(pairOutput, [controllerToken, pairedCredential.device_token]);
      expect(pairOutput.stdout).toContain("Background relay push is supported only on macOS");
      expect(pairOutput.stdout).not.toContain("Uploaded");
      expect(pairedCredential.relay_url).toBe(relayOrigin);
      expect(pairedCredential.instance_id).toBe(instanceID);
      expect(pairedCredential.last_sequence).toBe(-1);

      const devicesAfterPair = await controllerDevices(relayOrigin, controllerToken);
      expect(devicesAfterPair.devices).toHaveLength(1);
      const pairedDevice = devicesAfterPair.devices[0];
      expect(pairedDevice?.device_id).toBe(pairedCredential.device_id);
      expect(pairedDevice?.last_sequence).toBe(-1);
      expect(pairedDevice?.last_seen_at).toBeNull();

      const pushOutput = await runCLI(
        ["relay", "push"],
        environment,
        platformPreload,
        activeProcesses,
      );
      expect(pushOutput.exitCode).toBe(1);
      assertBearerMaterialAbsent(pushOutput, [controllerToken, pairedCredential.device_token]);
      expect(pushOutput.stdout).toContain("Uploaded 0 snapshots with sequence 0.");
      expect(pushOutput.stderr).toContain("provider collection was incomplete");

      const reportedCredential = await readCredential(credentialPath);
      expect(reportedCredential.last_sequence).toBe(0);
      const devicesAfterPush = await controllerDevices(relayOrigin, controllerToken);
      expect(devicesAfterPush.devices).toHaveLength(1);
      const reportedDevice = devicesAfterPush.devices[0];
      expect(reportedDevice?.device_id).toBe(pairedCredential.device_id);
      expect(reportedDevice?.last_sequence).toBe(0);
      expect(typeof reportedDevice?.last_seen_at).toBe("string");

      const snapshotsResponse = await relayRequest(relayOrigin, "/api/v1/snapshots", {
        headers: bearerHeaders(controllerToken),
      });
      expect(snapshotsResponse.status).toBe(200);
      const snapshots = ControllerSnapshotListResponseSchema.parse(await snapshotsResponse.json());
      expect(snapshots.observations).toEqual([]);

      const unpairOutput = await runCLI(
        ["relay", "unpair"],
        environment,
        platformPreload,
        activeProcesses,
      );
      expect(unpairOutput.exitCode).toBe(0);
      assertBearerMaterialAbsent(unpairOutput, [controllerToken, pairedCredential.device_token]);
      expect(unpairOutput.stdout).toContain("local relay credential was removed");
      expect(await pathExists(credentialPath)).toBe(false);

      const devicesAfterUnpair = await controllerDevices(relayOrigin, controllerToken);
      expect(devicesAfterUnpair.devices).toHaveLength(1);
      expect(devicesAfterUnpair.devices[0]?.device_id).toBe(pairedCredential.device_id);
      expect(typeof devicesAfterUnpair.devices[0]?.revoked_at).toBe("string");
    } finally {
      for (const process of activeProcesses) {
        process.kill(9);
      }
      await Promise.allSettled([...activeProcesses].map((process) => process.exited));
      if (server) {
        await server.stop(true);
      }
      await rm(temporaryDirectory, { recursive: true, force: true });
    }
  }, 30_000);
});

function isolatedCLIEnvironment(options: {
  xdgConfigHome: string;
  isolatedHome: string;
  emptyBin: string;
  providerRoots: { codex: string; claude: string; grok: string };
}): Record<string, string> {
  return {
    HOME: options.isolatedHome,
    PATH: options.emptyBin,
    XDG_CONFIG_HOME: options.xdgConfigHome,
    CODEX_HOME: options.providerRoots.codex,
    CLAUDE_CONFIG_DIR: options.providerRoots.claude,
    GROK_HOME: options.providerRoots.grok,
    CODEX_CLI_PATH: join(options.emptyBin, "missing-codex"),
    CLAUDE_CLI_PATH: join(options.emptyBin, "missing-claude"),
    GROK_CLI_PATH: join(options.emptyBin, "missing-grok"),
    LANG: "C",
    LC_ALL: "C",
  };
}

function spawnCLI(
  args: readonly string[],
  environment: Record<string, string>,
  platformPreload: string,
  activeProcesses: Set<CLIProcess>,
): CLIProcess {
  const child = Bun.spawn([process.execPath, "--preload", platformPreload, cliMainPath, ...args], {
    cwd: repositoryRoot,
    env: environment,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  activeProcesses.add(child);
  return child;
}

async function runCLI(
  args: readonly string[],
  environment: Record<string, string>,
  platformPreload: string,
  activeProcesses: Set<CLIProcess>,
): Promise<CLIResult> {
  const process = spawnCLI(args, environment, platformPreload, activeProcesses);
  const stdout = collectText(process.stdout);
  const stderr = collectText(process.stderr);
  const exitCode = await waitForExit(process, activeProcesses);
  return { exitCode, stdout: await stdout, stderr: await stderr };
}

async function waitForExit(process: CLIProcess, activeProcesses: Set<CLIProcess>): Promise<number> {
  try {
    return await withTimeout(
      process.exited,
      commandTimeoutMilliseconds,
      "QuotaCLI did not exit in time.",
      () => process.kill(9),
    );
  } catch (error) {
    process.kill(9);
    await process.exited;
    throw error;
  } finally {
    activeProcesses.delete(process);
  }
}

async function collectText(
  stream: ReadableStream<Uint8Array>,
  onLine?: (line: string) => void,
): Promise<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let lineBuffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    const chunk = decoder.decode(value, { stream: true });
    text += chunk;
    lineBuffer += chunk;
    let newlineIndex = lineBuffer.indexOf("\n");
    while (newlineIndex >= 0) {
      onLine?.(lineBuffer.slice(0, newlineIndex).replace(/\r$/, ""));
      lineBuffer = lineBuffer.slice(newlineIndex + 1);
      newlineIndex = lineBuffer.indexOf("\n");
    }
  }
  const tail = decoder.decode();
  text += tail;
  lineBuffer += tail;
  if (lineBuffer.length > 0) {
    onLine?.(lineBuffer.replace(/\r$/, ""));
  }
  return text;
}

async function controllerDevices(origin: string, controllerToken: string) {
  const response = await relayRequest(origin, "/api/v1/devices", {
    headers: bearerHeaders(controllerToken),
  });
  expect(response.status).toBe(200);
  return DeviceListResponseSchema.parse(await response.json());
}

async function relayRequest(origin: string, path: string, init: RequestInit): Promise<Response> {
  return await fetch(`${origin}${path}`, {
    ...init,
    signal: AbortSignal.timeout(5_000),
  });
}

function bearerHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

function bearerJSONHeaders(token: string): Record<string, string> {
  return { ...bearerHeaders(token), "Content-Type": "application/json" };
}

async function readCredential(path: string): Promise<StoredRelayCredential> {
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8"));
  } catch {
    throw new Error("QuotaCLI did not write a valid relay credential.");
  }
  if (!isRecord(value)) {
    throw new Error("QuotaCLI did not write a valid relay credential.");
  }
  const { relay_url, instance_id, device_id, device_token, last_sequence } = value;
  if (
    typeof relay_url !== "string" ||
    typeof instance_id !== "string" ||
    typeof device_id !== "string" ||
    typeof device_token !== "string" ||
    device_token.length === 0 ||
    typeof last_sequence !== "number"
  ) {
    throw new Error("QuotaCLI did not write a valid relay credential.");
  }
  return { relay_url, instance_id, device_id, device_token, last_sequence };
}

function assertBearerMaterialAbsent(result: CLIResult, secrets: readonly string[]): void {
  const output = `${result.stdout}\n${result.stderr}`;
  if (secrets.some((secret) => output.includes(secret))) {
    throw new Error("QuotaCLI output exposed bearer credential material.");
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if (isFileSystemError(error, "ENOENT")) {
      return false;
    }
    throw error;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isFileSystemError(error: unknown, code: string): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === code;
}

async function withTimeout<T>(
  promise: Promise<T>,
  milliseconds: number,
  message: string,
  onTimeout?: () => void,
): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_resolve, reject) => {
        timeout = setTimeout(() => {
          onTimeout?.();
          reject(new Error(message));
        }, milliseconds);
      }),
    ]);
  } finally {
    if (timeout) {
      clearTimeout(timeout);
    }
  }
}
