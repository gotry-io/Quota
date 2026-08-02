import { join } from "node:path";
import { asRecord, readString } from "../../runtime/files.ts";
import {
  GROK_RPC_INITIALIZE_TIMEOUT_MS,
  GROK_RPC_REQUEST_TIMEOUT_MS,
} from "../../runtime/limits.ts";
import { JsonRpcClient, resolveProviderExecutable } from "../../runtime/process.ts";

const GROK_CACHED_TOKEN_METHOD = "cached_token";

export interface GrokCliAuthRefreshOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  signal?: AbortSignal;
}

export async function refreshGrokAuthWithCli(options: GrokCliAuthRefreshOptions): Promise<boolean> {
  const environment = options.environment ?? process.env;
  const executable = await resolveGrokExecutable(options.homeDirectory, environment);
  if (!executable) {
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

  let initialized = false;
  try {
    const response = await client.initialize("initialize", {
      protocolVersion: "1",
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
      },
    });
    initialized = true;

    const methodId = selectCachedTokenMethod(response);
    if (!methodId) {
      return initialized;
    }
    await client.request({
      method: "authenticate",
      params: {
        methodId,
        _meta: { headless: true },
      },
      timeoutMs: GROK_RPC_REQUEST_TIMEOUT_MS,
    });
    return true;
  } catch (error) {
    if (options.signal?.aborted) {
      throw error;
    }
    // Initialization itself performs Grok's silent refresh. Even when the
    // follow-up cached-token authentication fails, allow the caller to reload
    // auth.json and observe a token that may already have been rotated.
    return initialized;
  } finally {
    client.shutdown();
  }
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
