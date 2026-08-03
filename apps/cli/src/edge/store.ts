import { constants } from "node:fs";
import type { Stats } from "node:fs";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { canonicalRelayUrl } from "./url.ts";

export interface EdgeCredential {
  relay_url: string;
  instance_id: string;
  device_id: string;
  device_token: string;
  paired_at: string;
  last_sequence: number;
}

export interface EdgeCredentialStoreOptions {
  path?: string;
}

export interface SaveEdgeCredentialOptions {
  overwrite?: boolean;
}

export class EdgeCredentialStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EdgeCredentialStoreError";
  }
}

export class EdgeCredentialStore {
  readonly path: string;

  constructor(options: EdgeCredentialStoreOptions = {}) {
    this.path = options.path ?? defaultEdgeCredentialPath();
    if (!isAbsolute(this.path)) {
      throw new EdgeCredentialStoreError("The edge credential path must be absolute.");
    }
  }

  async load(): Promise<EdgeCredential | null> {
    try {
      return await this.#load();
    } catch (error) {
      if (error instanceof EdgeCredentialStoreError) {
        throw error;
      }
      throw new EdgeCredentialStoreError("Could not read the edge credential file.");
    }
  }

  async #load(): Promise<EdgeCredential | null> {
    const directory = await existingTarget(dirname(this.path));
    if (!directory) {
      return null;
    }
    if (!directory.isDirectory()) {
      throw new EdgeCredentialStoreError("The edge credential directory is invalid.");
    }
    if (process.platform !== "win32" && (directory.mode & 0o077) !== 0) {
      throw new EdgeCredentialStoreError(
        "The edge credential directory must be accessible only by its owner.",
      );
    }

    let handle;
    try {
      handle = await open(
        this.path,
        constants.O_RDONLY | (process.platform === "win32" ? 0 : constants.O_NOFOLLOW),
      );
    } catch (error) {
      if (isFileSystemError(error, "ENOENT")) {
        return null;
      }
      throw new EdgeCredentialStoreError("Could not open the edge credential file.");
    }

    try {
      const metadata = await handle.stat();
      if (!metadata.isFile()) {
        throw new EdgeCredentialStoreError("The edge credential path is not a regular file.");
      }
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
        throw new EdgeCredentialStoreError(
          "The edge credential file must be readable only by its owner.",
        );
      }
      const contents = await handle.readFile("utf8");
      let value: unknown;
      try {
        value = JSON.parse(contents);
      } catch {
        throw new EdgeCredentialStoreError("The edge credential file is invalid.");
      }
      return decodeEdgeCredential(value);
    } finally {
      await handle.close();
    }
  }

  async save(credential: EdgeCredential, options: SaveEdgeCredentialOptions = {}): Promise<void> {
    try {
      await this.#save(credential, options);
    } catch (error) {
      if (error instanceof EdgeCredentialStoreError) {
        throw error;
      }
      throw new EdgeCredentialStoreError("Could not save the edge credential file.");
    }
  }

  async #save(credential: EdgeCredential, options: SaveEdgeCredentialOptions): Promise<void> {
    const validated = decodeEdgeCredential(credential);
    const directory = dirname(this.path);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryMetadata = await existingTarget(directory);
    if (!directoryMetadata?.isDirectory()) {
      throw new EdgeCredentialStoreError("The edge credential directory is invalid.");
    }
    if (process.platform !== "win32") {
      await chmod(directory, 0o700);
    }

    const existing = await existingTarget(this.path);
    if (existing && !options.overwrite) {
      throw new EdgeCredentialStoreError("An edge credential already exists.");
    }
    if (existing && !existing.isFile()) {
      throw new EdgeCredentialStoreError("The edge credential path is not a regular file.");
    }
    if (existing && process.platform !== "win32" && (existing.mode & 0o077) !== 0) {
      throw new EdgeCredentialStoreError(
        "The edge credential file must be readable only by its owner.",
      );
    }

    const temporaryPath = join(
      directory,
      `.${basename(this.path)}.${process.pid}.${crypto.randomUUID()}.tmp`,
    );
    let temporaryExists = false;
    try {
      const handle = await open(temporaryPath, "wx", 0o600);
      temporaryExists = true;
      try {
        await handle.writeFile(`${JSON.stringify(validated)}\n`, "utf8");
        await handle.sync();
      } finally {
        await handle.close();
      }
      if (process.platform !== "win32") {
        await chmod(temporaryPath, 0o600);
      }
      await rename(temporaryPath, this.path);
      temporaryExists = false;
    } catch {
      throw new EdgeCredentialStoreError("Could not save the edge credential file.");
    } finally {
      if (temporaryExists) {
        await unlink(temporaryPath).catch(() => undefined);
      }
    }
  }

  async delete(): Promise<void> {
    const directory = await existingTarget(dirname(this.path));
    if (!directory) {
      return;
    }
    if (!directory.isDirectory()) {
      throw new EdgeCredentialStoreError("The edge credential directory is invalid.");
    }
    if (process.platform !== "win32" && (directory.mode & 0o077) !== 0) {
      throw new EdgeCredentialStoreError(
        "The edge credential directory must be accessible only by its owner.",
      );
    }
    try {
      await unlink(this.path);
    } catch (error) {
      if (!isFileSystemError(error, "ENOENT")) {
        throw new EdgeCredentialStoreError("Could not delete the edge credential file.");
      }
    }
  }
}

