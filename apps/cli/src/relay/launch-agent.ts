import { spawn } from "node:child_process";
import type { Stats } from "node:fs";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, normalize, resolve } from "node:path";

export const RELAY_LAUNCH_AGENT_LABEL = "io.gotry.quotacli.relay";
export const LAUNCHCTL_PATH = "/bin/launchctl";

const pushIntervalSeconds = 300;
const launchctlTimeoutMilliseconds = 10_000;
const launchctlOutputLimitBytes = 16 * 1024;
const bunCompiledMainPrefix = "/$bunfs/root/";
const inheritedEnvironmentKeys = [
  "PATH",
  "XDG_CONFIG_HOME",
  "CODEX_HOME",
  "CLAUDE_CONFIG_DIR",
  "GROK_HOME",
  "CODEX_CLI_PATH",
  "CLAUDE_CLI_PATH",
  "GROK_CLI_PATH",
] as const;

export type RelayServiceStatus = "loaded" | "stopped";

export interface RelayPushService {
  start(): Promise<void>;
  status(): Promise<RelayServiceStatus>;
  stop(): Promise<void>;
}

export interface RelayPushInvocationInput {
  execPath: string;
  argv1?: string;
  cwd: string;
}

export interface LaunchctlResult {
  exitCode: number;
}

export type LaunchctlRunner = (
  executable: string,
  args: readonly string[],
) => Promise<LaunchctlResult>;

interface LaunchAgentFileHandle {
  writeFile(contents: string, encoding: "utf8"): Promise<void>;
  sync(): Promise<void>;
  close(): Promise<void>;
}

export interface LaunchAgentFileSystem {
  chmod(path: string, mode: number): Promise<void>;
  lstat(path: string): Promise<Stats>;
  mkdir(path: string, options: { recursive: true; mode: number }): Promise<unknown>;
  open(path: string, flags: string, mode: number): Promise<LaunchAgentFileHandle>;
  rename(from: string, to: string): Promise<void>;
  unlink(path: string): Promise<void>;
}

export interface MacOSLaunchAgentOptions {
  plistPath?: string;
  uid?: number;
  invocation?: RelayPushInvocationInput;
  environment?: NodeJS.ProcessEnv;
  runner?: LaunchctlRunner;
  filesystem?: LaunchAgentFileSystem;
}

export class LaunchAgentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LaunchAgentError";
  }
}

export class MacOSLaunchAgent implements RelayPushService {
  readonly #plistPath: string;
  readonly #uid: number | undefined;
  readonly #invocation: RelayPushInvocationInput | undefined;
  readonly #environment: NodeJS.ProcessEnv;
  readonly #runner: LaunchctlRunner;
  readonly #filesystem: LaunchAgentFileSystem;

  constructor(options: MacOSLaunchAgentOptions = {}) {
    this.#plistPath =
      options.plistPath ??
      join(homedir(), "Library", "LaunchAgents", `${RELAY_LAUNCH_AGENT_LABEL}.plist`);
    this.#uid = options.uid;
    this.#invocation = options.invocation;
    this.#environment = options.environment ?? process.env;
    this.#runner = options.runner ?? runLaunchctl;
    this.#filesystem = options.filesystem ?? nodeFileSystem;
  }

