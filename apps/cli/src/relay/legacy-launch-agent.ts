import { spawn } from "node:child_process";
import type { Stats } from "node:fs";
import { lstat, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, normalize } from "node:path";

const legacyLabel = "io.gotry.quotacli.relay";
const launchctlPath = "/bin/launchctl";
const launchctlTimeoutMilliseconds = 10_000;
const launchctlOutputLimitBytes = 16 * 1024;

interface LegacyLaunchAgentFileSystem {
  lstat(path: string): Promise<Stats>;
  unlink(path: string): Promise<void>;
}

interface LaunchctlResult {
  exitCode: number;
}

type LaunchctlRunner = (executable: string, args: readonly string[]) => Promise<LaunchctlResult>;

export interface LegacyLaunchAgentCleanupOptions {
  plistPath?: string;
  uid?: number;
  runner?: LaunchctlRunner;
  filesystem?: LegacyLaunchAgentFileSystem;
}

/** Removes the LaunchAgent shipped by QuotaCLI releases before QuotaBar owned scheduling. */
export async function cleanupLegacyMacOSLaunchAgent(
  options: LegacyLaunchAgentCleanupOptions = {},
): Promise<void> {
  const path = normalize(
    options.plistPath ?? join(homedir(), "Library", "LaunchAgents", `${legacyLabel}.plist`),
  );
  if (!isAbsolute(path)) {
    throw new Error("QuotaCLI could not remove the legacy background task.");
  }

  const filesystem = options.filesystem ?? { lstat, unlink };
  const directoryMetadata = await metadataOrNull(dirname(path), filesystem);
  if (!directoryMetadata) {
    return;
  }
  if (!directoryMetadata.isDirectory() || directoryMetadata.isSymbolicLink()) {
    throw new Error("QuotaCLI could not remove the legacy background task.");
  }

  const fileMetadata = await metadataOrNull(path, filesystem);
  if (!fileMetadata) {
    return;
  }
  if (!fileMetadata.isFile() || fileMetadata.isSymbolicLink()) {
    throw new Error("QuotaCLI could not remove the legacy background task.");
  }

  const uid = options.uid ?? currentUserID();
  const runner = options.runner ?? runLaunchctl;
  const result = await runner(launchctlPath, ["bootout", `gui/${uid}/${legacyLabel}`]);
  if (result.exitCode !== 0 && result.exitCode !== 3) {
    throw new Error("QuotaCLI could not remove the legacy background task.");
  }
  await filesystem.unlink(path);
}

async function metadataOrNull(
  path: string,
  filesystem: LegacyLaunchAgentFileSystem,
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
    throw new Error("QuotaCLI could not remove the legacy background task.");
  }
  return process.getuid();
}

function isFileSystemError(error: unknown, code: string): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === code;
}

async function runLaunchctl(executable: string, args: readonly string[]): Promise<LaunchctlResult> {
  return await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, [...args], {
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let settled = false;
    let outputBytes = 0;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const reject = () => {
      child.kill("SIGKILL");
      finish(() => rejectPromise(new Error("QuotaCLI could not run launchctl.")));
    };
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
          rejectPromise(new Error("QuotaCLI could not run launchctl."));
        } else {
          resolvePromise({ exitCode: code });
        }
      });
    });
    timeout = setTimeout(reject, launchctlTimeoutMilliseconds);
  });
}
