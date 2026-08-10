import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  open,
  readFile,
  rename,
  rm,
  unlink,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { Rfc3339InstantSchema, SessionTokenSchema } from "@gotry-io/quota-protocol";
import { z } from "zod";

export const ACCOUNT_STATE_SCHEMA_VERSION = 1 as const;

export interface InstallationState {
  schema_version: typeof ACCOUNT_STATE_SCHEMA_VERSION;
  installation_id: string;
  account_bindings: Array<{ account_id: string; upload_not_before: string }>;
}

export interface StoredSessionToken {
  access_token: string;
  access_expires_at: string;
  refresh_token: string;
  refresh_expires_at: string;
}

export interface StoredAccountSessionToken extends StoredSessionToken {
  account_id: string;
}

export interface StoredDeviceSessionToken extends StoredSessionToken {
  account_id: string;
  device_id: string;
  device_generation: number;
}

export interface ActiveAccountSessionState {
  schema_version: typeof ACCOUNT_STATE_SCHEMA_VERSION;
  status: "active";
  account_id: string;
  device_id: string;
  device_generation: number;
  next_snapshot_sequence: number;
  next_usage_sequence: number;
  usage_sync_revision: number;
  usage_deleted_before: string | null;
  upload_not_before: string;
  account: StoredAccountSessionToken;
  device: StoredDeviceSessionToken;
}

export interface LogoutPendingSessionState {
  schema_version: typeof ACCOUNT_STATE_SCHEMA_VERSION;
  status: "logout_pending";
  account_id: string;
  device_id: string;
  account_refresh_token: string;
  device_refresh_token: string;
}

export type AccountSessionState = ActiveAccountSessionState | LogoutPendingSessionState;

const OpaqueIdSchema = z
  .string()
  .min(1)
  .max(128)
  .refine((value) => value.trim() === value);
const CanonicalInstantSchema = Rfc3339InstantSchema.refine(isCanonicalInstant);
const InstallationSchema = z
  .object({
    schema_version: z.literal(ACCOUNT_STATE_SCHEMA_VERSION),
    installation_id: z.uuid(),
    account_bindings: z
      .array(
        z
          .object({
            account_id: OpaqueIdSchema,
            upload_not_before: CanonicalInstantSchema,
          })
          .strict(),
      )
      .max(32),
  })
  .strict()
  .superRefine((value, context) => {
    if (
      new Set(value.account_bindings.map((entry) => entry.account_id)).size !==
      value.account_bindings.length
    ) {
      context.addIssue({ code: "custom", message: "Account bindings must be unique." });
    }
  });
const StoredAccountSessionTokenSchema = SessionTokenSchema.extend({
  account_id: OpaqueIdSchema,
}).strict();
const StoredDeviceSessionTokenSchema = SessionTokenSchema.extend({
  account_id: OpaqueIdSchema,
  device_id: OpaqueIdSchema,
  device_generation: z.number().int().positive().safe(),
}).strict();
const ActiveAccountSessionStateSchema = z
  .object({
    schema_version: z.literal(ACCOUNT_STATE_SCHEMA_VERSION),
    status: z.literal("active"),
    account_id: OpaqueIdSchema,
    device_id: OpaqueIdSchema,
    device_generation: z.number().int().positive().safe(),
    next_snapshot_sequence: z.number().int().nonnegative().safe(),
    next_usage_sequence: z.number().int().nonnegative().safe(),
    usage_sync_revision: z.number().int().nonnegative().safe(),
    usage_deleted_before: CanonicalInstantSchema.nullable(),
    upload_not_before: CanonicalInstantSchema,
    account: StoredAccountSessionTokenSchema,
    device: StoredDeviceSessionTokenSchema,
  })
  .strict()
  .superRefine((value, context) => {
    if (
      value.account.account_id !== value.account_id ||
      value.device.account_id !== value.account_id ||
      value.device.device_id !== value.device_id ||
      value.device.device_generation !== value.device_generation
    ) {
      context.addIssue({ code: "custom", message: "Stored principals must match the session." });
    }
  });
