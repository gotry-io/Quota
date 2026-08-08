import { randomUUID } from "node:crypto";
import type { Stats } from "node:fs";
import { constants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  open,
  readFile,
  rename,
  rmdir,
  unlink,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import type { ProviderId } from "@gotry-io/quota-protocol";
import { configurableProviderIds, isConfigurableProviderId, PROVIDER_CATALOG } from "../catalog.ts";

export const PROVIDER_CONFIG_SCHEMA_VERSION = 1 as const;

/** Per-provider secret entry (api_key providers). */
export interface ProviderSecretEntry {
  api_key: string;
  base_url?: string;
}

export interface ProviderConfigFile {
  schema_version: typeof PROVIDER_CONFIG_SCHEMA_VERSION;
  providers: Partial<Record<ProviderId, ProviderSecretEntry>>;
}

export interface ProviderConfigStoreOptions {
  path?: string;
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
}

export class ProviderConfigStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProviderConfigStoreError";
  }
}

export function defaultProviderConfigPath(
  environment: Readonly<Record<string, string | undefined>> = process.env,
  homeDirectory = homedir(),
): string {
  const xdgConfigHome = environment.XDG_CONFIG_HOME;
  const configHome =
    xdgConfigHome && xdgConfigHome.length > 0 ? xdgConfigHome : join(homeDirectory, ".config");
  if (!isAbsolute(configHome)) {
    throw new ProviderConfigStoreError("XDG_CONFIG_HOME must be an absolute path.");
  }
  return join(configHome, "quotacli", "providers.json");
}

/**
 * Owner-only (`0600`) file for API-key provider secrets (catalog `config.kind === "api_key"`).
 * Path: `$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`.
 * Shared by QuotaCLI and QuotaBar; never store these keys in UserDefaults.
 */
export class ProviderConfigStore {
  readonly path: string;

  constructor(options: ProviderConfigStoreOptions = {}) {
    this.path =
      options.path ??
      defaultProviderConfigPath(options.environment ?? process.env, options.homeDirectory);
    if (!isAbsolute(this.path)) {
      throw new ProviderConfigStoreError("The provider config path must be absolute.");
    }
  }

  async load(): Promise<ProviderConfigFile> {
    try {
      return await this.#load();
    } catch (error) {
      if (error instanceof ProviderConfigStoreError) {
        throw error;
      }
      throw new ProviderConfigStoreError("Could not read the provider config file.");
    }
  }

  async #load(): Promise<ProviderConfigFile> {
    const directory = await existingTarget(dirname(this.path));
    if (!directory) {
      return emptyConfig();
    }
    if (!directory.isDirectory()) {
      throw new ProviderConfigStoreError("The provider config directory is invalid.");
    }
    if (process.platform !== "win32" && (directory.mode & 0o077) !== 0) {
      throw new ProviderConfigStoreError(
        "The provider config directory must be accessible only by its owner.",
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
        return emptyConfig();
      }
      throw new ProviderConfigStoreError("Could not open the provider config file.");
    }

