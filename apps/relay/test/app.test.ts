import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  type DeviceAuthorizationResponse,
  type OAuthTokenResponse,
} from "@gotry-io/quota-protocol";
import type { DevicePrincipal, UsageSubmission } from "@gotry-io/relay-core";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { createWebAccountAuth, type WebAccountAuth } from "../src/account/better-auth.ts";
import { D1EncryptedAuthStorage } from "../src/account/better-auth-storage.ts";
import { AccountService } from "../src/account/service.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
    }
  }
}

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const now = new Date("2026-08-10T00:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("managed Relay on real Workers and D1", () => {
  it("floors RFC3339 deletion watermarks with SQLite before accepting Usage", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_watermark', 'subject_watermark', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, deleted_before,
             created_at, last_login_at
           ) VALUES ('device_watermark', 'account_watermark', 'installation_watermark', 2,
             '2026-08-10T10:05:00Z', ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_test",
      family_id: "family_test",
      account_id: "account_watermark",
      device_id: "device_watermark",
      generation: 2,
      scopes: ["usage:write:self"],
    };
    const submission: UsageSubmission = {
      protocol_version: 5,
      submission_id: "submission_old",
      device_id: "device_watermark",
      generation: 2,
      sequence: 0,
      parser_revision: "parser_test",
      aggregation_timezone: "UTC",
      coverage: {
        agent: "codex",
        start_at: "2026-08-10T09:00:00.000Z",
        end_at: "2026-08-10T10:00:00.000Z",
        status: "complete",
      },
      rows: [],
    };
    const usage = new D1UsageState(env.DB);
    expect(await usage.recordUsage(principal, submission, now.toISOString())).toEqual({
      outcome: "deleted_range",
    });
    expect(
      await usage.recordUsage(
        principal,
        {
          ...submission,
          submission_id: "submission_current",
          coverage: {
            ...submission.coverage,
            start_at: "2026-08-10T10:00:00.000Z",
            end_at: "2026-08-10T11:00:00.000Z",
          },
        },
        now.toISOString(),
      ),
    ).toMatchObject({ outcome: "accepted", next_sequence: 1 });
  });

  it("decides one coverage verdict over every window the range spans", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_test', 'subject_test', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_test', 'account_test', 'installation_test', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const state = new D1UsageState(env.DB);
    const query = {
      start_at: "2026-06-01T00:00:00Z",
      end_at: "2026-08-03T00:00:00Z",
      limit: 1_000,
    };

    // A range no window covers is not silently complete.
    expect((await state.queryAccountUsage("account_test", query)).coverage).toBe("none");

    const window = (start: string, end: string, status: string, submission: string) =>
      env.DB.prepare(
        `INSERT INTO usage_coverage (
             device_id, agent, start_at, end_at, status, parser_revision, submission_id, accepted_at
           ) VALUES ('device_test', 'codex', ?1, ?2, ?3, 'parser_test', ?4, ?5)`,
      ).bind(start, end, status, submission, now.toISOString());

    await env.DB.batch([
      window("2026-06-01T00:00:00Z", "2026-07-02T00:00:00Z", "complete", "submission_1"),
      window("2026-07-02T00:00:00Z", "2026-08-02T00:00:00Z", "complete", "submission_2"),
    ]);
    expect((await state.queryAccountUsage("account_test", query)).coverage).toBe("complete");

    // One incompletely scanned window anywhere in the range decides the whole answer.
    await env.DB.batch([
      window("2026-08-02T00:00:00Z", "2026-08-03T00:00:00Z", "partial", "submission_3"),
    ]);
    expect((await state.queryAccountUsage("account_test", query)).coverage).toBe("partial");

    // A window outside the asked-for range does not.
    expect(
      (
        await state.queryAccountUsage("account_test", {
          ...query,
          end_at: "2026-08-02T00:00:00Z",
        })
      ).coverage,
    ).toBe("complete");
  });

  it("stores unknown as an explicit opaque model", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_legacy', 'subject_legacy', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_legacy', 'account_legacy', 'installation_legacy', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_legacy",
      family_id: "family_legacy",
      account_id: "account_legacy",
      device_id: "device_legacy",
      generation: 1,
      scopes: ["usage:write:self"],
    };
    const submission = unknownModelSubmission();
    const usage = new D1UsageState(env.DB);

    expect(await usage.recordUsage(principal, submission, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 1,
    });
    expect(await usage.recordUsage(principal, submission, now.toISOString())).toMatchObject({
      outcome: "duplicate",
      next_sequence: 1,
    });
    expect(
      await env.DB.prepare(
        "SELECT model FROM usage_hourly WHERE device_id = 'device_legacy'",
      ).first("model"),
    ).toBe("unknown");
  });

  it("merges explicit partial Usage without deleting facts and replaces it later", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_partial', 'subject_partial', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_partial', 'account_partial', 'installation_partial', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_partial",
      family_id: "family_partial",
      account_id: "account_partial",
      device_id: "device_partial",
      generation: 1,
      scopes: ["usage:write:self"],
    };
    const usage = new D1UsageState(env.DB);
    const first = usageSubmission(
      "partial_first",
      0,
      "2026-08-10T10:00:00Z",
      "2026-08-10T14:00:00Z",
      [usageFact("gpt-5.5[1m]", "2026-08-10T10:00:00Z")],
    );
    expect(await usage.recordUsage(principal, first, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 1,
    });
    const partial = {
      ...usageSubmission("partial_merge", 1, "2026-08-10T11:00:00Z", "2026-08-10T13:00:00Z", [
        usageFact("openrouter-3o[1m]", "2026-08-10T11:00:00Z"),
      ]),
      write_mode: "merge_partial" as const,
      coverage: {
        ...usageSubmission("partial_merge", 1, "2026-08-10T11:00:00Z", "2026-08-10T13:00:00Z", [])
          .coverage,
        status: "partial" as const,
      },
    };
    expect(await usage.recordUsage(principal, partial, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 2,
    });
    let result = await usage.queryAccountUsage("account_partial", {
      device_id: "device_partial",
      limit: 100,
    });
    expect(result.rows.map((row) => row.model)).toEqual(["gpt-5.5[1m]", "openrouter-3o[1m]"]);
    expect(result.coverage).toBe("partial");

    const complete = {
      ...partial,
      submission_id: "partial_complete",
      sequence: 2,
      write_mode: undefined,
      coverage: { ...partial.coverage, status: "complete" as const },
      rows: [],
    };
    expect(await usage.recordUsage(principal, complete, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 3,
    });
    result = await usage.queryAccountUsage("account_partial", {
      device_id: "device_partial",
      limit: 100,
    });
    expect(result.rows.map((row) => row.model)).toEqual(["gpt-5.5[1m]"]);
    expect(result.coverage).toBe("complete");

    const exactPartial = {
      ...partial,
      submission_id: "partial_exact",
      sequence: 3,
      rows: [usageFact("exact-partial", "2026-08-10T11:00:00Z")],
    };
    expect(await usage.recordUsage(principal, exactPartial, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 4,
    });
    result = await usage.queryAccountUsage("account_partial", {
      device_id: "device_partial",
      limit: 100,
    });
    expect(result.coverage).toBe("partial");
  });

  it("keeps multipart Usage invisible until all parts commit", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_multipart', 'subject_multipart', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_multipart', 'account_multipart', 'installation_multipart', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
    ]);
    const principal: DevicePrincipal = {
      kind: "device",
      session_id: "session_multipart",
      family_id: "family_multipart",
      account_id: "account_multipart",
      device_id: "device_multipart",
      generation: 1,
      scopes: ["usage:write:self"],
    };
    const usage = new D1UsageState(env.DB);
    const common = {
      protocol_version: 5 as const,
      device_id: "device_multipart",
      generation: 1,
      parser_revision: "parser_multipart",
      aggregation_timezone: "UTC",
      coverage: {
        agent: "codex" as const,
        start_at: "2026-08-10T12:00:00Z",
        end_at: "2026-08-10T13:00:00Z",
        status: "complete" as const,
      },
    };
    const partRows = Array.from({ length: 256 }, (_, index) =>
      usageFact(`model-${index}`, "2026-08-10T12:00:00Z"),
    );
    const part0: UsageSubmission = {
      ...common,
      submission_id: "multipart_0",
      sequence: 0,
      rows: partRows.slice(0, 128),
      multipart: { batch_id: "multipart_batch", part_index: 0, part_count: 2 },
    };
    const part1: UsageSubmission = {
      ...common,
      submission_id: "multipart_1",
      sequence: 1,
      rows: partRows.slice(128),
      multipart: { batch_id: "multipart_batch", part_index: 1, part_count: 2 },
    };
    expect(await usage.recordUsage(principal, part0, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 1,
    });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_hourly WHERE device_id = 'device_multipart'",
      ).first("count"),
    ).toBe(0);
    const finalResults = await Promise.all(
      Array.from({ length: 4 }, () => usage.recordUsage(principal, part1, now.toISOString())),
    );
    expect(finalResults.some((result) => result.outcome === "accepted")).toBe(true);
    expect(
      finalResults.every(
        (result) =>
          (result.outcome === "accepted" || result.outcome === "duplicate") &&
          result.next_sequence === 2,
      ),
    ).toBe(true);
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_hourly WHERE device_id = 'device_multipart'",
      ).first("count"),
    ).toBe(256);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_submission_parts").first("count"),
    ).toBe(0);
    expect(await usage.recordUsage(principal, part1, now.toISOString())).toMatchObject({
      outcome: "duplicate",
    });

    const conflictPart0: UsageSubmission = {
      ...part0,
      submission_id: "multipart_conflict_0",
      sequence: 2,
      rows: [usageFact("duplicate-model", "2026-08-10T12:00:00Z")],
      multipart: { batch_id: "multipart_conflict", part_index: 0, part_count: 2 },
    };
    const conflictPart1: UsageSubmission = {
      ...part1,
      submission_id: "multipart_conflict_1",
      sequence: 3,
      rows: [usageFact("duplicate-model", "2026-08-10T12:00:00Z")],
      multipart: { batch_id: "multipart_conflict", part_index: 1, part_count: 2 },
    };
    expect(await usage.recordUsage(principal, conflictPart0, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 3,
    });
    const rejectedResults = await Promise.all(
      Array.from({ length: 4 }, () =>
        usage.recordUsage(principal, conflictPart1, now.toISOString()),
      ),
    );
    expect(rejectedResults).toHaveLength(4);
    for (const result of rejectedResults) {
      expect(result).toMatchObject({
        outcome: "rejected",
        rejection_reason: "duplicate_fact_identity",
        next_sequence: 4,
      });
    }
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_hourly WHERE device_id = 'device_multipart'",
      ).first("count"),
    ).toBe(256);
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_submission_parts WHERE device_id = 'device_multipart' AND batch_id = 'multipart_conflict'",
      ).first("count"),
    ).toBe(0);
    expect(await usage.recordUsage(principal, conflictPart1, now.toISOString())).toMatchObject({
      outcome: "rejected",
      rejection_reason: "duplicate_fact_identity",
      next_sequence: 4,
    });

    const partialCommon = {
      ...common,
      write_mode: "merge_partial" as const,
      coverage: {
        ...common.coverage,
        status: "partial" as const,
      },
    };
    const partialConflictPart0: UsageSubmission = {
      ...partialCommon,
      submission_id: "multipart_partial_conflict_0",
      sequence: 4,
      rows: [usageFact("partial-duplicate-model", "2026-08-10T12:00:00Z")],
      multipart: {
        batch_id: "multipart_partial_conflict",
        part_index: 0,
        part_count: 2,
      },
    };
    const partialConflictPart1: UsageSubmission = {
      ...partialCommon,
      submission_id: "multipart_partial_conflict_1",
      sequence: 5,
      rows: [usageFact("partial-duplicate-model", "2026-08-10T12:00:00Z")],
      multipart: {
        batch_id: "multipart_partial_conflict",
        part_index: 1,
        part_count: 2,
      },
    };
    expect(
      await usage.recordUsage(principal, partialConflictPart0, now.toISOString()),
    ).toMatchObject({
      outcome: "accepted",
      next_sequence: 5,
    });
    expect(
      await usage.recordUsage(principal, partialConflictPart1, now.toISOString()),
    ).toMatchObject({
      outcome: "rejected",
      rejection_reason: "duplicate_fact_identity",
      next_sequence: 6,
    });
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_hourly WHERE device_id = 'device_multipart'",
      ).first("count"),
    ).toBe(256);
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM usage_submission_parts WHERE device_id = 'device_multipart' AND batch_id = 'multipart_partial_conflict'",
      ).first("count"),
    ).toBe(0);
    expect(
      await usage.recordUsage(principal, partialConflictPart1, now.toISOString()),
    ).toMatchObject({
      outcome: "rejected",
      rejection_reason: "duplicate_fact_identity",
      next_sequence: 6,
    });

    const afterConflict: UsageSubmission = {
      ...common,
      submission_id: "after_multipart_conflict",
      sequence: 6,
      coverage: {
        ...common.coverage,
        start_at: "2026-08-10T13:00:00Z",
        end_at: "2026-08-10T14:00:00Z",
      },
      rows: [usageFact("after-conflict", "2026-08-10T13:00:00Z")],
    };
    expect(await usage.recordUsage(principal, afterConflict, now.toISOString())).toMatchObject({
      outcome: "accepted",
      next_sequence: 7,
    });
  });

  it("serves every managed provider and agent from the one summary contract", async () => {
    const quotaSnapshot = (provider: "codex" | "cursor", fingerprint: string) =>
      JSON.stringify({
        provider,
        account: { fingerprint, fingerprint_scope: "global" },
        windows: [],
        status: "available",
        observed_at: now.toISOString(),
      });
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_agents', 'subject_agents', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_agents', 'account_agents', 'installation_agents', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageFactInsert("codex", "openai_direct", "gpt-5.6-sol"),
      usageFactInsert("grok", "xai_direct", "grok-4.5"),
      usageFactInsert("cursor", "openai_direct", "cursor-small"),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, sequence, captured_at, observed_at,
             snapshot_json, updated_at
           ) VALUES ('device_agents', ?1, ?2, 0, ?3, ?3, ?4, ?3)`,
      ).bind(
        "codex",
        "codex_fingerprint",
        now.toISOString(),
        quotaSnapshot("codex", "codex_fingerprint"),
      ),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, sequence, captured_at, observed_at,
             snapshot_json, updated_at
           ) VALUES ('device_agents', ?1, ?2, 0, ?3, ?3, ?4, ?3)`,
      ).bind(
        "cursor",
        "cursor_fingerprint",
        now.toISOString(),
        quotaSnapshot("cursor", "cursor_fingerprint"),
      ),
    ]);

    const usageState = new D1UsageState(env.DB);
    const filtered = await usageState.queryAccountUsage("account_agents", {
      agents: ["codex", "claude_code"],
      limit: 100,
    });
    const all = await usageState.queryAccountUsage("account_agents", {
      agents: ["codex", "claude_code", "grok", "opencode", "pi", "cursor"],
      limit: 100,
    });

    expect(filtered.rows.map((row) => row.agent)).toEqual(["codex"]);
    expect(all.rows.map((row) => row.agent)).toEqual(["codex", "cursor", "grok"]);

    const accountState = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "account_agents", name: "Quota Tester" },
        session: {
          id: "web_agents",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state: accountState,
      usageState,
      accountService: new AccountService(accountState, hasher, secret),
      webAuth,
      hasher,
      now: () => now,
    });
    const summary = (await (
      await app.request("https://quota.gotry.io/api/v5/account/summary?usage_agents=all")
    ).json()) as {
      protocol_version: number;
      quota: Array<{ snapshot: { provider: string } }>;
      usage: { totals: { requests: number } };
    };

    expect(summary).toMatchObject({ protocol_version: 5, usage: { totals: { requests: 3 } } });
    expect(summary.quota.map((observation) => observation.snapshot.provider)).toEqual([
      "codex",
      "cursor",
    ]);
    // The retired data routes are gone rather than kept answering an older shape, and they say
    // so as the one thing a caller on them can do: a version this deployment no longer serves
    // cannot be retried back into existence.
    const retired = await app.request(
      "https://quota.gotry.io/api/v3/account/summary?usage_agents=all",
    );
    expect(retired.status).toBe(404);
    expect(await retired.json()).toMatchObject({ error: { code: "client_upgrade_required" } });

    // A version this deployment does serve, spelled wrong, is a wrong path and stays one, so a
    // routing mistake of our own cannot hide behind an upgrade prompt.
    const wrong = await app.request("https://quota.gotry.io/api/v2/account/snapshots");
    expect(wrong.status).toBe(404);
    expect(await wrong.json()).toMatchObject({ error: { code: "not_found" } });
    const mistyped = await app.request("https://quota.gotry.io/api/v5/account/sumary");
    expect(await mistyped.json()).toMatchObject({ error: { code: "not_found" } });
  });

  it("answers an unchanged Account read from its validator instead of folding Usage again", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_etag', 'subject_etag', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at, last_seen_at
         ) VALUES ('device_etag', 'account_etag', 'installation_etag', 1, ?1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageFactInsertAt("device_etag", "2026-08-10T00:00:00Z", "2026-08-10"),
    ]);
    const usageState = new D1UsageState(env.DB);
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState,
      accountService: new AccountService(state, hasher, secret),
      webAuth: webSessionFor("account_etag"),
      hasher,
      now: () => now,
    });

    const summaryPath = "https://quota.gotry.io/api/v5/account/summary?usage_agents=all";
    const first = await app.request(summaryPath);
    expect(first.status).toBe(200);
    // `no-cache` is what makes the second request conditional at all: the browser may keep the
    // body as long as it revalidates before showing it.
    expect(first.headers.get("Cache-Control")).toBe("private, no-cache");
    const etag = first.headers.get("ETag");
    expect(etag).toMatch(/^"[0-9a-f]{64}"$/);

    const unchanged = await app.request(summaryPath, { headers: { "If-None-Match": etag ?? "" } });
    expect(unchanged.status).toBe(304);
    expect(unchanged.headers.get("ETag")).toBe(etag);
    expect(await unchanged.text()).toBe("");

    // Two routes answer the same query string with different bodies, and a different range is a
    // different answer, so neither may reuse the other's validator.
    const usage = await app.request(
      "https://quota.gotry.io/api/v5/account/usage/summary?usage_agents=all",
    );
    expect(usage.status).toBe(200);
    expect(usage.headers.get("ETag")).not.toBe(etag);
    const narrowed = await app.request(`${summaryPath}&from=2026-08-10&to=2026-08-10`);
    expect(narrowed.headers.get("ETag")).not.toBe(etag);

    // A new observation is a new answer even though no Usage fact moved.
    await env.DB.prepare(
      `INSERT INTO quota_snapshots (
         device_id, provider, account_fingerprint, sequence, captured_at, observed_at,
         snapshot_json, updated_at
       ) VALUES ('device_etag', 'codex', 'fingerprint_etag', 0, ?1, ?1, ?2, ?1)`,
    )
      .bind(now.toISOString(), JSON.stringify(quotaSnapshotJson()))
      .run();
    const afterUpload = await app.request(summaryPath, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(afterUpload.status).toBe(200);
    expect(afterUpload.headers.get("ETag")).not.toBe(etag);

    // A query key this route does not serve is still refused rather than validated.
    const bogus = await app.request(`${summaryPath}&nonsense=1`, {
      headers: { "If-None-Match": etag ?? "" },
    });
    expect(bogus.status).toBe(400);
    expect(bogus.headers.get("ETag")).toBeNull();
  });

  it("reports every billing channel it stores without an opt-in", async () => {
    const channelFact = (channel: string, channelSource: string, model: string) =>
      usageFactInsert("opencode", channel, model, {
        deviceID: "device_channels",
        channelSource,
        timezone: "UTC",
      });
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_channels', 'subject_channels', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_channels', 'account_channels', 'installation_channels', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      channelFact("moonshot_direct", "explicit", "k2p5"),
      channelFact("deepseek_direct", "explicit", "deepseek-v4-flash"),
      // Already unknown, so a narrowed row must fold into this group instead of
      // producing a second `unknown` provider.
      channelFact("unknown", "unknown", "big-pickle"),
    ]);
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "account_channels", name: "Quota Tester" },
        session: {
          id: "web_channels",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth,
      hasher,
      now: () => now,
    });
    const providersFor = async (query: string) => {
      const response = await app.request(`https://quota.gotry.io${query}`);
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        usage: { agents?: Array<{ providers: Array<{ provider: string }> }> };
      };
      return (body.usage.agents ?? []).flatMap((agent) =>
        agent.providers.map(({ provider }) => provider),
      );
    };

    expect(await providersFor("/api/v5/account/summary?usage_agents=all")).toEqual([
      "deepseek",
      "moonshot",
      "unknown",
    ]);
    // The retired opt-in is not a query key any more.
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v5/account/summary?usage_agents=all&usage_channels=1",
        )
      ).status,
    ).toBe(400);
  });

  it("serves the current pricing and model catalogs", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth: createWebAccountAuth({
        database: env.DB,
        githubClientId: "github-client",
        githubClientSecret: "github-secret",
        githubSubjectKey: secret,
        authSecret: secret,
        origin: "https://quota.gotry.io",
      }),
      hasher,
      now: () => now,
    });

    const pricing = (await (
      await app.request("https://quota.gotry.io/api/v2/pricing/catalog?usage_agents=all")
    ).json()) as { entries: Array<{ billing_channel: string }> };
    const invalid = await app.request(
      "https://quota.gotry.io/api/v2/pricing/catalog?usage_agents=codex",
    );

    expect(pricing.entries.some((entry) => entry.billing_channel === "xai_direct")).toBe(true);
    expect(invalid.status).toBe(400);

    const modelCatalog = await app.request("https://quota.gotry.io/api/v2/model/catalog");
    expect(modelCatalog.status).toBe(200);
    expect(modelCatalog.headers.get("cache-control")).toBe("public, max-age=300, must-revalidate");
    const modelETag = modelCatalog.headers.get("etag");
    expect(modelETag).toBeTruthy();
    expect((await modelCatalog.json()) as { revision: string }).toMatchObject({
      revision: expect.any(String),
    });
    const modelNotModified = await app.request("https://quota.gotry.io/api/v2/model/catalog", {
      headers: { "If-None-Match": modelETag ?? "" },
    });
    expect(modelNotModified.status).toBe(304);
    expect(
      (await app.request("https://quota.gotry.io/api/v2/model/catalog?unexpected=1")).status,
    ).toBe(400);
  });

  it("serves retained account history with client groups", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_history', 'account_history', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_history', 'account_history', 'installation_history', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      usageFactInsertAt("device_history", "2025-01-01T00:00:00Z", "2025-01-01"),
      usageFactInsertAt("device_history", "2026-08-09T00:00:00Z", "2026-08-09"),
    ]);
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "account_history", name: "Quota Tester" },
        session: {
          id: "web_history",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth,
      hasher,
      now: () => now,
    });

    const current = (await (
      await app.request("https://quota.gotry.io/api/v5/account/summary?usage_agents=all")
    ).json()) as {
      usage: {
        range: { from: string; to: string };
        totals: { requests: number };
        breakdowns: Array<{ dimension: string }>;
        agents?: unknown;
      };
    };
    const structured = (await (
      await app.request("https://quota.gotry.io/api/v5/account/summary?usage_agents=all")
    ).json()) as {
      usage: {
        agents: Array<{
          agent: string;
          totals: { messages: number };
          providers: Array<{ provider: string; models: Array<{ model: string }> }>;
        }>;
      };
    };

    expect(current.usage).toMatchObject({
      range: { from: "2025-01-01", to: "2026-08-09" },
      totals: { requests: 2 },
    });
    // Client groups are part of the contract, not something a caller asks for.
    expect(current.usage.agents).toMatchObject([
      { agent: "codex", providers: [{ provider: "openai" }] },
    ]);
    expect(structured.usage.agents).toMatchObject([
      {
        agent: "codex",
        totals: { messages: 2 },
        providers: [{ provider: "openai", models: [{ model: "gpt-5.6-sol" }] }],
      },
    ]);
    expect(current.usage.breakdowns.some(({ dimension }) => dimension === "usage_date")).toBe(true);
    expect(current.usage.breakdowns.some(({ dimension }) => dimension === "bucket_start_utc")).toBe(
      false,
    );
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v5/account/summary?usage_agents=all&from=2025-01-01&to=2026-08-10",
        )
      ).status,
    ).toBe(200);
  });

  it("marks high-cardinality summaries as truncated", async () => {
    const models = JSON.stringify(Array.from({ length: 1_001 }, (_, index) => index));
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_cardinality', 'subject_cardinality', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_cardinality', 'account_cardinality', 'installation_cardinality', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO usage_hourly (
           device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
           agent, billing_channel, channel_source, model, context_bucket,
           service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
           cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
           output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
           source_cost_microusd, source_cost_covered_requests
         )
         SELECT 'device_cardinality', '2026-08-09T00:00:00Z', '2026-08-09', 0, 'UTC',
                'codex', 'openai_direct', 'agent_default', 'model-' || value, 'le_128k',
                'unknown', 'unknown', 'unknown', 10, 0, 0, 0, 0, 2, 0, 1, 0, 0, '1', 1
         FROM json_each(?1)`,
      ).bind(models),
    ]);
    const state = new D1AccountState(env.DB);
    const usageState = new D1UsageState(env.DB);
    const hasher = new SecretHasher(secret);
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "account_cardinality", name: "Quota Tester" },
        session: {
          id: "web_cardinality",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState,
      accountService: new AccountService(state, hasher, secret),
      webAuth,
      hasher,
      now: () => now,
    });

    const summary = (await (
      await app.request("https://quota.gotry.io/api/v5/account/summary?usage_agents=all")
    ).json()) as {
      usage: { breakdowns_truncated?: boolean; cost: { unpriced_truncated?: boolean } };
    };
    expect(summary.usage.breakdowns_truncated).toBe(true);
    expect(summary.usage.cost.unpriced_truncated).toBe(true);

    const optedInResponse = await app.request(
      "https://quota.gotry.io/api/v5/account/summary?usage_agents=all",
    );
    const optedIn = (await optedInResponse.json()) as {
      usage: { model_catalog_revision?: string };
    };
    expect(optedInResponse.status).toBe(200);
    expect(optedIn.usage.model_catalog_revision).toEqual(expect.any(String));
    expect(
      (await app.request("https://quota.gotry.io/api/v5/account/summary?model_catalog=0")).status,
    ).toBe(400);
    expect(
      (
        await app.request(
          "https://quota.gotry.io/api/v5/account/usage/summary?usage_agents=all&from=2026-08-09&to=2026-08-09",
        )
      ).status,
    ).toBe(200);
  });

  it("stores Better Auth sessions encrypted behind hashed keys", async () => {
    const storage = new D1EncryptedAuthStorage(env.DB, secret);
    await storage.set("raw-session-token", JSON.stringify({ token: "raw-session-token" }), 60);

    const row = await env.DB.prepare(
      "SELECT key_hash, value_ciphertext FROM auth_session_store",
    ).first<{ key_hash: string; value_ciphertext: string }>();
    expect(row?.key_hash).not.toContain("raw-session-token");
    expect(row?.value_ciphertext).not.toContain("raw-session-token");
    expect(await storage.get("raw-session-token")).toContain("raw-session-token");

    const expiredKeyHash = await new SecretHasher(secret).hash(
      "better-auth-storage",
      "expired-session-token",
    );
    await env.DB.prepare(
      "INSERT INTO auth_session_store (key_hash, value_ciphertext, expires_at) VALUES (?1, 'expired', ?2)",
    )
      .bind(expiredKeyHash, "2026-08-09T00:00:00.000Z")
      .run();
    expect(await storage.getAndDelete("expired-session-token")).toBeNull();
    await env.DB.prepare(
      "INSERT INTO auth_session_store (key_hash, value_ciphertext, expires_at) VALUES ('expired', 'expired', ?1)",
    )
      .bind("2026-08-09T00:00:00.000Z")
      .run();
    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM auth_session_store WHERE key_hash = 'expired'",
      ).first("count"),
    ).toBe(0);
  });

  it("answers an account whose stored reading this build cannot read", async () => {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_unreadable', 'subject_unreadable', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_unreadable', 'account_unreadable', 'installation_unreadable', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      // A row a retired build wrote, still carrying the fields this contract removed.
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, sequence,
             captured_at, observed_at, snapshot_json, updated_at
           ) VALUES ('device_unreadable', 'codex', 'fingerprint', 1, ?1, ?1, ?2, ?1)`,
      ).bind(
        now.toISOString(),
        JSON.stringify({
          provider: "codex",
          account: { fingerprint: "fingerprint", fingerprint_scope: "global" },
          windows: [],
          source: "chatgpt_usage_api",
          status: "available",
          observed_at: now.toISOString(),
          valid_until: now.toISOString(),
        }),
      ),
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, sequence,
             captured_at, observed_at, snapshot_json, updated_at
           ) VALUES ('device_unreadable', 'cursor', 'fingerprint', 1, ?1, ?1, ?2, ?1)`,
      ).bind(
        now.toISOString(),
        JSON.stringify({
          provider: "cursor",
          account: { fingerprint: "fingerprint", fingerprint_scope: "global" },
          windows: [],
          status: "available",
          observed_at: now.toISOString(),
        }),
      ),
    ]);

    const stored = await new D1AccountState(env.DB).listLatestSnapshots("account_unreadable");

    // The reading it can read is answered; the one it cannot is dropped, not raised.
    expect(stored.map((observation) => observation.snapshot.provider)).toEqual(["cursor"]);
  });

  it("no longer stores anything an unauthenticated reader could have asked for", async () => {
    const columns = await env.DB.prepare("PRAGMA table_info(accounts)").all<{ name: string }>();
    const names = columns.results.map((column) => column.name);
    expect(names).not.toContain("public_profile_enabled");
    expect(names).not.toContain("public_profile_slug");
    const indexes = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'accounts'",
    ).all<{ name: string }>();
    expect(indexes.results.map((index) => index.name)).not.toContain(
      "accounts_public_profile_slug",
    );
  });

  it("keeps a sleeping device's reading and deletes one nothing will read again", async () => {
    const snapshot = (provider: string, observedAt: string) =>
      env.DB.prepare(
        `INSERT INTO quota_snapshots (
             device_id, provider, account_fingerprint, sequence,
             captured_at, observed_at, snapshot_json, updated_at
           ) VALUES ('device_retention', ?1, 'fingerprint', 1, ?2, ?2, '{}', ?3)`,
      ).bind(provider, observedAt, now.toISOString());
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_retention', 'subject_retention', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
             id, account_id, installation_id_hash, generation, created_at, last_login_at
           ) VALUES ('device_retention', 'account_retention', 'installation_retention', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      // A Mac that has been closed for two days: still the account's only reading of it.
      snapshot("codex", "2026-08-08T00:00:00Z"),
      // A provider this device stopped collecting long enough ago that nothing reads it.
      snapshot("cursor", "2026-08-01T00:00:00Z"),
    ]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));

    const remaining = await env.DB.prepare(
      "SELECT provider FROM quota_snapshots WHERE device_id = 'device_retention' ORDER BY provider",
    ).all<{ provider: string }>();
    expect(remaining.results.map((row) => row.provider)).toEqual(["codex"]);
  });

  it("keeps a Usage receipt only while a client could still be retrying it", async () => {
    const receipt = (submissionID: string, sequence: number, acceptedAt: string) =>
      env.DB.prepare(
        `INSERT INTO usage_submissions (
           device_id, submission_id, generation, sequence, request_digest,
           usage_sync_revision, agent, start_at, end_at, accepted_at
         ) VALUES ('device_receipts', ?1, 1, ?2, 'digest', 1, 'codex', ?3, ?3, ?3)`,
      ).bind(submissionID, sequence, acceptedAt);
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, identity_subject, created_at, updated_at) VALUES ('account_receipts', 'subject_receipts', ?1, ?1)",
      ).bind(now.toISOString()),
      env.DB.prepare(
        `INSERT INTO devices (
           id, account_id, installation_id_hash, generation, created_at, last_login_at
         ) VALUES ('device_receipts', 'account_receipts', 'installation_receipts', 1, ?1, ?1)`,
      ).bind(now.toISOString()),
      // Yesterday's upload: an outbox entry stuck behind a bad network is still this one.
      receipt("submission_recent", 1, "2026-08-09T00:00:00.000Z"),
      // A month old: the device's own sequence has moved on, and no client reuses that ID.
      receipt("submission_ancient", 0, "2026-07-10T00:00:00.000Z"),
    ]);

    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));

    const kept = await env.DB.prepare(
      "SELECT submission_id FROM usage_submissions WHERE device_id = 'device_receipts'",
    ).all<{ submission_id: string }>();
    expect(kept.results.map((row) => row.submission_id)).toEqual(["submission_recent"]);
  });

  it("expires one rate-limit window without resetting that subject's live one", async () => {
    const state = new D1AccountState(env.DB);
    const counter = (startedAt: string, expiresAt: string) =>
      env.DB.prepare(
        `INSERT INTO rate_limit_counters (key_hash, window_started_at, window_expires_at, request_count)
         VALUES ('subject_hash', ?1, ?2, 5)`,
      ).bind(startedAt, expiresAt);
    await env.DB.batch([
      counter("2026-08-09T23:00:00.000Z", "2026-08-09T23:10:00.000Z"),
      counter("2026-08-10T00:00:00.000Z", "2026-08-10T00:10:00.000Z"),
    ]);

    // Consuming the live window also collects expired rows; the live counter must survive, or
    // an exhausted subject buys a fresh allowance by making one more request.
    const result = await state.consumeRateLimit({
      key_hash: "subject_hash",
      window_started_at: "2026-08-10T00:00:00.000Z",
      window_expires_at: "2026-08-10T00:10:00.000Z",
      checked_at: now.toISOString(),
      limit: 10,
    });
    expect(result.allowed).toBe(true);
    const exhausted = await state.consumeRateLimit({
      key_hash: "subject_hash",
      window_started_at: "2026-08-10T00:00:00.000Z",
      window_expires_at: "2026-08-10T00:10:00.000Z",
      checked_at: now.toISOString(),
      limit: 6,
    });
    expect(exhausted.allowed).toBe(false);
    const rows = await env.DB.prepare(
      "SELECT window_started_at FROM rate_limit_counters ORDER BY window_started_at",
    ).all<{ window_started_at: string }>();
    expect(rows.results.map((row) => row.window_started_at)).toEqual(["2026-08-10T00:00:00.000Z"]);
  });

  it("uses Better Auth's standard GitHub redirect and stores no provider token", async () => {
    const auth = createWebAccountAuth({
      database: env.DB,
      githubClientId: "github-client",
      githubClientSecret: "github-secret",
      githubSubjectKey: secret,
      authSecret: secret,
      origin: "https://quota.gotry.io",
    });
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth: auth,
      hasher,
      now: () => now,
    });
    const response = await app.request("https://quota.gotry.io/api/auth/v2/sign-in/social", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://quota.gotry.io",
        "cf-connecting-ip": "203.0.113.10",
      },
      body: JSON.stringify({ provider: "github", callbackURL: "/app" }),
    });
    const body = (await response.json()) as { url?: string };
    expect(body.url).toContain("github.com/login/oauth/authorize");
    expect(body.url).toContain("scope=");
    expect(response.headers.get("set-cookie")).toContain("quota");
    expect(response.headers.get("cache-control")).toBe("no-store");
    const nativeResponse = await auth.beginGitHubSignIn(
      new Headers({ Origin: "https://quota.gotry.io" }),
      "https://quota.gotry.io/oauth/v2/complete?login_token=synthetic",
    );
    expect(nativeResponse.status).toBe(302);
    expect(nativeResponse.headers.get("location")).toContain("github.com/login/oauth/authorize");
    expect(nativeResponse.headers.get("set-cookie")).toContain("quota");
    expect(nativeResponse.headers.get("cache-control")).toBe("no-store");
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM auth_identities").first("count"),
    ).toBe(0);
  });

  it("completes browser PKCE through a Better Auth Web principal and issues device tokens", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    const service = new AccountService(state, hasher, secret);
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('identity_subject', 'identity_subject', 'Quota Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    let callbackURL = "";
    let sessionCreatedAt = now;
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async (_headers, callback) => {
        callbackURL = callback;
        return Response.redirect("https://github.com/login/oauth/authorize", 302);
      },
      getSession: async () => ({
        user: { id: "identity_subject", name: "Quota Tester" },
        session: {
          id: "web_session",
          createdAt: sessionCreatedAt,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: service,
      webAuth,
      hasher,
      now: () => now,
    });
    const decisionBody = JSON.stringify({
      protocol_version: 2,
      user_code: "ABCD-EFGH",
      decision: "approve",
    });
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: decisionBody,
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: decisionBody,
        })
      ).status,
    ).toBe(404);
    sessionCreatedAt = new Date(now.getTime() - 10 * 60_000 - 1);
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Origin: "https://quota.gotry.io",
            "Sec-Fetch-Site": "same-origin",
          },
          body: decisionBody,
        })
      ).status,
    ).toBe(403);
    sessionCreatedAt = now;

    const verifier = "a".repeat(43);
    const challengeBuffer = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(verifier),
    );
    const challenge = btoa(String.fromCharCode(...new Uint8Array(challengeBuffer)))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replace(/=+$/, "");
    const authorize = new URL("https://quota.gotry.io/oauth/v2/authorize");
    authorize.search = new URLSearchParams({
      response_type: "code",
      client_id: "quotacli",
      redirect_uri: "http://127.0.0.1:43210/callback",
      state: "client-state-123456789",
      code_challenge: challenge,
      code_challenge_method: "S256",
    }).toString();
    expect((await app.request(authorize)).status).toBe(302);

    const complete = await app.request(callbackURL);
    expect(complete.status).toBe(302);
    const code = new URL(complete.headers.get("location") ?? "invalid:").searchParams.get("code");
    expect(code).toBeTruthy();

    const exchanged = await app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        grant_type: "authorization_code",
        client_id: "quotacli",
        code,
        code_verifier: verifier,
        redirect_uri: "http://127.0.0.1:43210/callback",
        installation_id: "4a7f950d-89ea-4f64-a7c1-b4aeb46a67f8",
        device_display_name: "Test Mac",
        platform: "macos",
      }),
    });
    expect(exchanged.status).toBe(200);
    const tokens = (await exchanged.json()) as OAuthTokenResponse;
    expect(tokens.account_id).toBe("identity_subject");
    expect(tokens.device_generation).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);

    const oldAccessHash = await hasher.hash("device-access", tokens.device_session.access_token);
    expect(await state.authorizeDeviceSession(oldAccessHash, now.toISOString())).toMatchObject({
      device_id: tokens.device_id,
      generation: 1,
    });
    expect(
      (
        await app.request("https://quota.gotry.io/api/v2/device/profile", {
          method: "PUT",
          headers: {
            Authorization: `Bearer ${tokens.device_session.access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            protocol_version: 2,
            display_name: "Kyle's Mac mini",
            platform: "macos",
          }),
        })
      ).status,
    ).toBe(200);
    expect(
      await env.DB.prepare("SELECT display_name FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("display_name"),
    ).toBe("Kyle's Mac mini");
    expect(
      (
        await app.request("https://quota.gotry.io/oauth/v2/revoke", {
          method: "POST",
          headers: { Authorization: `Bearer ${tokens.device_session.refresh_token}` },
        })
      ).status,
    ).toBe(204);
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeDeviceSession(oldAccessHash, now.toISOString())).toBeNull();

    const deletedAt = new Date(now.getTime() + 1_000).toISOString();
    expect(
      await state.deleteDeviceData(tokens.account_id, tokens.device_id, deletedAt),
    ).toMatchObject({ device_id: tokens.device_id, generation: 2 });
    await env.DB.prepare("UPDATE devices SET signed_out_at = NULL, deleted_at = NULL WHERE id = ?1")
      .bind(tokens.device_id)
      .run();
    expect(await state.authorizeDeviceSession(oldAccessHash, deletedAt)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 1)).toBeNull();
    expect(await state.getDeviceSyncControl(tokens.device_id, 2)).toMatchObject({ generation: 2 });

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare(
      "UPDATE login_grants SET redirect_uri = 'https://attacker.invalid/callback' WHERE completed_at IS NULL",
    ).run();
    const unsafeRedirect = await app.request(callbackURL);
    expect(unsafeRedirect.status).toBe(400);
    expect(unsafeRedirect.headers.get("location")).toBeNull();
    expect(
      await env.DB.prepare(
        "SELECT COUNT(*) AS count FROM login_grants WHERE completed_at IS NOT NULL AND redirect_uri = 'https://attacker.invalid/callback'",
      ).first("count"),
    ).toBe(0);

    expect((await app.request(authorize)).status).toBe(302);
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(tokens.account_id).run();
    expect((await app.request(callbackURL)).status).toBe(401);
    expect(
      (
        await app.request("https://quota.gotry.io/api/v2/account/devices", {
          headers: { Origin: "https://quota.gotry.io" },
        })
      ).status,
    ).toBe(401);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts WHERE id = ?1")
        .bind(tokens.account_id)
        .first("count"),
    ).toBe(0);
  });

  it("completes the headless device authorization grant", async () => {
    const state = new D1AccountState(env.DB);
    const hasher = new SecretHasher(secret);
    let checkedAt = now;
    await env.DB.prepare(
      `INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at)
       VALUES ('device_account', 'device_account', 'Device Tester', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    const webAuth: WebAccountAuth = {
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 302 }),
      getSession: async () => ({
        user: { id: "device_account", name: "Device Tester" },
        session: {
          id: "device_web_session",
          createdAt: now,
          expiresAt: new Date(now.getTime() + 60_000),
        },
      }),
    };
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webAuth,
      hasher,
      now: () => checkedAt,
    });

    const started = await app.request("https://quota.gotry.io/oauth/v2/device/code", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocol_version: 2,
        client_id: "quotacli",
        installation_id: "dd4e60c6-fd44-4ac4-ad1f-28f2eeb52ca1",
        device_display_name: "Headless Linux",
        platform: "linux",
      }),
    });
    expect(started.status).toBe(201);
    const grant = (await started.json()) as DeviceAuthorizationResponse;
    expect(grant.verification_uri).toBe("https://quota.gotry.io/activate");
    expect(grant.verification_uri_complete).toContain(encodeURIComponent(grant.user_code));

    const tokenBody = JSON.stringify({
      protocol_version: 2,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      client_id: "quotacli",
      device_code: grant.device_code,
    });
    const pending = await app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: tokenBody,
    });
    expect(pending.status).toBe(400);
    expect(pending.headers.get("Retry-After")).toBe(String(grant.interval));
    expect(await pending.json()).toMatchObject({ error: { code: "authorization_pending" } });

    const approved = await app.request("https://quota.gotry.io/oauth/v2/device/authorize", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://quota.gotry.io",
        "Sec-Fetch-Site": "same-origin",
      },
      body: JSON.stringify({
        protocol_version: 2,
        user_code: grant.user_code,
        decision: "approve",
      }),
    });
    expect(approved.status).toBe(204);

    checkedAt = new Date(now.getTime() + grant.interval * 1_000);
    const exchanged = await app.request("https://quota.gotry.io/oauth/v2/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: tokenBody,
    });
    expect(exchanged.status).toBe(200);
    const tokens = (await exchanged.json()) as OAuthTokenResponse;
    expect(tokens.account_id).toBe("device_account");
    expect(tokens.device_generation).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM devices WHERE id = ?1")
        .bind(tokens.device_id)
        .first("count"),
    ).toBe(1);
  });
});

function usageFactInsert(
  agent: string,
  channel: string,
  model: string,
  overrides: { deviceID?: string; channelSource?: string; timezone?: string } = {},
): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_hourly (
         device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
         agent, billing_channel, channel_source, model, context_bucket,
         service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
         output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
         source_cost_microusd, source_cost_covered_requests
       ) VALUES (
         ?4, '2026-08-10T00:00:00Z', '2026-08-10', 8, ?5,
         ?1, ?2, ?6, ?3, 'le_128k',
         'unknown', 'unknown', 'unknown', 10, 0,
         0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
       )`,
  ).bind(
    agent,
    channel,
    model,
    overrides.deviceID ?? "device_agents",
    overrides.timezone ?? "Asia/Singapore",
    overrides.channelSource ?? "agent_default",
  );
}

function usageFactInsertAt(
  deviceID: string,
  bucketStart: string,
  usageDate: string,
): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO usage_hourly (
       device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone,
       agent, billing_channel, channel_source, model, context_bucket,
       service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
       cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
       output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
       source_cost_microusd, source_cost_covered_requests
     ) VALUES (
       ?1, ?2, ?3, 0, 'UTC', 'codex', 'openai_direct', 'agent_default',
       'gpt-5.6-sol', 'le_128k', 'unknown', 'unknown', 'unknown', 10, 0,
       0, 0, 0, 2, 0, 1, 0, 0, NULL, 0
     )`,
  ).bind(deviceID, bucketStart, usageDate);
}

function usageFact(model: string, bucket: string) {
  return {
    bucket_start_utc: bucket,
    usage_date: bucket.slice(0, 10),
    usage_hour: Number(bucket.slice(11, 13)),
    agent: "codex" as const,
    billing_channel: "openai_direct" as const,
    channel_source: "agent_default" as const,
    model,
    context_bucket: "le_128k" as const,
    service_tier: "unknown",
    speed: "unknown",
    inference_geo: "unknown",
    input_tokens: 10,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 2,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
  };
}

function usageSubmission(
  submissionID: string,
  sequence: number,
  startAt: string,
  endAt: string,
  rows: ReturnType<typeof usageFact>[],
): UsageSubmission {
  return {
    protocol_version: 5,
    submission_id: submissionID,
    device_id: "device_partial",
    generation: 1,
    sequence,
    parser_revision: "parser_partial",
    aggregation_timezone: "UTC",
    coverage: {
      agent: "codex",
      start_at: startAt,
      end_at: endAt,
      status: "complete",
    },
    rows,
  };
}

function unknownModelSubmission(): UsageSubmission {
  return {
    protocol_version: 5,
    submission_id: "submission_unknown_model",
    device_id: "device_legacy",
    generation: 1,
    sequence: 0,
    parser_revision: "parser_unknown_model",
    aggregation_timezone: "UTC",
    coverage: {
      agent: "codex",
      start_at: "2026-08-09T10:00:00Z",
      end_at: "2026-08-09T11:00:00Z",
      status: "complete",
    },
    rows: [
      {
        bucket_start_utc: "2026-08-09T10:00:00Z",
        usage_date: "2026-08-09",
        usage_hour: 10,
        agent: "codex",
        billing_channel: "openai_direct",
        channel_source: "agent_default",
        model: "unknown",
        context_bucket: "le_128k",
        service_tier: "unknown",
        speed: "unknown",
        inference_geo: "unknown",
        input_tokens: 10,
        cache_read_tokens: 0,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0,
        cache_write_inferred_tokens: 0,
        output_tokens: 2,
        reasoning_tokens: 0,
        requests: 1,
        web_search_requests: 0,
        web_fetch_requests: 0,
        source_cost_covered_requests: 0,
      },
    ],
  };
}

function webSessionFor(accountId: string): WebAccountAuth {
  return {
    handler: async () => new Response(null, { status: 404 }),
    beginGitHubSignIn: async () => new Response(null, { status: 302 }),
    getSession: async () => ({
      user: { id: accountId, name: "Quota Tester" },
      session: {
        id: `web_${accountId}`,
        createdAt: now,
        expiresAt: new Date(now.getTime() + 60_000),
      },
    }),
  };
}

function quotaSnapshotJson() {
  return {
    protocol_version: 5,
    provider: "codex",
    captured_at: now.toISOString(),
    observed_at: now.toISOString(),
    valid_for_seconds: 3_600,
    account: { fingerprint: "fingerprint_etag", label: "tester", plan: "Plus" },
    windows: [
      {
        id: "weekly",
        title: "Weekly",
        used_percent: 25,
        resets_at: new Date(now.getTime() + 86_400_000).toISOString(),
      },
    ],
  };
}