  async start(): Promise<void> {
    try {
      const context = this.#context();
      const plist = renderLaunchAgentPlist(
        resolveRelayPushProgramArguments(context.invocation),
        this.#environment,
      );
      await preflightPlistTarget(context.plistPath, this.#filesystem);
      const bootout = await this.#run(["bootout", context.serviceTarget]);
      if (bootout.exitCode !== 0 && bootout.exitCode !== 3) {
        throw new LaunchAgentError("QuotaCLI could not unload the existing LaunchAgent.");
      }

      await writePlistAtomically(context.plistPath, plist, this.#filesystem);

      const bootstrap = await this.#run(["bootstrap", context.domainTarget, context.plistPath]);
      if (bootstrap.exitCode !== 0) {
        await this.#cleanupFailedStart(context);
        throw new LaunchAgentError("QuotaCLI could not load the LaunchAgent.");
      }
    } catch (error) {
      if (error instanceof LaunchAgentError) {
        throw error;
      }
      throw new LaunchAgentError("QuotaCLI could not start the LaunchAgent.");
    }
  }

  async status(): Promise<RelayServiceStatus> {
    try {
      const context = this.#context();
      const result = await this.#run(["print", context.serviceTarget]);
      if (result.exitCode === 0) {
        return "loaded";
      }
      if (result.exitCode === 113) {
        return "stopped";
      }
      throw new LaunchAgentError("QuotaCLI could not inspect the LaunchAgent.");
    } catch (error) {
      if (error instanceof LaunchAgentError) {
        throw error;
      }
      throw new LaunchAgentError("QuotaCLI could not inspect the LaunchAgent.");
    }
  }

  async stop(): Promise<void> {
    try {
      const context = this.#context();
      const result = await this.#run(["bootout", context.serviceTarget]);
      if (result.exitCode !== 0 && result.exitCode !== 3) {
        throw new LaunchAgentError("QuotaCLI could not unload the LaunchAgent.");
      }
      await removePlist(context.plistPath, this.#filesystem);
    } catch (error) {
      if (error instanceof LaunchAgentError) {
        throw error;
      }
      throw new LaunchAgentError("QuotaCLI could not stop the LaunchAgent.");
    }
  }

  async #run(args: readonly string[]): Promise<LaunchctlResult> {
    try {
      return await this.#runner(LAUNCHCTL_PATH, args);
    } catch {
      throw new LaunchAgentError("QuotaCLI could not run launchctl.");
    }
  }

  async #cleanupFailedStart(context: LaunchAgentContext): Promise<void> {
    await this.#run(["bootout", context.serviceTarget]).catch(() => undefined);
    await removePlist(context.plistPath, this.#filesystem).catch(() => undefined);
  }

  #context(): LaunchAgentContext {
    if (!isAbsolute(this.#plistPath)) {
      throw new LaunchAgentError("The LaunchAgent path must be absolute.");
    }
    const uid = this.#uid ?? currentUserID();
    const domainTarget = `gui/${uid}`;
    return {
      plistPath: normalize(this.#plistPath),
      domainTarget,
      serviceTarget: `${domainTarget}/${RELAY_LAUNCH_AGENT_LABEL}`,
      invocation: this.#invocation ?? {
        execPath: process.execPath,
        cwd: process.cwd(),
        ...(process.argv[1] ? { argv1: process.argv[1] } : {}),
      },
    };
  }
}

interface LaunchAgentContext {
  plistPath: string;
  domainTarget: string;
  serviceTarget: string;
  invocation: RelayPushInvocationInput;
}

export function resolveRelayPushProgramArguments(input: RelayPushInvocationInput): string[] {
  if (!isAbsolute(input.execPath) || !input.argv1) {
    throw new LaunchAgentError("QuotaCLI could not resolve its executable path.");
  }
  const executable = normalize(input.execPath);
  if (input.argv1.startsWith(bunCompiledMainPrefix)) {
    return [executable, "relay", "push"];
  }
  const entry = isAbsolute(input.argv1)
    ? normalize(input.argv1)
    : isAbsolute(input.cwd)
      ? resolve(input.cwd, input.argv1)
      : "";
  if (!isAbsolute(entry)) {
    throw new LaunchAgentError("QuotaCLI could not resolve its entry path.");
  }
  // Prefer the installed CLI path as ProgramArguments[0] so macOS Background Items show
  // "quotacli" instead of the Node/Bun runtime. launchd follows the script shebang.
  if (entry === executable || isInstalledCLIEntry(entry)) {
    return [entry, "relay", "push"];
  }
  return [executable, entry, "relay", "push"];
}

function isInstalledCLIEntry(entry: string): boolean {
  const name = basename(entry);
  return name === "quotacli" || name === "quotacli.js";
}

export function renderLaunchAgentPlist(
  programArguments: readonly string[],
  environment: NodeJS.ProcessEnv = {},
): string {
  if (programArguments.length < 3 || programArguments.some((argument) => argument.length === 0)) {
    throw new LaunchAgentError("QuotaCLI could not create the LaunchAgent configuration.");
  }
  const argumentElements = programArguments
    .map((argument) => `    <string>${escapeXML(argument)}</string>`)
    .join("\n");
  const inheritedEnvironment = inheritedEnvironmentKeys.flatMap((key) => {
    const value = environment[key];
    if (!value || (key === "XDG_CONFIG_HOME" && !isAbsolute(value))) {
      return [];
    }
    return [`    <key>${key}</key>\n    <string>${escapeXML(value)}</string>`];
  });
  const environmentSection =
    inheritedEnvironment.length === 0
      ? ""
      : `  <key>EnvironmentVariables</key>\n  <dict>\n${inheritedEnvironment.join("\n")}\n  </dict>\n`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${RELAY_LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${argumentElements}
  </array>
${environmentSection}  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${pushIntervalSeconds}</integer>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
</dict>
</plist>
`;
}

async function writePlistAtomically(
  path: string,
  contents: string,
  filesystem: LaunchAgentFileSystem,
): Promise<void> {
  const directory = dirname(path);
  let directoryMetadata = await metadataOrNull(directory, filesystem);
  if (!directoryMetadata) {
    await filesystem.mkdir(directory, { recursive: true, mode: 0o700 });
    directoryMetadata = await metadataOrNull(directory, filesystem);
  }
  if (!directoryMetadata?.isDirectory() || directoryMetadata.isSymbolicLink()) {
    throw new LaunchAgentError("The LaunchAgent directory is invalid.");
  }

  const existing = await metadataOrNull(path, filesystem);
  if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
    throw new LaunchAgentError("The LaunchAgent file is invalid.");
  }

  const temporaryPath = join(
    directory,
    `.${basename(path)}.${process.pid}.${crypto.randomUUID()}.tmp`,
  );
  let temporaryExists = false;
  try {
    const handle = await filesystem.open(temporaryPath, "wx", 0o600);
    temporaryExists = true;
    try {
      await handle.writeFile(contents, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await filesystem.chmod(temporaryPath, 0o600);
    await filesystem.rename(temporaryPath, path);
    temporaryExists = false;
  } finally {
    if (temporaryExists) {
      await filesystem.unlink(temporaryPath).catch(() => undefined);
    }
  }
}

async function preflightPlistTarget(
  path: string,
  filesystem: LaunchAgentFileSystem,
): Promise<void> {
  const directoryMetadata = await metadataOrNull(dirname(path), filesystem);
  if (
    directoryMetadata &&
    (!directoryMetadata.isDirectory() || directoryMetadata.isSymbolicLink())
  ) {
    throw new LaunchAgentError("The LaunchAgent directory is invalid.");
  }
  const fileMetadata = await metadataOrNull(path, filesystem);
  if (fileMetadata && (!fileMetadata.isFile() || fileMetadata.isSymbolicLink())) {
    throw new LaunchAgentError("The LaunchAgent file is invalid.");
  }
}

async function removePlist(path: string, filesystem: LaunchAgentFileSystem): Promise<void> {
  const directory = dirname(path);
  const directoryMetadata = await metadataOrNull(directory, filesystem);
  if (!directoryMetadata) {
    return;
  }
  if (!directoryMetadata.isDirectory() || directoryMetadata.isSymbolicLink()) {
    throw new LaunchAgentError("The LaunchAgent directory is invalid.");
  }
  const metadata = await metadataOrNull(path, filesystem);
  if (!metadata) {
    return;
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new LaunchAgentError("The LaunchAgent file is invalid.");
  }
  await filesystem.unlink(path);
}

async function metadataOrNull(
  path: string,
  filesystem: LaunchAgentFileSystem,
): Promise<Stats | null> {
  try {
    return await filesystem.lstat(path);
  } catch (error) {
    if (isFileSystemError(error, "ENOENT")) {
      return null;
    }
    throw error;
  }
}

function currentUserID(): number {
  if (typeof process.getuid !== "function") {
    throw new LaunchAgentError("QuotaCLI could not determine the current user ID.");
  }
  return process.getuid();
}

function escapeXML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function isFileSystemError(error: unknown, code: string): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === code;
}

const nodeFileSystem: LaunchAgentFileSystem = {
  chmod,
  lstat,
  mkdir,
  open,
  rename,
  unlink,
};

async function runLaunchctl(executable: string, args: readonly string[]): Promise<LaunchctlResult> {
  return await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, [...args], {
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let settled = false;
    let outputBytes = 0;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const finish = (callback: () => void) => {
      if (settled) {
        return;
      }
      settled = true;
      if (timeout) {
        clearTimeout(timeout);
      }
      callback();
    };
    const reject = () => {
      child.kill("SIGKILL");
      finish(() => rejectPromise(new LaunchAgentError("QuotaCLI could not run launchctl.")));
    };
    const countOutput = (chunk: Buffer | string) => {
      outputBytes += Buffer.byteLength(chunk);
      if (outputBytes > launchctlOutputLimitBytes) {
        reject();
      }
    };
    child.stdout?.on("data", countOutput);
    child.stderr?.on("data", countOutput);
    child.once("error", reject);
    child.once("close", (code) => {
      finish(() => {
        if (code === null) {
          rejectPromise(new LaunchAgentError("QuotaCLI could not run launchctl."));
        } else {
          resolvePromise({ exitCode: code });
        }
      });
    });
    timeout = setTimeout(reject, launchctlTimeoutMilliseconds);
  });
}
