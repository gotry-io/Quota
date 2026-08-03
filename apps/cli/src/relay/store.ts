import type { Stats } from "node:fs";
import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { canonicalRelayUrl } from "./url.ts";

export interface RelayCredential {
  relay_url: string;
  instance_id: string;
  device_id: string;
  device_token: string;
  paired_at: string;
  last_sequence: number;
}

export interface RelayCredentialStoreOptions {
  path?: string;
}

export interface SaveRelayCredentialOptions {
  overwrite?: boolean;
}

export class RelayCredentialStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RelayCredentialStoreError";
  }
}

export class RelayCredentialStore {
  readonly path: string;

  constructor(options: RelayCredentialStoreOptions = {}) {
    this.path = options.path ?? defaultRelayCredentialPath();
    if (!isAbsolute(this.path)) {
      throw new RelayCredentialStoreError("The relay credential path must be absolute.");
    }
  }

  async load(): Promise<RelayCredential | null> {
    try {
      return await this.#load();
    } catch (error) {
      if (error instanceof RelayCredentialStoreError) {
        throw error;
      }
      throw new RelayCredentialStoreError("Could not read the relay credential file.");
    }
  }

  async #load(): Promise<RelayCredential | null> {
    const directory = await existingTarget(dirname(this.path));
    if (!directory) {
      return null;
    }
    if (!directory.isDirectory()) {
      throw new RelayCredentialStoreError("The relay credential directory is invalid.");
    }
    if (process.platform !== "win32" && (directory.mode & 0o077) !== 0) {
      throw new RelayCredentialStoreError(
        "The relay credential directory must be accessible only by its owner.",
      );
    }

    let handle: Awaited<ReturnType<typeof open>>;
    try {
      handle = await open(
        this.path,
        constants.O_RDONLY | (process.platform === "win32" ? 0 : constants.O_NOFOLLOW),
      );
    } catch (error) {
      if (isFileSystemError(error, "ENOENT")) {
        return null;
      }
      throw new RelayCredentialStoreError("Could not open the relay credential file.");
    }

    try {
      const metadata = await handle.stat();
      if (!metadata.isFile()) {
        throw new RelayCredentialStoreError("The relay credential path is not a regular file.");
      }
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
        throw new RelayCredentialStoreError(
          "The relay credential file must be readable only by its owner.",
        );
      }
      const contents = await handle.readFile("utf8");
      let value: unknown;
      try {
        value = JSON.parse(contents);
      } catch {
        throw new RelayCredentialStoreError("The relay credential file is invalid.");
      }
      return decodeRelayCredential(value);
    } finally {
      await handle.close();
    }
  }

  async save(credential: RelayCredential, options: SaveRelayCredentialOptions = {}): Promise<void> {
    try {
      await this.#save(credential, options);
    } catch (error) {
      if (error instanceof RelayCredentialStoreError) {
        throw error;
      }
      throw new RelayCredentialStoreError("Could not save the relay credential file.");
    }
  }

  async #save(credential: RelayCredential, options: SaveRelayCredentialOptions): Promise<void> {
    const validated = decodeRelayCredential(credential);
    const directory = dirname(this.path);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryMetadata = await existingTarget(directory);
    if (!directoryMetadata?.isDirectory()) {
      throw new RelayCredentialStoreError("The relay credential directory is invalid.");
    }
    if (process.platform !== "win32") {
      await chmod(directory, 0o700);
    }

    const existing = await existingTarget(this.path);
    if (existing && !options.overwrite) {
      throw new RelayCredentialStoreError("An relay credential already exists.");
    }
    if (existing && !existing.isFile()) {
      throw new RelayCredentialStoreError("The relay credential path is not a regular file.");
    }
    if (existing && process.platform !== "win32" && (existing.mode & 0o077) !== 0) {
      throw new RelayCredentialStoreError(
        "The relay credential file must be readable only by its owner.",
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
      throw new RelayCredentialStoreError("Could not save the relay credential file.");
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
      throw new RelayCredentialStoreError("The relay credential directory is invalid.");
    }
    if (process.platform !== "win32" && (directory.mode & 0o077) !== 0) {
      throw new RelayCredentialStoreError(
        "The relay credential directory must be accessible only by its owner.",
      );
    }
    try {
      await unlink(this.path);
    } catch (error) {
      if (!isFileSystemError(error, "ENOENT")) {
        throw new RelayCredentialStoreError("Could not delete the relay credential file.");
      }
    }
  }
}

export function defaultRelayCredentialPath(
  environment: NodeJS.ProcessEnv = process.env,
  homeDirectory = homedir(),
): string {
  const xdgConfigHome = environment.XDG_CONFIG_HOME;
  const configHome =
    xdgConfigHome && xdgConfigHome.length > 0 ? xdgConfigHome : join(homeDirectory, ".config");
  if (!isAbsolute(configHome)) {
    throw new RelayCredentialStoreError("XDG_CONFIG_HOME must be an absolute path.");
  }
  return join(configHome, "quotacli", "device.json");
}

export function decodeRelayCredential(value: unknown): RelayCredential {
  if (!isRecord(value) || !hasOnlyCredentialKeys(value)) {
    throw new RelayCredentialStoreError("The relay credential file is invalid.");
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
    !isCanonicalDateTime(paired_at) ||
    typeof last_sequence !== "number" ||
    !Number.isSafeInteger(last_sequence) ||
    last_sequence < -1
  ) {
    throw new RelayCredentialStoreError("The relay credential file is invalid.");
  }

  let canonicalUrl: string;
  try {
    canonicalUrl = canonicalRelayUrl(relay_url);
  } catch {
    throw new RelayCredentialStoreError("The relay credential file is invalid.");
  }
  if (canonicalUrl !== relay_url) {
    throw new RelayCredentialStoreError("The relay credential file is invalid.");
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
    throw new RelayCredentialStoreError("Could not inspect the relay credential path.");
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

function isCanonicalDateTime(value: string): boolean {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return false;
  const canonical = new Date(timestamp).toISOString();
  return value === canonical || value === canonical.replace(".000Z", "Z");
}

function isFileSystemError(error: unknown, code: string): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === code;
}