const LogoutPendingSessionStateSchema = z
  .object({
    schema_version: z.literal(ACCOUNT_STATE_SCHEMA_VERSION),
    status: z.literal("logout_pending"),
    account_id: OpaqueIdSchema,
    device_id: OpaqueIdSchema,
    account_refresh_token: SessionTokenSchema.shape.refresh_token,
    device_refresh_token: SessionTokenSchema.shape.refresh_token,
  })
  .strict();
const AccountSessionStateSchema = z.discriminatedUnion("status", [
  ActiveAccountSessionStateSchema,
  LogoutPendingSessionStateSchema,
]);

export class AccountStateStoreError extends Error {
  readonly code: "invalid_state" | "client_upgrade_required" | "unavailable";

  constructor(code: "invalid_state" | "client_upgrade_required" | "unavailable", message: string) {
    super(message);
    this.name = "AccountStateStoreError";
    this.code = code;
  }
}

export interface AccountStateStoreOptions {
  root?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  homeDirectory?: string;
}

export type AccountStateArtifact =
  | "usage-cache.json"
  | "usage-outbox.json"
  | "pricing-catalog.json";

export class AccountStateStore {
  readonly root: string;
  readonly installationPath: string;
  readonly sessionPath: string;

  constructor(options: AccountStateStoreOptions = {}) {
    this.root =
      options.root ??
      defaultAccountStateRoot(
        options.environment ?? process.env,
        options.homeDirectory ?? homedir(),
      );
    if (!isAbsolute(this.root)) {
      throw new AccountStateStoreError("invalid_state", "The Quota state path must be absolute.");
    }
    this.installationPath = join(this.root, "installation.json");
    this.sessionPath = join(this.root, "session.json");
  }

  async loadOrCreateInstallation(): Promise<InstallationState> {
    return await this.withLock(async () => {
      const existing = await readOwnerOnlyJson(this.installationPath);
      if (existing !== null) {
        return decodeInstallation(existing);
      }
      const installation = {
        schema_version: ACCOUNT_STATE_SCHEMA_VERSION,
        installation_id: randomUUID(),
        account_bindings: [],
      } satisfies InstallationState;
      await writeOwnerOnlyJson(this.installationPath, installation, false);
      return installation;
    });
  }

  async uploadLowerBound(accountId: string, loginAt: string): Promise<string> {
    if (!isOpaque(accountId) || !isCanonicalInstant(loginAt)) throw invalidState();
    return await this.withLock(async () => {
      const value = await readOwnerOnlyJson(this.installationPath);
      if (value === null) throw invalidState();
      const installation = decodeInstallation(value);
      const existing = installation.account_bindings.find(
        (entry) => entry.account_id === accountId,
      );
      if (existing) return existing.upload_not_before;
      const uploadNotBefore =
        installation.account_bindings.length === 0 ? "1970-01-01T00:00:00Z" : loginAt;
      if (installation.account_bindings.length >= 32) {
        throw new AccountStateStoreError(
          "invalid_state",
          "Too many Quota accounts have used this installation. Reset the local identity.",
        );
      }
      installation.account_bindings.push({
        account_id: accountId,
        upload_not_before: uploadNotBefore,
      });
      await writeOwnerOnlyJson(this.installationPath, installation, true);
      return uploadNotBefore;
    });
  }

  async loadSession(): Promise<AccountSessionState | null> {
    const value = await readOwnerOnlyJson(this.sessionPath);
    return value === null ? null : decodeSession(value);
  }

  async saveActiveSession(session: ActiveAccountSessionState): Promise<void> {
    await this.withLock(async () => {
      await writeOwnerOnlyJson(this.sessionPath, decodeSession(session), true);
    });
  }

  async beginLogout(): Promise<LogoutPendingSessionState | null> {
    return await this.withLock(async () => {
      const value = await readOwnerOnlyJson(this.sessionPath);
      if (value === null) {
        return null;
      }
      const session = decodeSession(value);
      if (session.status === "logout_pending") {
        return session;
      }
      const pending = {
        schema_version: ACCOUNT_STATE_SCHEMA_VERSION,
        status: "logout_pending",
        account_id: session.account_id,
        device_id: session.device_id,
        account_refresh_token: session.account.refresh_token,
        device_refresh_token: session.device.refresh_token,
      } satisfies LogoutPendingSessionState;
      await writeOwnerOnlyJson(this.sessionPath, pending, true);
      return pending;
    });
  }