    try {
      const metadata = await handle.stat();
      if (!metadata.isFile()) {
        throw new ProviderConfigStoreError("The provider config path is not a regular file.");
      }
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
        throw new ProviderConfigStoreError(
          "The provider config file must be readable only by its owner.",
        );
      }
      const contents = await handle.readFile("utf8");
      if (contents.trim() === "") {
        return emptyConfig();
      }
      let value: unknown;
      try {
        value = JSON.parse(contents);
      } catch {
        throw new ProviderConfigStoreError("The provider config file is invalid.");
      }
      return decodeProviderConfig(value);
    } finally {
      await handle.close();
    }
  }

  async #save(config: ProviderConfigFile): Promise<void> {
    const directory = dirname(this.path);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryMetadata = await existingTarget(directory);
    if (!directoryMetadata?.isDirectory()) {
      throw new ProviderConfigStoreError("The provider config directory is invalid.");
    }
    if (process.platform !== "win32") {
      await chmod(directory, 0o700);
    }

    const existing = await existingTarget(this.path);
    if (existing && !existing.isFile()) {
      throw new ProviderConfigStoreError("The provider config path is not a regular file.");
    }
    if (existing && process.platform !== "win32" && (existing.mode & 0o077) !== 0) {
      throw new ProviderConfigStoreError(
        "The provider config file must be readable only by its owner.",
      );
    }

    const temporaryPath = join(
      directory,
      `.${basename(this.path)}.${process.pid}.${randomUUID()}.tmp`,
    );
    let temporaryExists = false;
    try {
      const handle = await open(temporaryPath, "wx", 0o600);
      temporaryExists = true;
      try {
        await handle.writeFile(`${JSON.stringify(config)}\n`, "utf8");
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
      throw new ProviderConfigStoreError("Could not save the provider config file.");
    } finally {
      if (temporaryExists) {
        await unlink(temporaryPath).catch(() => undefined);
      }
    }
  }

  async get(provider: ProviderId): Promise<ProviderSecretEntry | undefined> {
    assertConfigurable(provider);
    const config = await this.load();
    return config.providers[provider];
  }

  async set(provider: ProviderId, entry: ProviderSecretEntry): Promise<void> {
    assertConfigurable(provider);
    const apiKey = entry.api_key.trim();
    if (!apiKey) {
      throw new ProviderConfigStoreError(
        `${PROVIDER_CATALOG[provider].displayName} API key must not be empty.`,
      );
    }
    if (entry.base_url?.trim() && PROVIDER_CATALOG[provider].config?.supportsBaseUrl !== true) {
      throw new ProviderConfigStoreError(
        `${PROVIDER_CATALOG[provider].displayName} does not support custom base URLs.`,
      );
    }
    await this.#withWriteLock(async () => {
      const config = await this.load();
      const next: ProviderSecretEntry = { api_key: apiKey };
      if (entry.base_url?.trim()) {
        next.base_url = entry.base_url.trim();
      }
      config.providers[provider] = next;
      await this.#save(config);
    });
  }

  async unset(provider: ProviderId): Promise<boolean> {
    assertConfigurable(provider);
    return await this.#withWriteLock(async () => {
      const config = await this.load();
      if (!config.providers[provider]) {
        return false;
      }
      delete config.providers[provider];
      if (Object.keys(config.providers).length === 0) {
        await this.deleteFile();
        return true;
      }
      await this.#save(config);
      return true;
    });
  }

  async listConfigured(): Promise<ProviderId[]> {
    const config = await this.load();
    return configurableProviderIds().filter((id) => Boolean(config.providers[id]?.api_key));
  }

  private async deleteFile(): Promise<void> {
    try {
      await unlink(this.path);
    } catch (error) {
      if (!isFileSystemError(error, "ENOENT")) {
        throw new ProviderConfigStoreError("Could not delete the provider config file.");
      }
    }
  }

  /** Cross-process mutex shared with QuotaBar's Swift ProviderConfigStore. */
  async #withWriteLock<T>(action: () => Promise<T>): Promise<T> {
    const lockPath = `${this.path}.lock`;
    const ownerPath = join(lockPath, "owner");
    const directory = dirname(this.path);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const deadline = Date.now() + 10_000;
    while (true) {
      try {
        await mkdir(lockPath, { mode: 0o700 });
        try {
          await writeFile(ownerPath, `${process.pid}\n`, {
            encoding: "utf8",
            flag: "wx",
            mode: 0o600,
          });
        } catch {
          await rmdir(lockPath).catch(() => undefined);
          throw new ProviderConfigStoreError("Could not initialize the provider config lock.");
        }
        break;
      } catch (error) {
        if (!isFileSystemError(error, "EEXIST")) {
          throw new ProviderConfigStoreError("Could not acquire the provider config lock.");
        }
        if (await removeStaleWriteLock(lockPath, ownerPath)) {
          continue;
        }
        if (Date.now() >= deadline) {
          throw new ProviderConfigStoreError("Could not acquire the provider config lock.");
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    }
    try {
      return await action();
    } finally {
      await unlink(ownerPath).catch(() => undefined);
      await rmdir(lockPath).catch(() => undefined);
    }
  }
}

