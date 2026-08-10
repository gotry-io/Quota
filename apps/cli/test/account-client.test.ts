import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AccountClient } from "../src/account/client.ts";
import { activeSessionWithFreshToken } from "../src/account/session.ts";
import { AccountStateStore, type ActiveAccountSessionState } from "../src/account/state.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-account-client-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("AccountClient", () => {
  it("uses the fixed managed origin, refuses redirects, and validates token responses", async () => {
    const fetch = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      expect(String(input)).toBe("https://quota.gotry.io/oauth/v2/token");
      expect(init?.redirect).toBe("error");
      expect(new Headers(init?.headers).has("Authorization")).toBe(false);
      return Response.json(loginResponse());
    });
    const client = new AccountClient({ fetch });
    await expect(
      client.exchangeToken({
        protocol_version: 2,
        grant_type: "authorization_code",
        client_id: "quotacli",
        code: "authorization-code-synthetic",
        code_verifier: "v".repeat(43),
        redirect_uri: "http://127.0.0.1:4242/callback",
        installation_id: "11111111-1111-4111-8111-111111111111",
        device_display_name: "Synthetic Device",
        platform: "macos",
      }),
    ).resolves.toEqual(loginResponse());

    expect(() => new AccountClient({ origin: "https://relay.example.com" })).toThrow(
      "managed service",
    );
    expect(() => new AccountClient({ origin: "http://127.0.0.1:8787" })).not.toThrow();
  });

  it("does not expose malformed response bodies or credentials in errors", async () => {
    const secret = "synthetic-secret-token";
    const client = new AccountClient({
      fetch: async () => new Response(`raw response ${secret}`, { status: 500 }),
    });
    const error = await captureError(client.revoke(secret));
    expect(error.message).toBe("The Quota request failed.");
    expect(error.message).not.toContain(secret);
  });

  it("rotates refresh tokens atomically and rejects a mismatched principal", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    await store.saveActiveSession(expiredSession());
    const refreshSession = vi.fn(async () => ({
      protocol_version: 2 as const,
      token_type: "Bearer" as const,
      token_audience: "device" as const,
      account_id: "other_account",
      device_id: "device_test",
      device_generation: 3,
      device_session: expiredSession().device,
    }));

    await expect(
      activeSessionWithFreshToken(
        store,
        { refreshSession },
        "device",
        new Date("2026-08-09T12:00:00Z"),
      ),
    ).rejects.toThrow("same account");
    expect(await store.loadSession()).toEqual(expiredSession());
  });
});

function loginResponse() {
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

function expiredSession(): ActiveAccountSessionState {
  return {
    schema_version: 1,
    status: "active",
    account_id: "account_test",
    device_id: "device_test",
    device_generation: 3,
    next_snapshot_sequence: 7,
    next_usage_sequence: 4,
    usage_sync_revision: 2,
    usage_deleted_before: null,
    upload_not_before: "1970-01-01T00:00:00Z",
    account: {
      account_id: "account_test",
      access_token: "account-expired-access-token",
      access_expires_at: "2026-08-09T11:00:00Z",
      refresh_token: "account-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
    device: {
      account_id: "account_test",
      device_id: "device_test",
      device_generation: 3,
      access_token: "device-expired-access-token",
      access_expires_at: "2026-08-09T11:00:00Z",
      refresh_token: "device-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
  };
}

async function captureError(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(Error);
    return error as Error;
  }
  throw new Error("Expected failure.");
}
