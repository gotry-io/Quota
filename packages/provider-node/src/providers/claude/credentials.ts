import { join } from "node:path";
import {
  asRecord,
  readJsonFile,
  readNumber,
  readString,
  readStringArray,
} from "../../runtime/files.ts";
import { readGenericPassword } from "../../runtime/keychain.ts";
import { parseFlexibleDate } from "../../runtime/time.ts";

export const CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials";
export const CLAUDE_SOURCE_API = "anthropic_oauth_usage_api";

export interface ClaudeCredentials {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: Date;
  scopes: string[];
  subscriptionType?: string;
  rateLimitTier?: string;
  source: string;
}

export interface ClaudeCredentialLoadOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  platform?: NodeJS.Platform;
  signal?: AbortSignal;
  readJson?: (path: string) => Promise<unknown | undefined>;
  readKeychain?: (service: string) => Promise<string | undefined>;
}

export function claudeCredentialPaths(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = {},
): string[] {
  const root = environment.CLAUDE_CONFIG_DIR?.trim() || join(homeDirectory, ".claude");
  return [join(root, ".credentials.json")];
}

export async function loadClaudeCredentials(
  options: ClaudeCredentialLoadOptions,
): Promise<ClaudeCredentials | undefined> {
  const environment = options.environment ?? {};
  const readJson = options.readJson ?? readJsonFile;

  for (const path of claudeCredentialPaths(options.homeDirectory, environment)) {
    const json = await readJson(path);
    const parsed = parseClaudeCredentials(json, path);
    if (parsed) {
      return parsed;
    }
  }

  const readKeychain =
    options.readKeychain ??
    ((service: string) =>
      readGenericPassword({
        service,
        ...(options.platform ? { platform: options.platform } : {}),
        ...(options.signal ? { signal: options.signal } : {}),
      }));

  const keychainPayload = await readKeychain(CLAUDE_KEYCHAIN_SERVICE);
  if (keychainPayload) {
    try {
      const json = JSON.parse(keychainPayload) as unknown;
      const parsed = parseClaudeCredentials(json, `macOS Keychain: ${CLAUDE_KEYCHAIN_SERVICE}`);
      if (parsed) {
        return parsed;
      }
    } catch {
      return undefined;
    }
  }

  return undefined;
}

export function parseClaudeCredentials(
  json: unknown,
  source: string,
): ClaudeCredentials | undefined {
  const root = asRecord(json);
  if (!root) {
    return undefined;
  }
  if (root.claudeAiOauth === undefined && root.mcpOAuth !== undefined) {
    return undefined;
  }
  const oauth = asRecord(root.claudeAiOauth);
  if (!oauth) {
    return undefined;
  }
  const accessToken = readString(oauth, "accessToken", "access_token");
  if (!accessToken) {
    return undefined;
  }
  const refreshToken = readString(oauth, "refreshToken", "refresh_token");
  const scopes = readStringArray(oauth, "scopes") ?? [];
  const subscriptionType = readString(oauth, "subscriptionType", "subscription_type");
  const rateLimitTier = readString(oauth, "rateLimitTier", "rate_limit_tier");
  const expiresRaw = readNumber(oauth, "expiresAt", "expires_at");
  const expiresAt = expiresRaw !== undefined ? parseFlexibleDate(expiresRaw) : undefined;

  return {
    accessToken,
    ...(refreshToken ? { refreshToken } : {}),
    ...(expiresAt ? { expiresAt } : {}),
    scopes,
    ...(subscriptionType ? { subscriptionType } : {}),
    ...(rateLimitTier ? { rateLimitTier } : {}),
    source,
  };
}

export function hasUserProfileScope(credentials: ClaudeCredentials): boolean {
  return credentials.scopes.includes("user:profile");
}
