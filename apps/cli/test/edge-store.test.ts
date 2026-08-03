import { chmod, mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  decodeEdgeCredential,
  defaultEdgeCredentialPath,
  type EdgeCredential,
  EdgeCredentialStore,
} from "../src/edge/store.ts";

const credential: EdgeCredential = {
  relay_url: "https://relay.example.com",
  instance_id: "relay_test",
  device_id: "device_test",
  device_token: "synthetic-device-token",
  paired_at: "2026-08-03T10:00:00Z",
  last_sequence: -1,
};

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quota-cli-edge-test-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("EdgeCredentialStore", () => {
  it("uses XDG_CONFIG_HOME with a home config fallback", () => {
    expect(defaultEdgeCredentialPath({ XDG_CONFIG_HOME: "/xdg" }, "/home/test")).toBe(
      "/xdg/quotacli/edge.json",
    );
    expect(defaultEdgeCredentialPath({}, "/home/test")).toBe(
      "/home/test/.config/quotacli/edge.json",
    );
    expect(() => defaultEdgeCredentialPath({ XDG_CONFIG_HOME: "relative" }, "/home/test")).toThrow(
      "absolute",
    );
  });

  it("atomically saves and strictly loads a user-only credential", async () => {
    const path = join(temporaryDirectory, "nested", "edge.json");
    const store = new EdgeCredentialStore({ path });
    await store.save(credential);

    expect(await store.load()).toEqual(credential);
    if (process.platform !== "win32") {
      expect((await stat(join(temporaryDirectory, "nested"))).mode & 0o777).toBe(0o700);
      expect((await stat(path)).mode & 0o777).toBe(0o600);
    }
    expect(await readdir(join(temporaryDirectory, "nested"))).toEqual(["edge.json"]);
  });

  it("refuses to overwrite by default and supports an atomic explicit replacement", async () => {
    const path = join(temporaryDirectory, "edge.json");
    const store = new EdgeCredentialStore({ path });
    await store.save(credential);

    await expect(store.save({ ...credential, last_sequence: 0 })).rejects.toThrow("already exists");
    expect(await store.load()).toEqual(credential);

    await store.save({ ...credential, last_sequence: 0 }, { overwrite: true });
    expect(await store.load()).toEqual({ ...credential, last_sequence: 0 });
    expect(await readdir(temporaryDirectory)).toEqual(["edge.json"]);
  });

  it("fails closed for group- or other-readable credentials on POSIX", async () => {
    if (process.platform === "win32") {
      return;
    }
    const path = join(temporaryDirectory, "edge.json");
    await writeFile(path, JSON.stringify(credential), { mode: 0o600 });
    await chmod(path, 0o640);

    await expect(new EdgeCredentialStore({ path }).load()).rejects.toThrow("only by its owner");
  });

  it("fails closed for a group- or other-accessible credential directory on POSIX", async () => {
    if (process.platform === "win32") {
      return;
    }
    const directory = join(temporaryDirectory, "insecure");
    const path = join(directory, "edge.json");
    const store = new EdgeCredentialStore({ path });
    await store.save(credential);
    await chmod(directory, 0o750);

    await expect(store.load()).rejects.toThrow("directory must be accessible only by its owner");
  });

  it("does not follow a credential directory symlink while saving on POSIX", async () => {
    if (process.platform === "win32") {
      return;
    }
    const target = join(temporaryDirectory, "target");
    const linkedDirectory = join(temporaryDirectory, "linked");
    await mkdir(target, { mode: 0o700 });
    await symlink(target, linkedDirectory);

    const store = new EdgeCredentialStore({ path: join(linkedDirectory, "edge.json") });
    await expect(store.save(credential)).rejects.toThrow("directory is invalid");
    expect(await readdir(target)).toEqual([]);
  });

  it("strictly rejects malformed, extra, and non-canonical fields", async () => {
    expect(() => decodeEdgeCredential({ ...credential, extra: true })).toThrow("invalid");
    expect(() => decodeEdgeCredential({ ...credential, last_sequence: -2 })).toThrow("invalid");
    expect(() =>
      decodeEdgeCredential({ ...credential, relay_url: "https://relay.example.com/" }),
    ).toThrow("invalid");
    expect(() => decodeEdgeCredential({ ...credential, paired_at: "yesterday" })).toThrow(
      "invalid",
    );
    expect(() =>
      decodeEdgeCredential({ ...credential, paired_at: "2026-02-31T10:00:00Z" }),
    ).toThrow("invalid");
    expect(() =>
      decodeEdgeCredential({ ...credential, paired_at: "2026-08-03T10:00:00+00:00" }),
    ).toThrow("invalid");

    const path = join(temporaryDirectory, "edge.json");
    await writeFile(path, "not-json synthetic-device-token", { mode: 0o600 });
    const error = await captureError(new EdgeCredentialStore({ path }).load());
    expect(error.message).toBe("The edge credential file is invalid.");
    expect(error.message).not.toContain("synthetic-device-token");
  });

  it("returns null when absent and deletes idempotently", async () => {
    const store = new EdgeCredentialStore({ path: join(temporaryDirectory, "edge.json") });
    await expect(store.load()).resolves.toBeNull();
    await store.save(credential);
    await store.delete();
    await store.delete();
    await expect(store.load()).resolves.toBeNull();
  });
});

async function captureError(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(Error);
    return error as Error;
  }
  throw new Error("Expected an error.");
}