  async updateActiveSession(
    update: (
      current: ActiveAccountSessionState,
    ) => ActiveAccountSessionState | Promise<ActiveAccountSessionState>,
  ): Promise<ActiveAccountSessionState> {
    return await this.withLock(async () => {
      const value = await readOwnerOnlyJson(this.sessionPath);
      if (value === null) {
        throw new AccountStateStoreError("invalid_state", "QuotaCLI is signed out.");
      }
      const current = decodeSession(value);
      if (current.status !== "active") {
        throw new AccountStateStoreError("invalid_state", "QuotaCLI logout is pending.");
      }
      const next = decodeSession(await update(current));
      if (next.status !== "active") {
        throw new AccountStateStoreError("invalid_state", "The Quota session update is invalid.");
      }
      await writeOwnerOnlyJson(this.sessionPath, next, true);
      return next;
    });
  }

  async clearSession(): Promise<void> {
    await this.withLock(async () => {
      await unlink(this.sessionPath).catch((error: unknown) => {
        if (!isFileSystemError(error, "ENOENT")) {
          throw error;
        }
      });
    });
  }

  async loadArtifact(name: AccountStateArtifact): Promise<unknown | null> {
    return await readOwnerOnlyJson(join(this.root, name));
  }

  async saveArtifact(name: AccountStateArtifact, value: unknown): Promise<void> {
    await this.withLock(async () => {
      await writeOwnerOnlyJson(join(this.root, name), value, true);
    });
  }

  async updateArtifact<T>(
    name: AccountStateArtifact,
    decode: (value: unknown | null) => T,
    update: (current: T) => T | Promise<T>,
  ): Promise<T> {
    return await this.withLock(async () => {
      const path = join(this.root, name);
      const next = await update(decode(await readOwnerOnlyJson(path)));
      await writeOwnerOnlyJson(path, next, true);
      return next;
    });
  }

  async withLock<T>(action: () => Promise<T>): Promise<T> {
    await ensureOwnerOnlyDirectory(this.root);
    const lockPath = join(this.root, "state.lock");
    const ownerPath = join(lockPath, "owner");
    const deadline = Date.now() + 10_000;
    while (true) {
      try {
        await mkdir(lockPath, { mode: 0o700 });
        await writeFile(ownerPath, `${process.pid}\n`, { flag: "wx", mode: 0o600 });
        break;
      } catch (error) {
        if (!isFileSystemError(error, "EEXIST")) {
          await rm(lockPath, { recursive: true, force: true }).catch(() => undefined);
          throw new AccountStateStoreError(
            "unavailable",
            "Could not acquire the Quota state lock.",
          );
        }
        if (await removeStaleLock(lockPath, ownerPath)) {
          continue;
        }
        if (Date.now() >= deadline) {
          throw new AccountStateStoreError(
            "unavailable",
            "Could not acquire the Quota state lock.",
          );
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    }
    try {
      return await action();
    } finally {
      await rm(lockPath, { recursive: true, force: true });
    }
  }
}

export function defaultAccountStateRoot(
  environment: Readonly<Record<string, string | undefined>> = process.env,
  homeDirectory = homedir(),
): string {
  const configured = environment.XDG_CONFIG_HOME;
  const configRoot =
    configured && configured.length > 0 ? configured : join(homeDirectory, ".config");
  if (!isAbsolute(configRoot)) {
    throw new AccountStateStoreError("invalid_state", "XDG_CONFIG_HOME must be an absolute path.");
  }
  return join(configRoot, "quotacli");
}

export function decodeInstallation(value: unknown): InstallationState {
  rejectNewerState(value);
  const parsed = InstallationSchema.safeParse(value);
  if (!parsed.success) throw invalidState();
  return parsed.data;
}

export function decodeSession(value: unknown): AccountSessionState {
  rejectNewerState(value);
  const parsed = AccountSessionStateSchema.safeParse(value);
  if (!parsed.success) throw invalidState();
  return parsed.data;
}

async function readOwnerOnlyJson(path: string): Promise<unknown | null> {
  const parent = await lstat(dirname(path)).catch((error: unknown) => {
    if (isFileSystemError(error, "ENOENT")) return null;
    throw error;
  });
  if (parent === null) return null;
  if (!parent.isDirectory() || parent.isSymbolicLink()) throw invalidState();
  assertOwnerOnly(parent.mode, "directory");
  let handle: Awaited<ReturnType<typeof open>>;
  try {
    handle = await open(
      path,
      constants.O_RDONLY | (process.platform === "win32" ? 0 : constants.O_NOFOLLOW),
    );
  } catch (error) {
    if (isFileSystemError(error, "ENOENT")) return null;
    throw invalidState();
  }
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile()) throw invalidState();
    assertOwnerOnly(metadata.mode, "file");
    try {
      return JSON.parse(await handle.readFile("utf8"));
    } catch {
      throw invalidState();
    }
  } finally {
    await handle.close();
  }
}

