import { Database } from "bun:sqlite";
import type { RelayInfo } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRelayApp } from "../src/app.ts";
import { selfHostedRelayInfo } from "../src/config.ts";
import {
  bootstrapSelfHostedOwner,
  requireSelfHostedOwnerToken,
  SELF_HOSTED_OWNER_ID,
  SELF_HOSTED_OWNER_SESSION_EXPIRES_AT,
  SELF_HOSTED_OWNER_SESSION_ID,
} from "../src/self-hosted-bootstrap.ts";
import { sha256Hex } from "../src/security.ts";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

const firstOwnerToken = "synthetic-self-hosted-owner-token-0001";
const rotatedOwnerToken = "synthetic-self-hosted-owner-token-0002";

describe("self-hosted owner bootstrap", () => {
  it("rejects missing, weak, and surrounding-whitespace tokens without echoing them", () => {
    const invalidTokens = [
      undefined,
      "",
      " ".repeat(40),
      "x".repeat(31),
      ` ${"x".repeat(32)}`,
      `${"x".repeat(32)} `,
    ];

    for (const invalidToken of invalidTokens) {
      let error: unknown;
      try {
        requireSelfHostedOwnerToken(invalidToken);
      } catch (caught) {
        error = caught;
      }
      expect(error).toBeInstanceOf(Error);
      const message = (error as Error).message;
      expect(message).toContain("QUOTA_RELAY_OWNER_TOKEN");
      if (invalidToken) {
        expect(message).not.toContain(invalidToken);
      }
    }

    expect(requireSelfHostedOwnerToken("x".repeat(32))).toBe("x".repeat(32));
  });

  it("stores one hash-only scoped session, supports idempotent restart and rotates immediately", async () => {
    const directory = mkdtempSync(join(tmpdir(), "quota-relay-owner-bootstrap-test-"));
    const databasePath = join(directory, "relay.db");
    const state = new SQLiteRelayState(databasePath);
    await state.initialize();

    await bootstrapSelfHostedOwner(
      state,
      requireSelfHostedOwnerToken(firstOwnerToken),
      new Date("2026-08-03T01:00:00Z"),
    );
    const firstTokenHash = await sha256Hex(firstOwnerToken);
    expect(
      await state.getActiveAuthSessionByTokenHash(firstTokenHash, "2026-08-03T01:01:00Z"),
    ).toEqual({
      owner_id: SELF_HOSTED_OWNER_ID,
      scopes: ["quota:read", "device:manage"],
    });

    const mutator = new Database(databasePath, { strict: true });
    mutator
      .query(
        `UPDATE auth_sessions
         SET scopes_json = '[]', expires_at = '2026-08-03T01:30:00Z',
             revoked_at = '2026-08-03T01:15:00Z'
         WHERE id = ?1`,
      )
      .run(SELF_HOSTED_OWNER_SESSION_ID);
    mutator.close();

    await bootstrapSelfHostedOwner(
      state,
      requireSelfHostedOwnerToken(firstOwnerToken),
      new Date("2026-08-03T02:00:00Z"),
    );

    const database = new Database(databasePath, { readonly: true, strict: true });
    const row = database
      .query<
        {
          id: string;
          owner_id: string;
          token_hash: string;
          scopes_json: string;
          expires_at: string;
          revoked_at: string | null;
          created_at: string;
        },
        []
      >(
        `SELECT id, owner_id, token_hash, scopes_json, expires_at, revoked_at, created_at
         FROM auth_sessions`,
      )
      .get();
    expect(
      database.query<{ count: number }, []>("SELECT COUNT(*) AS count FROM auth_sessions").get()
        ?.count,
    ).toBe(1);
    expect(row).toEqual({
      id: SELF_HOSTED_OWNER_SESSION_ID,
      owner_id: SELF_HOSTED_OWNER_ID,
      token_hash: firstTokenHash,
      scopes_json: '["quota:read","device:manage"]',
      expires_at: SELF_HOSTED_OWNER_SESSION_EXPIRES_AT,
      revoked_at: null,
      created_at: "2026-08-03T01:00:00.000Z",
    });
    expect(row?.token_hash).not.toBe(firstOwnerToken);
    database.close();

    await bootstrapSelfHostedOwner(
      state,
      requireSelfHostedOwnerToken(rotatedOwnerToken),
      new Date("2026-08-03T03:00:00Z"),
    );
    const rotatedTokenHash = await sha256Hex(rotatedOwnerToken);
    expect(
      await state.getActiveAuthSessionByTokenHash(firstTokenHash, "2026-08-03T03:01:00Z"),
    ).toBeNull();
    expect(
      await state.getActiveAuthSessionByTokenHash(rotatedTokenHash, "2026-08-03T03:01:00Z"),
    ).toEqual({
      owner_id: SELF_HOSTED_OWNER_ID,
      scopes: ["quota:read", "device:manage"],
    });

    const app = createRelayApp({ state, relayInfo: selfHostedRelayInfo("self-hosted-test") });
    const oldCredentialResponse = await app.request("/api/v1/devices", {
      headers: { Authorization: `Bearer ${firstOwnerToken}` },
    });
    expect(oldCredentialResponse.status).toBe(401);
    const rotatedCredentialResponse = await app.request("/api/v1/devices", {
      headers: { Authorization: `Bearer ${rotatedOwnerToken}` },
    });
    expect(rotatedCredentialResponse.status).toBe(200);

    const discovery = await app.request("/.well-known/quotabar-relay");
    expect(discovery.status).toBe(200);
    expect((await discovery.json()) as RelayInfo).toEqual({
      instance_id: "self-hosted-test",
      mode: "self_hosted",
      version: "0.1.0",
      api_versions: [1],
      auth_methods: ["bearer"],
      capabilities: {
        realtime: false,
        persistent_snapshots: true,
        instant_device_revocation: true,
        history: false,
        multi_tenant: false,
      },
    });
    const databaseBytes = readFileSync(databasePath);
    expect(databaseBytes.includes(firstOwnerToken)).toBe(false);
    expect(databaseBytes.includes(rotatedOwnerToken)).toBe(false);
  });
});
