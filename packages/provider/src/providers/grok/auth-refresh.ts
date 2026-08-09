import { open, readFile } from "node:fs/promises";
import { join } from "node:path";
import { asRecord, readString } from "../../runtime/files.ts";
import {
  GROK_RPC_INITIALIZE_TIMEOUT_MS,
  GROK_RPC_REQUEST_TIMEOUT_MS,
} from "../../runtime/limits.ts";
import { JsonRpcClient, resolveProviderExecutable } from "../../runtime/process.ts";
import { grokAuthPaths, parseGrokCredentials } from "./credentials.ts";

const GROK_CACHED_TOKEN_METHOD = "cached_token";

export interface GrokCliAuthRefreshOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  signal?: AbortSignal;
}

/**
 * Headless Grok CLI refresh. Snapshots auth.json first because some CLI builds
 * delete it when silent refresh fails. A restored snapshot is not a rotation.
 */
export async function refreshGrokAuthWithCli(options: GrokCliAuthRefreshOptions): Promise<boolean> {
  const environment = options.environment ?? process.env;
  const executable = await resolveGrokExecutable(options.homeDirectory, environment);
  if (!executable) {
    return false;
  }

  const backup = await snapshotAuthFile(options.homeDirectory, environment);
  if (!backup) {
    return false;
  }

  const client = new JsonRpcClient({
    executable,
    args: ["agent", "stdio"],
    environment,
    initializeTimeoutMs: GROK_RPC_INITIALIZE_TIMEOUT_MS,
    requestTimeoutMs: GROK_RPC_REQUEST_TIMEOUT_MS,
    ...(options.signal ? { signal: options.signal } : {}),
  });

  try {
    const response = await client.initialize("initialize", {
      protocolVersion: "1",
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
      },
    });

    const methodId = selectCachedTokenMethod(response);
    if (methodId) {
      await client.request({
        method: "authenticate",
        params: {
          methodId,
          _meta: { headless: true },
        },
        timeoutMs: GROK_RPC_REQUEST_TIMEOUT_MS,
      });
    }
  } catch (error) {
    if (options.signal?.aborted) {
      await restoreAuthFileIfMissing(backup);
      throw error;
    }
    // initialize may already have rotated; inspect the live file below.
  } finally {
    client.shutdown();
  }

  // Success only if auth stayed readable without restore. Restoring a deleted
  // file preserves the previous session; it is not a provider-owned rotation.
  if (await readAuthBytes(backup.path)) {
    return true;
  }
  await restoreAuthFileIfMissing(backup);
  return false;
}

export async function resolveGrokExecutable(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): Promise<string | undefined> {
  return await resolveProviderExecutable({
    name: "grok",
    overrideKey: "GROK_CLI_PATH",
    environment,
    knownPaths: [
      join(homeDirectory, ".grok", "bin", "grok"),
      join(homeDirectory, ".local", "bin", "grok"),
      "/usr/local/bin/grok",
      "/opt/homebrew/bin/grok",
    ],
  });
}

function selectCachedTokenMethod(value: unknown): string | undefined {
  const root = asRecord(value);
  const authMethods = Array.isArray(root?.authMethods) ? root.authMethods : [];
  const cachedToken = authMethods.find((method) => {
    const record = asRecord(method);
    return readString(record, "id") === GROK_CACHED_TOKEN_METHOD;
  });
  const cachedTokenId = readString(asRecord(cachedToken), "id");
  if (!cachedTokenId) {
    return undefined;
  }

  const preferred = readString(asRecord(root?._meta), "defaultAuthMethodId");
  return preferred === GROK_CACHED_TOKEN_METHOD ? preferred : cachedTokenId;
}

async function snapshotAuthFile(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>>,
): Promise<{ path: string; bytes: Buffer } | undefined> {
  for (const path of grokAuthPaths(homeDirectory, environment)) {
    const bytes = await readAuthBytes(path);
    if (bytes) {
      return { path, bytes };
    }
  }
  return undefined;
}

async function restoreAuthFileIfMissing(backup: { path: string; bytes: Buffer }): Promise<void> {
  try {
    // Exclusive creation is the final authority: malformed, rotated, or concurrently
    // recreated auth files are never overwritten during recovery.
    const handle = await open(backup.path, "wx", 0o600);
    try {
      await handle.writeFile(backup.bytes);
      await handle.sync();
    } finally {
      await handle.close();
    }
  } catch {
    // best-effort; caller treats missing auth as refresh failure
  }
}

async function readAuthBytes(path: string): Promise<Buffer | undefined> {
  try {
    const bytes = await readFile(path);
    if (parseGrokCredentials(JSON.parse(bytes.toString("utf8")) as unknown, path)) {
      return bytes;
    }
  } catch {
    // missing or unreadable
  }
  return undefined;
}
