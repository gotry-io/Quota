import { join } from "node:path";
import { asRecord, readJsonFile, readString } from "../../runtime/files.ts";
import { parseFlexibleDate } from "../../runtime/time.ts";

export const GROK_OIDC_SCOPE_PREFIX = "https://auth.x.ai::";
export const GROK_LEGACY_SESSION_SCOPE = "https://accounts.x.ai/sign-in";
export const GROK_SOURCE_API = "grok_billing_api";
export const GROK_AUTH_REFRESH_SKEW_MS = 60_000;

export interface GrokCredentials {
  scope: string;
  /** Kept in memory for requests to the fixed official Grok endpoint; never emitted. */
  accessToken: string;
  userId?: string;
  email?: string;
  firstName?: string;
  lastName?: string;
  teamId?: string;
  principalType?: string;
  expiresAt?: Date;
  sourcePath: string;
}

export interface GrokCredentialLoadOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  readJson?: (path: string) => Promise<unknown | undefined>;
}

export function grokAuthPaths(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = {},
): string[] {
  const paths: string[] = [];
  const grokHome = environment.GROK_HOME?.trim();
  if (grokHome) {
    paths.push(join(grokHome, "auth.json"));
  }
  paths.push(join(homeDirectory, ".grok", "auth.json"));
  return [...new Set(paths)];
}

export async function loadGrokCredentials(
  options: GrokCredentialLoadOptions,
): Promise<GrokCredentials | undefined> {
  const environment = options.environment ?? {};
  const readJson = options.readJson ?? readJsonFile;
  for (const path of grokAuthPaths(options.homeDirectory, environment)) {
    const json = await readJson(path);
    const parsed = parseGrokCredentials(json, path);
    if (parsed) {
      return parsed;
    }
  }
  return undefined;
}

export function parseGrokCredentials(
  json: unknown,
  sourcePath: string,
): GrokCredentials | undefined {
  const root = asRecord(json);
  if (!root) {
    return undefined;
  }

  const preferred = selectPreferredEntry(root);
  if (!preferred) {
    return undefined;
  }
  const { scope, entry } = preferred;
  const key = readString(entry, "key");
  if (!key) {
    return undefined;
  }

  const userId = readString(entry, "user_id", "userId");
  const email = readString(entry, "email");
  const firstName = readString(entry, "first_name", "firstName");
  const lastName = readString(entry, "last_name", "lastName");
  const teamId = readString(entry, "team_id", "teamId");
  const principalType = readString(entry, "principal_type", "principalType");
  const expiresAt = parseFlexibleDate(entry.expires_at ?? entry.expiresAt);

  return {
    scope,
    accessToken: key,
    ...(userId ? { userId } : {}),
    ...(email ? { email } : {}),
    ...(firstName ? { firstName } : {}),
    ...(lastName ? { lastName } : {}),
    ...(teamId ? { teamId } : {}),
    ...(principalType ? { principalType } : {}),
    ...(expiresAt ? { expiresAt } : {}),
    sourcePath,
  };
}

function selectPreferredEntry(
  root: Record<string, unknown>,
): { scope: string; entry: Record<string, unknown> } | undefined {
  const oidc: Array<{ scope: string; entry: Record<string, unknown> }> = [];
  const legacy: Array<{ scope: string; entry: Record<string, unknown> }> = [];

  for (const [scope, value] of Object.entries(root)) {
    const entry = asRecord(value);
    if (!entry) {
      continue;
    }
    const key = readString(entry, "key");
    if (!key) {
      continue;
    }
    if (scope.startsWith(GROK_OIDC_SCOPE_PREFIX)) {
      oidc.push({ scope, entry });
    } else if (scope === GROK_LEGACY_SESSION_SCOPE || scope.includes("/sign-in")) {
      legacy.push({ scope, entry });
    }
  }

  return newestEntry(oidc) ?? newestEntry(legacy);
}

function newestEntry(
  entries: Array<{ scope: string; entry: Record<string, unknown> }>,
): { scope: string; entry: Record<string, unknown> } | undefined {
  return entries.reduce<(typeof entries)[number] | undefined>((best, candidate) => {
    if (!best) {
      return candidate;
    }
    const bestExpiry = parseFlexibleDate(best.entry.expires_at ?? best.entry.expiresAt)?.getTime();
    const candidateExpiry = parseFlexibleDate(
      candidate.entry.expires_at ?? candidate.entry.expiresAt,
    )?.getTime();
    if (
      candidateExpiry !== undefined &&
      (bestExpiry === undefined || candidateExpiry > bestExpiry)
    ) {
      return candidate;
    }
    return best;
  }, undefined);
}

export function shouldRefreshGrokCredentials(
  credentials: GrokCredentials,
  now = new Date(),
): boolean {
  return (
    credentials.expiresAt !== undefined &&
    credentials.expiresAt.getTime() <= now.getTime() + GROK_AUTH_REFRESH_SKEW_MS
  );
}

export function grokDisplayName(credentials: GrokCredentials): string | undefined {
  const parts = [credentials.firstName, credentials.lastName].filter(
    (part): part is string => typeof part === "string" && part.trim().length > 0,
  );
  if (parts.length === 0) {
    return undefined;
  }
  return parts.join(" ");
}
