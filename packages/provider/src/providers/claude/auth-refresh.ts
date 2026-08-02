import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProviderCollectionError } from "../../contracts.ts";
import {
  CLAUDE_CLI_OUTPUT_LIMIT_BYTES,
  CLAUDE_CLI_REFRESH_TIMEOUT_MS,
} from "../../runtime/limits.ts";
import { resolveExecutable, resolveProviderExecutable } from "../../runtime/process.ts";

const CLAUDE_PROBE_SESSION_FILE = ".quota-session-id";
const CLAUDE_PROBE_EXPECT_FILE = "refresh.exp";
const CLAUDE_PROBE_SETTINGS = {
  disableDeepLinkRegistration: "disable",
};
const CLAUDE_REFRESH_EXPECT_SCRIPT = `#!/usr/bin/expect -f
log_user 0
match_max 65536
set timeout 2
set status_sent 0

if {[llength $argv] < 1} {
  exit 2
}

spawn {*}$argv
expect {
  -nocase -re {quick.*safety.*check|trust.*folder} {
    send -- "y\\r"
    after 1800
    send -- "/status\\r"
    set status_sent 1
  }
  timeout {
    send -- "/status\\r"
    set status_sent 1
  }
  eof {
    exit 3
  }
}

set timeout 3
expect {
  -nocase -re {quick.*safety.*check|trust.*folder} {
    send -- "y\\r"
    after 1800
    send -- "/status\\r"
    set status_sent 1
    exp_continue
  }
  timeout {
    catch {send -- "/exit\\r"}
    exit [expr {$status_sent ? 0 : 3}]
  }
  eof {
    exit [expr {$status_sent ? 0 : 3}]
  }
}
`;

export interface ClaudeCliAuthRefreshOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  platform?: NodeJS.Platform;
  signal?: AbortSignal;
}

/**
 * Touch Claude Code's OAuth auth path without running a model prompt.
 *
 * Claude performs refresh-token exchange while its interactive `/status` path
 * loads the account. Quota never receives or submits that refresh token. The
 * macOS `expect` utility supplies the PTY required by Claude's slash command.
 */
export async function refreshClaudeAuthWithCli(
  options: ClaudeCliAuthRefreshOptions,
): Promise<boolean> {
  const platform = options.platform ?? process.platform;
  if (platform !== "darwin") {
    return false;
  }
  if (options.signal?.aborted) {
    throw new ProviderCollectionError("unavailable", "Claude CLI refresh cancelled.");
  }

  const environment = options.environment ?? process.env;
  const executable = await resolveClaudeExecutable(options.homeDirectory, environment);
  const expectExecutable = await resolveExecutable("/usr/bin/expect", environment);
  if (!executable || !expectExecutable) {
    return false;
  }

  const probeDirectory = await prepareProbeDirectory();
  const expectScript = join(probeDirectory, CLAUDE_PROBE_EXPECT_FILE);
  const sessionId = await loadOrCreateProbeSessionId(probeDirectory);
  await removeProbeTranscript({
    homeDirectory: options.homeDirectory,
    environment,
    probeDirectory,
    sessionId,
  });

  const childEnvironment = makeClaudeEnvironment(
    options.homeDirectory,
    probeDirectory,
    environment,
  );
  const child = spawn(
    expectExecutable,
    [expectScript, executable, "--allowed-tools", "", "--session-id", sessionId],
    {
      cwd: probeDirectory,
      env: childEnvironment,
      stdio: ["ignore", "pipe", "pipe"],
      shell: false,
      windowsHide: true,
    },
  );

  try {
    return await waitForStatusProbe(child, options.signal);
  } finally {
    terminateChild(child);
    await removeProbeTranscript({
      homeDirectory: options.homeDirectory,
      environment,
      probeDirectory,
      sessionId,
    });
  }
}

