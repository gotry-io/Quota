import { join } from "node:path";
import { asRecord, readJsonFile, readString } from "../../runtime/files.ts";

export interface CodexCredentials {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  accountId?: string;
  lastRefresh?: string;
  sourcePath: string;
  hasRefreshToken: boolean;
}

export interface CodexCredentialLoadOptions {
  homeDirectory: string;
  environment?: Readonly<Record<string, string | undefined>>;
  readJson?: (path: string) => Promise<unknown | undefined>;
}

export function codexAuthPaths(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = {},
): string[] {
  const paths: string[] = [];
  const codexHome = environment.CODEX_HOME?.trim();
  if (codexHome) {
    paths.push(join(codexHome, "auth.json"));
  }
  paths.push(join(homeDirectory, ".codex", "auth.json"));
  return [...new Set(paths)];
}

export async function loadCodexCredentials(
  options: CodexCredentialLoadOptions,
): Promise<CodexCredentials | undefined> {
  const environment = options.environment ?? {};
  const readJson = options.readJson ?? readJsonFile;
  for (const path of codexAuthPaths(options.homeDirectory, environment)) {
    const json = await readJson(path);
    const parsed = parseCodexCredentials(json, path);
    if (parsed) {
      return parsed;
    }
  }
  return undefined;
}

export function parseCodexCredentials(
  json: unknown,
  sourcePath: string,
): CodexCredentials | undefined {
  const root = asRecord(json);
  if (!root) {
    return undefined;
  }

  const tokens = asRecord(root.tokens);
  if (!tokens) {
    return undefined;
  }

  const accessToken = readString(tokens, "access_token", "accessToken");
  if (!accessToken) {
    return undefined;
  }

  const refreshToken = readString(tokens, "refresh_token", "refreshToken");
  const idToken = readString(tokens, "id_token", "idToken");
  const accountId = readString(tokens, "account_id", "accountId");
  const lastRefresh =
    typeof root.last_refresh === "string"
      ? root.last_refresh
      : typeof root.lastRefresh === "string"
        ? root.lastRefresh
        : undefined;

  return {
    accessToken,
    ...(refreshToken ? { refreshToken } : {}),
    ...(idToken ? { idToken } : {}),
    ...(accountId ? { accountId } : {}),
    ...(lastRefresh ? { lastRefresh } : {}),
    sourcePath,
    hasRefreshToken: Boolean(refreshToken),
  };
}

export function decodeJwtPayload(token: string | undefined): Record<string, unknown> | undefined {
  if (!token) {
    return undefined;
  }
  const parts = token.split(".");
  if (parts.length < 2) {
    return undefined;
  }
  const payload = parts[1];
  if (!payload) {
    return undefined;
  }
  try {
    const normalized = payload.replaceAll("-", "+").replaceAll("_", "/");
    const pad = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
    const json = Buffer.from(normalized + pad, "base64").toString("utf8");
    const parsed = JSON.parse(json) as unknown;
    return asRecord(parsed);
  } catch {
    return undefined;
  }
}

export function extractCodexIdentity(credentials: CodexCredentials): {
  email?: string;
  plan?: string;
  accountId?: string;
} {
  const payload = decodeJwtPayload(credentials.idToken);
  const auth = asRecord(payload?.["https://api.openai.com/auth"]);
  const profile = asRecord(payload?.["https://api.openai.com/profile"]);
  const email = readString(payload, "email") ?? readString(profile, "email") ?? undefined;
  const plan =
    readString(auth, "chatgpt_plan_type") ?? readString(payload, "chatgpt_plan_type") ?? undefined;
  const accountId =
    credentials.accountId ??
    readString(auth, "chatgpt_account_id") ??
    readString(payload, "chatgpt_account_id") ??
    undefined;
  return {
    ...(email ? { email } : {}),
    ...(plan ? { plan } : {}),
    ...(accountId ? { accountId } : {}),
  };
}
