import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  AccountSummary,
  LocalUsageReport,
  QuotaCollectionReport,
} from "@gotry-io/quota-protocol";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AccountClientError } from "../src/account/client.ts";
import { AccountStateStore, type ActiveAccountSessionState } from "../src/account/state.ts";
import { runSyncCommand, type SyncDependencies } from "../src/account/sync.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-account-sync-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("account sync", () => {
  it("collects locally while signed out and performs no network request", async () => {
    const dependencies = makeDependencies();
    const capture = captureOutput();

    expect(await runSyncCommand(["--format=json"], capture.output, dependencies)).toBe(0);
    expect(JSON.parse(capture.stdout[0] ?? "")).toMatchObject({
      schema_version: 2,
      status: "signed_out",
      local_report: { protocol_version: 2 },
      local_usage: { protocol_version: 2, status: "partial" },
      account_summary: null,
    });
    expect(dependencies.client.syncControl).not.toHaveBeenCalled();
    expect(dependencies.client.uploadSnapshot).not.toHaveBeenCalled();
  });

  it("uses authoritative control, uploads its own device/generation, and commits next sequence", async () => {
    const dependencies = makeDependencies();
    await dependencies.store.loadOrCreateInstallation();
    await dependencies.store.saveActiveSession(activeSession());
    const capture = captureOutput();

    expect(await runSyncCommand(["--format=json"], capture.output, dependencies)).toBe(0);
    expect(dependencies.client.uploadSnapshot).toHaveBeenCalledWith(
      "device-synthetic-access-token",
      expect.objectContaining({
        protocol_version: 2,
        device_id: "device_test",
        generation: 3,
        sequence: 8,
      }),
    );
    expect(dependencies.refreshPricingCatalog).toHaveBeenCalledOnce();
    expect(await dependencies.store.loadSession()).toMatchObject({ next_snapshot_sequence: 9 });
    const result = JSON.parse(capture.stdout[0] ?? "");
    expect(result.status).toBe("synced");
    expect(result.account_summary.account.account_id).toBe("account_test");
    expect(JSON.stringify(result)).not.toContain("synthetic-access-token");
  });

  it("fails closed and drops local sessions when Web deleted the device", async () => {
    const dependencies = makeDependencies();
    await dependencies.store.loadOrCreateInstallation();
    await dependencies.store.saveActiveSession(activeSession());
    dependencies.client.syncControl.mockRejectedValueOnce(
      new AccountClientError("device_deleted", "raw secret response"),
    );
    const capture = captureOutput();

    expect(await runSyncCommand(["--format=json"], capture.output, dependencies)).toBe(1);
    expect(await dependencies.store.loadSession()).toBeNull();
    expect(JSON.parse(capture.stdout[0] ?? "")).toMatchObject({
      status: "signed_out",
      reason: "device_deleted",
    });
    expect(capture.stderr.join("\n")).not.toContain("raw secret response");
  });
});

function makeDependencies(): SyncDependencies & {
  client: {
    refreshSession: ReturnType<typeof vi.fn>;
    syncControl: ReturnType<typeof vi.fn>;
    uploadSnapshot: ReturnType<typeof vi.fn>;
    accountSummary: ReturnType<typeof vi.fn>;
  };
} {
  return {
    store: new AccountStateStore({ root: temporaryDirectory }),
    now: () => new Date("2026-08-09T12:00:00Z"),
    collect: vi.fn(async () => localReport()),
    collectLocalUsage: vi.fn(async () => localUsageReport()),
    refreshPricingCatalog: vi.fn(async () => undefined),
    client: {
      refreshSession: vi.fn(async () => {
        throw new Error("fresh fixture tokens should not refresh");
      }),
      syncControl: vi.fn(async () => ({
        protocol_version: 2 as const,
        account_id: "account_test",
        device_id: "device_test",
        device_generation: 3,
        next_snapshot_sequence: 8,
        next_usage_sequence: 4,
        usage_deleted_before: null,
        usage_sync_revision: 2,
      })),
      uploadSnapshot: vi.fn(async () => ({
        protocol_version: 2 as const,
        outcome: "accepted" as const,
        device_id: "device_test",
        device_generation: 3,
        accepted_sequence: 8,
        next_snapshot_sequence: 9,
      })),
      accountSummary: vi.fn(async () => accountSummary()),
    },
    syncUsage: vi.fn(async () => ({ uploaded: 0, pending: 0, coverage: [] })),
  };
}

function activeSession(): ActiveAccountSessionState {
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
      access_token: "account-synthetic-access-token",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "account-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
    device: {
      account_id: "account_test",
      device_id: "device_test",
      device_generation: 3,
      access_token: "device-synthetic-access-token",
      access_expires_at: "2026-08-09T12:15:00Z",
      refresh_token: "device-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
  };
}

function localReport(): QuotaCollectionReport {
  return {
    protocol_version: 2,
    captured_at: "2026-08-09T12:00:00Z",
    results: [
      {
        provider: "codex",
        outcome: "success",
        snapshots: [
          {
            provider: "codex",
            account: { fingerprint: "codex_test", fingerprint_scope: "source" },
            windows: [],
            source: "codex_oauth",
            status: "available",
            observed_at: "2026-08-09T12:00:00Z",
          },
        ],
      },
    ],
  };
}

function localUsageReport(): LocalUsageReport {
  return {
    protocol_version: 2,
    generated_at: "2026-08-09T12:00:00Z",
    aggregation_timezone: "UTC",
    range: { from: "2026-07-11", to: "2026-08-09" },
    status: "partial",
    totals: emptyTotals(),
    cost: emptyCost(),
    coverage: [
      {
        agent: "codex",
        start_at: "2026-07-10T00:00:00Z",
        end_at: "2026-08-09T13:00:00Z",
        status: "partial",
      },
    ],
    breakdowns: [],
  };
}

function accountSummary(): AccountSummary {
  const totals = emptyTotals();
  return {
    protocol_version: 2,
    generated_at: "2026-08-09T12:00:00Z",
    account: {
      account_id: "account_test",
      display_label: "Synthetic account",
      created_at: "2026-08-09T12:00:00Z",
    },
    devices: [],
    quota: [],
    usage: {
      range: { from: "2026-08-09", to: "2026-08-09" },
      totals,
      cost: emptyCost(),
      coverage: [],
      breakdowns: [],
    },
  };
}

function emptyTotals() {
  return {
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 0,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: null,
    source_cost_covered_requests: 0,
  };
}

function emptyCost() {
  return {
    mode: "calculate" as const,
    basis: "none" as const,
    status: "complete" as const,
    amount_microusd: null,
    catalog_revision: null,
    calculated_rows: 0,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
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