export async function resolveClaudeExecutable(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): Promise<string | undefined> {
  return await resolveProviderExecutable({
    name: "claude",
    overrideKey: "CLAUDE_CLI_PATH",
    environment,
    knownPaths: [
      join(homeDirectory, ".local", "bin", "claude"),
      join(homeDirectory, ".claude", "local", "claude"),
      join(homeDirectory, ".claude", "bin", "claude"),
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      "/Applications/cmux.app/Contents/Resources/bin/claude",
    ],
  });
}

async function waitForStatusProbe(child: ChildProcess, signal?: AbortSignal): Promise<boolean> {
  return await new Promise<boolean>((resolve, reject) => {
    let settled = false;
    let capturedBytes = 0;
    const timer = setTimeout(() => {
      terminateChild(child);
      finish(false);
    }, CLAUDE_CLI_REFRESH_TIMEOUT_MS + 1_000);
    const finish = (value: boolean) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      resolve(value);
    };
    const onAbort = () => {
      terminateChild(child);
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new ProviderCollectionError("unavailable", "Claude CLI refresh cancelled."));
      }
    };
    const observe = (chunk: Buffer) => {
      capturedBytes += chunk.byteLength;
      if (capturedBytes > CLAUDE_CLI_OUTPUT_LIMIT_BYTES) {
        terminateChild(child);
        finish(false);
      }
    };

    child.stdout?.on("data", observe);
    child.stderr?.on("data", observe);
    child.on("error", () => finish(false));
    child.on("close", (code) => finish(code === 0));
    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

async function prepareProbeDirectory(): Promise<string> {
  const uid = typeof process.getuid === "function" ? process.getuid() : "user";
  const directory = join(tmpdir(), `gotry-quota-claude-probe-${uid}`);
  const settingsDirectory = join(directory, ".claude");
  await mkdir(settingsDirectory, { recursive: true, mode: 0o700 });
  const settingsPath = join(settingsDirectory, "settings.local.json");
  await writeFile(settingsPath, `${JSON.stringify(CLAUDE_PROBE_SETTINGS, undefined, 2)}\n`, {
    mode: 0o600,
  });
  await writeFile(join(directory, CLAUDE_PROBE_EXPECT_FILE), CLAUDE_REFRESH_EXPECT_SCRIPT, {
    mode: 0o700,
  });
  return directory;
}

async function loadOrCreateProbeSessionId(directory: string): Promise<string> {
  const path = join(directory, CLAUDE_PROBE_SESSION_FILE);
  try {
    const existing = (await readFile(path, "utf8")).trim();
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(existing)) {
      return existing;
    }
  } catch {
    // Create a stable probe-only session identifier below.
  }
  const sessionId = randomUUID();
  await writeFile(path, `${sessionId}\n`, { mode: 0o600 });
  return sessionId;
}

function makeClaudeEnvironment(
  homeDirectory: string,
  probeDirectory: string,
  environment: Readonly<Record<string, string | undefined>>,
): NodeJS.ProcessEnv {
  const result: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(environment)) {
    if (typeof value === "string" && !key.startsWith("ANTHROPIC_")) {
      result[key] = value;
    }
  }
  result.HOME ??= homeDirectory;
  result.PWD = probeDirectory;
  result.DISABLE_AUTOUPDATER = "1";
  return result;
}

async function removeProbeTranscript(options: {
  homeDirectory: string;
  environment: Readonly<Record<string, string | undefined>>;
  probeDirectory: string;
  sessionId: string;
}): Promise<void> {
  const configRoot =
    options.environment.CLAUDE_CONFIG_DIR?.split(",")[0]?.trim() ||
    join(options.homeDirectory, ".claude");
  const projectDirectory = options.probeDirectory
    .normalize("NFC")
    .replace(/[^0-9A-Za-z]/gu, "-")
    .slice(0, 200);
  const transcript = join(configRoot, "projects", projectDirectory, `${options.sessionId}.jsonl`);
  try {
    await rm(transcript, { force: true });
  } catch {
    // Probe cleanup must not invalidate a successful credential refresh.
  }
}

function terminateChild(child: ChildProcess): void {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  try {
    child.stdin?.end();
  } catch {
    // Ignore a process that already closed its PTY input.
  }
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
    }
  }, 500).unref?.();
}
