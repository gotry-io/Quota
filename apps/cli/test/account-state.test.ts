import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  ACCOUNT_STATE_SCHEMA_VERSION,
  AccountStateStore,
  type ActiveAccountSessionState,
  decodeSession,
  defaultAccountStateRoot,
} from "../src/account/state.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-account-state-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("AccountStateStore", () => {
  it("creates one stable random installation identity in owner-only state", async () => {
    const store = new AccountStateStore({ root: join(temporaryDirectory, "state") });
    const first = await store.loadOrCreateInstallation();
    const second = await store.loadOrCreateInstallation();

    expect(second).toEqual(first);
    expect(first.installation_id).toMatch(/^[0-9a-f-]{36}$/i);
    expect(JSON.parse(await readFile(store.installationPath, "utf8"))).toEqual(first);
    if (process.platform !== "win32") {
      expect((await stat(store.root)).mode & 0o777).toBe(0o700);
      expect((await stat(store.installationPath)).mode & 0o777).toBe(0o600);
    }
  });

  it("backfills the first and returning account but bounds a switched account at login", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    await store.loadOrCreateInstallation();

    expect(await store.uploadLowerBound("account_one", "2026-08-09T12:00:00Z")).toBe(
      "1970-01-01T00:00:00Z",
    );
    expect(await store.uploadLowerBound("account_two", "2026-08-10T12:00:00Z")).toBe(
      "2026-08-10T12:00:00Z",
    );
    expect(await store.uploadLowerBound("account_one", "2026-08-11T12:00:00Z")).toBe(
      "1970-01-01T00:00:00Z",
    );
  });

  it("persists matching account and device principals and advances sequence atomically", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    await store.saveActiveSession(activeSession());

    expect(await store.loadSession()).toEqual(activeSession());
    const next = await store.updateActiveSession((current) => ({
      ...current,
      next_snapshot_sequence: current.next_snapshot_sequence + 1,
    }));
    expect(next.next_snapshot_sequence).toBe(8);
    expect((await store.loadSession())?.status).toBe("active");
  });

  it("switches to logout_pending before network revocation and keeps installation identity", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    const installation = await store.loadOrCreateInstallation();
    await store.saveActiveSession(activeSession());

    expect(await store.beginLogout()).toEqual({
      schema_version: 1,
      status: "logout_pending",
      account_id: "account_test",
      device_id: "device_test",
      account_refresh_token: "account-refresh-token-synthetic",
      device_refresh_token: "device-refresh-token-synthetic",
    });
    expect((await store.loadSession())?.status).toBe("logout_pending");
    expect(await store.loadOrCreateInstallation()).toEqual(installation);

    await store.clearSession();
    await expect(store.loadSession()).resolves.toBeNull();
    await expect(store.loadOrCreateInstallation()).resolves.toEqual(installation);
  });

  it("fails closed on a newer schema before modifying the file", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    const contents = '{"schema_version":2,"status":"future"}\n';
    await writeFile(store.sessionPath, contents, { mode: 0o600 });

    await expect(store.beginLogout()).rejects.toMatchObject({ code: "client_upgrade_required" });
    expect(await readFile(store.sessionPath, "utf8")).toBe(contents);
  });

  it("rejects extra fields, mismatched account principals, and insecure paths", async () => {
    expect(() => decodeSession({ ...activeSession(), extra: true })).toThrow("invalid");
    expect(() =>
      decodeSession({
        ...activeSession(),
        account: { ...activeSession().account, account_id: "other" },
      }),
    ).toThrow("invalid");

    if (process.platform !== "win32") {
      const insecure = new AccountStateStore({ root: join(temporaryDirectory, "insecure") });
      await mkdir(insecure.root, { mode: 0o700 });
      await writeFile(insecure.sessionPath, JSON.stringify(activeSession()), { mode: 0o600 });
      await chmod(insecure.sessionPath, 0o640);
      await expect(insecure.loadSession()).rejects.toThrow("only by its owner");

      const target = join(temporaryDirectory, "target");
      const linked = join(temporaryDirectory, "linked");
      await mkdir(target, { mode: 0o700 });
      await symlink(target, linked);
      await expect(
        new AccountStateStore({ root: linked }).loadOrCreateInstallation(),
      ).rejects.toThrow("invalid");
    }
  });

  it("uses one XDG state root and rejects relative configuration", () => {
    expect(defaultAccountStateRoot({ XDG_CONFIG_HOME: "/xdg" }, "/home/test")).toBe(
      "/xdg/quotacli",
    );
    expect(defaultAccountStateRoot({}, "/home/test")).toBe("/home/test/.config/quotacli");
    expect(() => defaultAccountStateRoot({ XDG_CONFIG_HOME: "relative" }, "/home/test")).toThrow(
      "absolute",
    );
  });
});

function activeSession(): ActiveAccountSessionState {
  return {
    schema_version: ACCOUNT_STATE_SCHEMA_VERSION,
    status: "active",
    account_id: "account_test",
    device_id: "device_test",
    device_generation: 3,
    next_snapshot_sequence: 7,
    next_usage_sequence: 4,
    usage_sync_revision: 2,
    usage_deleted_before: "2026-08-09T12:00:00Z",
    upload_not_before: "2026-08-09T12:00:00Z",
    account: {
      account_id: "account_test",
      access_token: "account-access-token-synthetic",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "account-refresh-token-synthetic",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
    device: {
      account_id: "account_test",
      device_id: "device_test",
      device_generation: 3,
      access_token: "device-access-token-synthetic",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "device-refresh-token-synthetic",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
  };
}