export function defaultEdgeCredentialPath(
  environment: NodeJS.ProcessEnv = process.env,
  homeDirectory = homedir(),
): string {
  const xdgConfigHome = environment.XDG_CONFIG_HOME;
  const configHome =
    xdgConfigHome && xdgConfigHome.length > 0 ? xdgConfigHome : join(homeDirectory, ".config");
  if (!isAbsolute(configHome)) {
    throw new EdgeCredentialStoreError("XDG_CONFIG_HOME must be an absolute path.");
  }
  return join(configHome, "quotacli", "edge.json");
}

export function decodeEdgeCredential(value: unknown): EdgeCredential {
  if (!isRecord(value) || !hasOnlyCredentialKeys(value)) {
    throw new EdgeCredentialStoreError("The edge credential file is invalid.");
  }
  const { relay_url, instance_id, device_id, device_token, paired_at, last_sequence } = value;
  if (
    typeof relay_url !== "string" ||
    typeof instance_id !== "string" ||
    instance_id.length === 0 ||
    instance_id.trim() !== instance_id ||
    typeof device_id !== "string" ||
    device_id.length === 0 ||
    device_id.trim() !== device_id ||
    typeof device_token !== "string" ||
    device_token.length === 0 ||
    device_token.trim() !== device_token ||
    typeof paired_at !== "string" ||
    !isOffsetDateTime(paired_at) ||
    typeof last_sequence !== "number" ||
    !Number.isSafeInteger(last_sequence) ||
    last_sequence < -1
  ) {
    throw new EdgeCredentialStoreError("The edge credential file is invalid.");
  }

  let canonicalUrl: string;
  try {
    canonicalUrl = canonicalRelayUrl(relay_url);
  } catch {
    throw new EdgeCredentialStoreError("The edge credential file is invalid.");
  }
  if (canonicalUrl !== relay_url) {
    throw new EdgeCredentialStoreError("The edge credential file is invalid.");
  }

  return {
    relay_url,
    instance_id,
    device_id,
    device_token,
    paired_at,
    last_sequence,
  };
}

async function existingTarget(path: string): Promise<Stats | null> {
  try {
    return await lstat(path);
  } catch (error) {
    if (isFileSystemError(error, "ENOENT")) {
      return null;
    }
    throw new EdgeCredentialStoreError("Could not inspect the edge credential path.");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyCredentialKeys(value: Record<string, unknown>): boolean {
  const expected = [
    "relay_url",
    "instance_id",
    "device_id",
    "device_token",
    "paired_at",
    "last_sequence",
  ];
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((key) => keys.includes(key));
}

function isOffsetDateTime(value: string): boolean {
  const match =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-](\d{2}):(\d{2}))$/.exec(
      value,
    );
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = Number(match[8] ?? 0);
  const offsetMinute = Number(match[9] ?? 0);
  if (
    year < 1 ||
    month < 1 ||
    month > 12 ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    offsetHour > 23 ||
    offsetMinute > 59
  ) {
    return false;
  }
  const calendar = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  return (
    calendar.getUTCFullYear() === year &&
    calendar.getUTCMonth() === month - 1 &&
    calendar.getUTCDate() === day &&
    Number.isFinite(Date.parse(value))
  );
}

function isFileSystemError(error: unknown, code: string): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === code;
}
