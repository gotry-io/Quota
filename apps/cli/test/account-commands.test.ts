import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AccountClientError } from "../src/account/client.ts";
import {
  type AccountCommandDependencies,
  runAuthCommand,
  runLoginCommand,
  runLogoutCommand,
} from "../src/account/commands.ts";
import { AccountStateStore } from "../src/account/state.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-account-command-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("account commands", () => {
  it("completes browser PKCE login and never prints issued credentials", async () => {
    const dependencies = makeDependencies();
    const capture = captureOutput();
    expect(await runLoginCommand(["--format", "json"], capture.output, dependencies)).toBe(0);

    const result = JSON.parse(capture.stdout.join(""));
    expect(result).toEqual({
      schema_version: 1,
      status: "signed_in",
      account_id: "account_test",
      device_id: "device_test",
      device_generation: 3,
    });
    expect(dependencies.client.exchangeToken).toHaveBeenCalledWith(
      expect.objectContaining({
        grant_type: "authorization_code",
        installation_id: expect.stringMatching(/^[0-9a-f-]{36}$/i),
        code_verifier: "v".repeat(43),
      }),
    );
    const output = [...capture.stdout, ...capture.stderr].join("\n");
    expect(output).not.toContain("synthetic-access-token");
    expect(output).not.toContain("synthetic-refresh-token");
    expect(await dependencies.store.loadSession()).toMatchObject({ status: "active" });
  });

  it("uses RFC 8628 interval and slow_down before saving the same account/device sessions", async () => {
    const dependencies = makeDependencies();
    dependencies.client.exchangeToken
      .mockRejectedValueOnce(new AccountClientError("authorization_pending", "pending"))
      .mockRejectedValueOnce(new AccountClientError("slow_down", "slow"))
      .mockResolvedValueOnce(tokenResponse());
    const capture = captureOutput();

    expect(
      await runLoginCommand(["--device-auth", "--format=json"], capture.output, dependencies),
    ).toBe(0);
    expect(dependencies.sleep).toHaveBeenNthCalledWith(1, 2_000);
    expect(dependencies.sleep).toHaveBeenNthCalledWith(2, 2_000);
    expect(dependencies.sleep).toHaveBeenNthCalledWith(3, 7_000);
    expect(capture.stderr.join("\n")).toContain("ABCD-EFGH");
    expect(capture.stdout.join("\n")).not.toContain("device-code-synthetic");
  });

  it("disables uploads locally before revoke and keeps a retryable pending state on failure", async () => {
    const dependencies = makeDependencies();
    await runLoginCommand(["--format=json"], captureOutput().output, dependencies);
    dependencies.client.revoke.mockRejectedValueOnce(new Error("network secret body"));
    const capture = captureOutput();

    expect(await runLogoutCommand(["--format=json"], capture.output, dependencies)).toBe(1);
    expect(await dependencies.store.loadSession()).toMatchObject({ status: "logout_pending" });
    expect(capture.stderr).toEqual([
      "QuotaCLI stopped uploads locally, but server logout is pending. Retry while online.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain("network secret body");

    dependencies.client.revoke.mockResolvedValue(undefined);
    expect(await runLogoutCommand(["--format=json"], captureOutput().output, dependencies)).toBe(0);
    expect(await dependencies.store.loadSession()).toBeNull();
  });

  it("reports signed-out and client-upgrade states without creating identity", async () => {
    const dependencies = makeDependencies();
    const capture = captureOutput();
    expect(await runAuthCommand(["status", "--format=json"], capture.output, dependencies)).toBe(0);
    expect(JSON.parse(capture.stdout[0] ?? "")).toEqual({
      schema_version: 1,
      status: "signed_out",
    });

    await dependencies.store.loadOrCreateInstallation();
    await readFile(dependencies.store.installationPath, "utf8");
  });
});

function makeDependencies(): AccountCommandDependencies & {
  client: {
    beginDeviceAuthorization: ReturnType<typeof vi.fn>;
    exchangeToken: ReturnType<typeof vi.fn>;
    revoke: ReturnType<typeof vi.fn>;
  };
  sleep: ReturnType<typeof vi.fn>;
} {
  let now = new Date("2026-08-09T12:00:00Z");
  return {
    store: new AccountStateStore({ root: temporaryDirectory }),
    client: {
      beginDeviceAuthorization: vi.fn(async () => ({
        protocol_version: 2 as const,
        device_code: "device-code-synthetic",
        user_code: "ABCD-EFGH",
        verification_uri: "https://quota.gotry.io/activate",
        verification_uri_complete: "https://quota.gotry.io/activate?user_code=ABCD-EFGH",
        expires_in: 600,
        interval: 2,
      })),
      exchangeToken: vi.fn(async () => tokenResponse()),
      revoke: vi.fn(async () => undefined),
    },
    now: () => now,
    sleep: vi.fn(async (milliseconds: number) => {
      now = new Date(now.getTime() + milliseconds);
    }),
    browserLogin: vi.fn(async () => ({
      code: "authorization-code-synthetic",
      code_verifier: "v".repeat(43),
      redirect_uri: "http://127.0.0.1:4242/callback",
    })),
    deviceName: () => "Synthetic Device",
    platform: "macos",
  };
}

function tokenResponse() {
  return {
    protocol_version: 2 as const,
    token_type: "Bearer" as const,
    account_id: "account_test",
    device_id: "device_test",
    device_generation: 3,
    next_snapshot_sequence: 7,
    next_usage_sequence: 4,
    usage_deleted_before: null,
    usage_sync_revision: 2,
    account_session: {
      access_token: "account-synthetic-access-token",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "account-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
    device_session: {
      access_token: "device-synthetic-access-token",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "device-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
  };
}

function captureOutput() {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return {
    stdout,
    stderr,
    output: {
      stdout: (message: string) => stdout.push(message),
      stderr: (message: string) => stderr.push(message),
    },
  };
}
