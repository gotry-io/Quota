import { hostname } from "node:os";
import { parseArgs } from "node:util";
import type {
  DeviceAuthorizationRequest,
  DeviceAuthorizationResponse,
  OAuthTokenRequest,
  OAuthTokenResponse,
} from "@gotry-io/quota-protocol";
import type { CliOutput } from "../commands.ts";
import { cliParseError } from "../arguments.ts";
import { renderJson } from "../render.ts";
import { runBrowserAuthorization } from "./browser-login.ts";
import { AccountClient, AccountClientError, QUOTA_ACCOUNT_ORIGIN } from "./client.ts";
import {
  ACCOUNT_STATE_SCHEMA_VERSION,
  AccountStateStore,
  AccountStateStoreError,
  type ActiveAccountSessionState,
} from "./state.ts";

export interface AccountCommandClient {
  beginDeviceAuthorization(input: DeviceAuthorizationRequest): Promise<DeviceAuthorizationResponse>;
  exchangeToken(input: OAuthTokenRequest): Promise<OAuthTokenResponse>;
  revoke(token: string): Promise<void>;
}

export interface AccountCommandDependencies {
  client: AccountCommandClient;
  store: AccountStateStore;
  now(): Date;
  sleep(milliseconds: number): Promise<void>;
  browserLogin(): Promise<{
    code: string;
    code_verifier: string;
    redirect_uri: string;
  }>;
  deviceName(): string;
  platform: "macos" | "linux" | "windows";
}

export async function runLoginCommand(
  args: readonly string[],
  output: CliOutput,
  dependencies?: AccountCommandDependencies,
): Promise<number> {
  const parsed = parseAuthArguments(args, true);
  if (!parsed.ok) return usageError(parsed.error, output);
  let resolved: AccountCommandDependencies;
  try {
    resolved = dependencies ?? defaultDependencies();
    const current = await resolved.store.loadSession();
    if (current?.status === "active") {
      writeResult(output, parsed, authResult(current));
      return 0;
    }
    if (current?.status === "logout_pending") {
      output.stderr("QuotaCLI logout is pending. Run `quotacli logout` while online, then retry.");
      return 1;
    }
  } catch (error) {
    return reportAccountError(error, output, "QuotaCLI could not read local account state.");
  }

  try {
    const installation = await resolved.store.loadOrCreateInstallation();
    const deviceName = sanitizeDeviceName(resolved.deviceName());
    const issued = parsed.deviceAuth
      ? await loginWithDeviceAuthorization(
          resolved,
          {
            protocol_version: 2,
            client_id: "quotacli",
            installation_id: installation.installation_id,
            device_display_name: deviceName,
            platform: resolved.platform,
          },
          output,
        )
      : await loginWithBrowser(resolved, installation.installation_id, deviceName, output);
    const loginAt = resolved.now().toISOString();
    const uploadNotBefore = await resolved.store.uploadLowerBound(issued.account_id, loginAt);
    const session = toActiveSession(issued, uploadNotBefore);
    await resolved.store.saveActiveSession(session);
    writeResult(output, parsed, authResult(session));
    return 0;
  } catch (error) {
    return reportAccountError(error, output, "QuotaCLI could not complete account login.");
  }
}

export async function runLogoutCommand(
  args: readonly string[],
  output: CliOutput,
  dependencies?: AccountCommandDependencies,
): Promise<number> {
  const parsed = parseAuthArguments(args, false);
  if (!parsed.ok) return usageError(parsed.error, output);
  try {
    const resolved = dependencies ?? defaultDependencies();
    const pending = await resolved.store.beginLogout();
    if (pending === null) {
      writeResult(output, parsed, { schema_version: 1, status: "signed_out" });
      return 0;
    }
    await Promise.all([
      resolved.client.revoke(pending.account_refresh_token),
      resolved.client.revoke(pending.device_refresh_token),
    ]);
    await resolved.store.clearSession();
    writeResult(output, parsed, { schema_version: 1, status: "signed_out" });
    return 0;
  } catch (error) {
    return reportAccountError(
      error,
      output,
      "QuotaCLI stopped uploads locally, but server logout is pending. Retry while online.",
    );
  }
}

export async function runAuthCommand(
  args: readonly string[],
  output: CliOutput,
  dependencies?: AccountCommandDependencies,
): Promise<number> {
  if (args[0] !== "status") {
    return usageError(
      args[0] ? `Unknown auth command: ${args[0]}` : "Missing auth command.",
      output,
    );
  }
  const parsed = parseAuthArguments(args.slice(1), false);
  if (!parsed.ok) return usageError(parsed.error, output);
  try {
    const session = await (dependencies?.store ?? new AccountStateStore()).loadSession();
    const result =
      session === null
        ? { schema_version: 1 as const, status: "signed_out" as const }
        : session.status === "logout_pending"
          ? { schema_version: 1 as const, status: "logout_pending" as const }
          : authResult(session);
    writeResult(output, parsed, result);
    return session?.status === "logout_pending" ? 1 : 0;
  } catch (error) {
    return reportAccountError(error, output, "QuotaCLI could not read local account state.");
  }
}

async function loginWithBrowser(
  dependencies: AccountCommandDependencies,
  installationId: string,
  deviceName: string,
  output: CliOutput,
): Promise<OAuthTokenResponse> {
  output.stderr("Opening GitHub account login in your browser…");
  const callback = await dependencies.browserLogin();
  return await dependencies.client.exchangeToken({
    protocol_version: 2,
    grant_type: "authorization_code",
    client_id: "quotacli",
    code: callback.code,
    code_verifier: callback.code_verifier,
    redirect_uri: callback.redirect_uri,
    installation_id: installationId,
    device_display_name: deviceName,
    platform: dependencies.platform,
  });
}