async function writeOwnerOnlyJson(path: string, value: unknown, replace: boolean): Promise<void> {
  await ensureOwnerOnlyDirectory(dirname(path));
  const current = await lstat(path).catch((error: unknown) => {
    if (isFileSystemError(error, "ENOENT")) return null;
    throw error;
  });
  if (current && (!current.isFile() || current.isSymbolicLink())) throw invalidState();
  if (current) assertOwnerOnly(current.mode, "file");
  if (current && !replace) throw invalidState();
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    const handle = await open(temporary, "wx", 0o600);
    try {
      await handle.writeFile(`${JSON.stringify(value)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (process.platform !== "win32") await chmod(temporary, 0o600);
    await rename(temporary, path);
  } finally {
    await unlink(temporary).catch(() => undefined);
  }
}

async function ensureOwnerOnlyDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const metadata = await lstat(path);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw invalidState();
  if (process.platform !== "win32") {
    await chmod(path, 0o700);
  }
}

async function removeStaleLock(lockPath: string, ownerPath: string): Promise<boolean> {
  try {
    const owner = Number((await readFile(ownerPath, "utf8")).trim());
    if (Number.isSafeInteger(owner) && owner > 0) {
      try {
        process.kill(owner, 0);
        return false;
      } catch (error) {
        if (!isFileSystemError(error, "ESRCH")) return false;
      }
    } else if (Date.now() - (await lstat(lockPath)).mtimeMs < 1_000) {
      return false;
    }
  } catch (error) {
    if (!isFileSystemError(error, "ENOENT")) return false;
    const metadata = await lstat(lockPath).catch(() => null);
    if (metadata && Date.now() - metadata.mtimeMs < 1_000) return false;
  }
  await rm(lockPath, { recursive: true, force: true });
  return true;
}

function rejectNewerState(value: unknown): void {
  if (
    typeof value === "object" &&
    value !== null &&
    "schema_version" in value &&
    typeof value.schema_version === "number" &&
    Number.isSafeInteger(value.schema_version) &&
    value.schema_version > ACCOUNT_STATE_SCHEMA_VERSION
  ) {
    throw new AccountStateStoreError(
      "client_upgrade_required",
      "This Quota state was written by a newer QuotaCLI. Upgrade before continuing.",
    );
  }
}

function isOpaque(value: unknown): value is string {
  return (
    typeof value === "string" && value.length >= 1 && value.length <= 128 && value.trim() === value
  );
}

function isCanonicalInstant(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return false;
  const canonical = new Date(timestamp).toISOString();
  return value === canonical || value === canonical.replace(".000Z", "Z");
}

function assertOwnerOnly(mode: number, kind: "directory" | "file"): void {
  if (process.platform !== "win32" && (mode & 0o077) !== 0) {
    throw new AccountStateStoreError(
      "invalid_state",
      `The Quota state ${kind} must be accessible only by its owner.`,
    );
  }
}

function invalidState(): AccountStateStoreError {
  return new AccountStateStoreError("invalid_state", "The local Quota state is invalid.");
}

function isFileSystemError(error: unknown, code: string): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === code;
}