async function removeStaleWriteLock(lockPath: string, ownerPath: string): Promise<boolean> {
  let stale = false;
  try {
    const owner = (await readFile(ownerPath, "utf8")).trim();
    const ownerPid = Number(owner);
    if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) {
      const metadata = await lstat(lockPath);
      stale = Date.now() - metadata.mtimeMs >= 1_000;
    } else {
      try {
        process.kill(ownerPid, 0);
      } catch (error) {
        stale = isFileSystemError(error, "ESRCH");
      }
    }
  } catch (error) {
    if (!isFileSystemError(error, "ENOENT")) {
      return false;
    }
    try {
      const metadata = await lstat(lockPath);
      stale = Date.now() - metadata.mtimeMs >= 1_000;
    } catch {
      return true;
    }
  }
  if (!stale) {
    return false;
  }
  await unlink(ownerPath).catch(() => undefined);
  try {
    await rmdir(lockPath);
    return true;
  } catch {
    return false;
  }
}

function assertConfigurable(provider: ProviderId): void {
  if (!isConfigurableProviderId(provider)) {
    throw new ProviderConfigStoreError(
      `Provider ${provider} does not support stored API key config.`,
    );
  }
}

export function decodeProviderConfig(value: unknown): ProviderConfigFile {
  if (!isRecord(value)) {
    throw new ProviderConfigStoreError("The provider config file is invalid.");
  }
  const schemaVersion = value.schema_version;
  if (schemaVersion !== PROVIDER_CONFIG_SCHEMA_VERSION) {
    throw new ProviderConfigStoreError("The provider config file is invalid.");
  }
  const providersRaw = value.providers;
  if (!isRecord(providersRaw)) {
    throw new ProviderConfigStoreError("The provider config file is invalid.");
  }

  const providers: ProviderConfigFile["providers"] = {};
  for (const [key, rawEntry] of Object.entries(providersRaw)) {
    if (!isConfigurableProviderId(key)) {
      throw new ProviderConfigStoreError("The provider config file is invalid.");
    }
    providers[key] = decodeSecretEntry(rawEntry);
  }

  return {
    schema_version: PROVIDER_CONFIG_SCHEMA_VERSION,
    providers,
  };
}

function decodeSecretEntry(value: unknown): ProviderSecretEntry {
  if (!isRecord(value)) {
    throw new ProviderConfigStoreError("The provider config file is invalid.");
  }
  const apiKey = value.api_key;
  if (typeof apiKey !== "string" || apiKey.trim() === "") {
    throw new ProviderConfigStoreError("The provider config file is invalid.");
  }
  const entry: ProviderSecretEntry = { api_key: apiKey.trim() };
  if (value.base_url !== undefined) {
    if (typeof value.base_url !== "string" || value.base_url.trim() === "") {
      throw new ProviderConfigStoreError("The provider config file is invalid.");
    }
    entry.base_url = value.base_url.trim();
  }
  for (const key of Object.keys(value)) {
    if (key !== "api_key" && key !== "base_url") {
      throw new ProviderConfigStoreError("The provider config file is invalid.");
    }
  }
  return entry;
}

function emptyConfig(): ProviderConfigFile {
  return { schema_version: PROVIDER_CONFIG_SCHEMA_VERSION, providers: {} };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function existingTarget(path: string): Promise<Stats | null> {
  try {
    return await lstat(path);
  } catch (error) {
    if (isFileSystemError(error, "ENOENT")) {
      return null;
    }
    throw error;
  }
}

function isFileSystemError(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: string }).code === code
  );
}