async function loginWithDeviceAuthorization(
  dependencies: AccountCommandDependencies,
  request: DeviceAuthorizationRequest,
  output: CliOutput,
): Promise<OAuthTokenResponse> {
  const grant = await dependencies.client.beginDeviceAuthorization(request);
  output.stderr(`Open ${grant.verification_uri} and enter code ${grant.user_code}.`);
  let intervalMilliseconds = grant.interval * 1000;
  const deadline = dependencies.now().getTime() + grant.expires_in * 1000;
  while (dependencies.now().getTime() < deadline) {
    await dependencies.sleep(intervalMilliseconds);
    try {
      return await dependencies.client.exchangeToken({
        protocol_version: 2,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: "quotacli",
        device_code: grant.device_code,
      });
    } catch (error) {
      if (error instanceof AccountClientError && error.code === "authorization_pending") continue;
      if (error instanceof AccountClientError && error.code === "slow_down") {
        intervalMilliseconds += 5_000;
        continue;
      }
      throw error;
    }
  }
  throw new AccountClientError("expired_token", "Quota login expired.");
}

function toActiveSession(
  issued: OAuthTokenResponse,
  uploadNotBefore: string,
): ActiveAccountSessionState {
  return {
    schema_version: ACCOUNT_STATE_SCHEMA_VERSION,
    status: "active",
    account_id: issued.account_id,
    device_id: issued.device_id,
    device_generation: issued.device_generation,
    next_snapshot_sequence: issued.next_snapshot_sequence,
    next_usage_sequence: issued.next_usage_sequence,
    usage_sync_revision: issued.usage_sync_revision,
    usage_deleted_before: issued.usage_deleted_before,
    upload_not_before: uploadNotBefore,
    account: { account_id: issued.account_id, ...issued.account_session },
    device: {
      account_id: issued.account_id,
      device_id: issued.device_id,
      device_generation: issued.device_generation,
      ...issued.device_session,
    },
  };
}

function authResult(session: ActiveAccountSessionState) {
  return {
    schema_version: 1 as const,
    status: "signed_in" as const,
    account_id: session.account_id,
    device_id: session.device_id,
    device_generation: session.device_generation,
  };
}

type ParsedAuthArguments =
  | { ok: true; deviceAuth: boolean; format: "text" | "json"; pretty: boolean }
  | { ok: false; error: string };

function parseAuthArguments(
  args: readonly string[],
  allowDeviceAuth: boolean,
): ParsedAuthArguments {
  let values: { "device-auth"?: boolean; format?: string; pretty?: boolean };
  try {
    values = parseArgs({
      args: [...args],
      options: {
        "device-auth": { type: "boolean" },
        format: { type: "string" },
        pretty: { type: "boolean" },
      },
      strict: true,
      allowPositionals: false,
    }).values;
  } catch (error) {
    return { ok: false, error: cliParseError(error) };
  }
  if (!allowDeviceAuth && values["device-auth"]) {
    return { ok: false, error: "Unknown option: --device-auth" };
  }
  if (values.format !== undefined && values.format !== "text" && values.format !== "json") {
    return { ok: false, error: "Invalid --format value." };
  }
  return {
    ok: true,
    deviceAuth: values["device-auth"] ?? false,
    format: values.format ?? "text",
    pretty: values.pretty ?? false,
  };
}

function writeResult(
  output: CliOutput,
  parsed: Extract<ParsedAuthArguments, { ok: true }>,
  result: Record<string, unknown>,
): void {
  if (parsed.format === "json") {
    output.stdout(renderJson(result, parsed.pretty));
    return;
  }
  if (result.status === "signed_in") {
    output.stdout(`Signed in to Quota. Device: ${result.device_id as string}`);
  } else if (result.status === "logout_pending") {
    output.stdout("Signed out locally; server revocation is pending.");
  } else {
    output.stdout("Signed out of Quota.");
  }
}

function defaultDependencies(): AccountCommandDependencies {
  const platform = platformName(process.platform);
  return {
    client: new AccountClient(),
    store: new AccountStateStore(),
    now: () => new Date(),
    sleep: async (milliseconds) =>
      await new Promise((resolve) => setTimeout(resolve, milliseconds)),
    browserLogin: async () => await runBrowserAuthorization({ origin: QUOTA_ACCOUNT_ORIGIN }),
    deviceName: () => hostname(),
    platform,
  };
}

function platformName(platform: NodeJS.Platform): "macos" | "linux" | "windows" {
  if (platform === "darwin") return "macos";
  if (platform === "win32") return "windows";
  return "linux";
}

function sanitizeDeviceName(value: string): string {
  const sanitized = Array.from(value, (character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || code === 0x7f ? " " : character;
  })
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return sanitized.slice(0, 128) || "QuotaCLI device";
}

function reportAccountError(error: unknown, output: CliOutput, fallback: string): number {
  if (error instanceof AccountStateStoreError && error.code === "client_upgrade_required") {
    output.stderr(error.message);
  } else if (
    error instanceof AccountClientError &&
    ["access_denied", "expired_token", "cancelled"].includes(error.code)
  ) {
    output.stderr(error.message);
  } else {
    output.stderr(fallback);
  }
  return 1;
}

function usageError(message: string, output: CliOutput): number {
  output.stderr(`${message}\n\n${accountUsage()}`);
  return 2;
}

export function accountUsage(): string {
  return `Account commands:
  quotacli login [--device-auth] [--format text|json] [--pretty]
  quotacli logout [--format text|json] [--pretty]
  quotacli auth status [--format text|json] [--pretty]`;
}
