import { parseArgs } from "node:util";
import type {
  AccountSummary,
  DeviceSyncResponse,
  LocalUsageReport,
  QuotaCollectionReport,
  QuotaSnapshotEnvelope,
  QuotaSnapshotUploadResponse,
  SessionRefreshRequest,
  SessionRefreshResponse,
} from "@gotry-io/quota-protocol";
import { PROTOCOL_VERSION, QuotaCollectionReportSchema } from "@gotry-io/quota-protocol";
import { collectQuotaReport } from "@gotry-io/quota-provider";
import type { CliOutput } from "../commands.ts";
import { cliParseError } from "../arguments.ts";
import { QUOTA_CLI_VERSION } from "../commands.ts";
import { renderJson } from "../render.ts";
import { AccountClient, AccountClientError } from "./client.ts";
import { collectLocalUsage, defaultLocalUsageDependencies } from "./local-usage.ts";
import { refreshPricingCatalogCache } from "./pricing-cache.ts";
import { activeSessionWithFreshToken } from "./session.ts";
import {
  AccountStateStore,
  AccountStateStoreError,
  type ActiveAccountSessionState,
} from "./state.ts";
import {
  defaultUsageSyncDependencies,
  syncUsage as syncLocalUsage,
  type UsageSyncResult,
} from "./usage-sync.ts";

export interface SyncClient {
  refreshSession(input: SessionRefreshRequest): Promise<SessionRefreshResponse>;
  syncControl(token: string): Promise<DeviceSyncResponse>;
  uploadSnapshot(
    token: string,
    envelope: QuotaSnapshotEnvelope,
  ): Promise<QuotaSnapshotUploadResponse>;
  accountSummary(token: string, query?: string): Promise<AccountSummary>;
}

export interface SyncDependencies {
  client: SyncClient;
  store: AccountStateStore;
  now(): Date;
  collect(): Promise<QuotaCollectionReport>;
  collectLocalUsage(now: Date): Promise<LocalUsageReport>;
  refreshPricingCatalog(): Promise<void>;
  syncUsage(session: ActiveAccountSessionState, now: Date): Promise<UsageSyncResult>;
}

export async function runSyncCommand(
  args: readonly string[],
  output: CliOutput,
  dependencies?: SyncDependencies,
): Promise<number> {
  const parsed = parseSyncArguments(args);
  if (!parsed.ok) {
    output.stderr(`${parsed.error}\n\n${syncUsage()}`);
    return 2;
  }
  let resolved: SyncDependencies;
  let localReport: QuotaCollectionReport;
  let localUsage: LocalUsageReport;
  try {
    resolved = dependencies ?? defaultDependencies();
    localReport = QuotaCollectionReportSchema.parse(await resolved.collect());
    localUsage = await resolved.collectLocalUsage(resolved.now());
  } catch {
    output.stderr("QuotaCLI could not collect local quota and Usage.");
    return 1;
  }

  try {
    const stored = await resolved.store.loadSession();
    if (stored === null || stored.status === "logout_pending") {
      writeSyncResult(output, parsed.pretty, {
        schema_version: 2,
        status: stored === null ? "signed_out" : "logout_pending",
        local_report: localReport,
        local_usage: localUsage,
        account_summary: null,
      });
      return stored === null ? collectionExitCode(localReport) : 1;
    }

    let session = await activeSessionWithFreshToken(
      resolved.store,
      resolved.client,
      "device",
      resolved.now(),
    );
    const control = await resolved.client.syncControl(session.device.access_token);
    validateControl(session, control);
    session = await resolved.store.updateActiveSession((current) => ({
      ...current,
      device_generation: control.device_generation,
      next_snapshot_sequence: control.next_snapshot_sequence,
      next_usage_sequence: control.next_usage_sequence,
      usage_sync_revision: control.usage_sync_revision,
      usage_deleted_before: control.usage_deleted_before,
      device: { ...current.device, device_generation: control.device_generation },
    }));

    // Catalog availability must not block authoritative quota or Usage uploads. A failed refresh
    // leaves the last validated atomic cache untouched.
    await resolved.refreshPricingCatalog().catch(() => undefined);

    const snapshotUpload = await resolved.client.uploadSnapshot(
      session.device.access_token,
      snapshotEnvelope(session, localReport),
    );
    validateSnapshotUpload(session, snapshotUpload);
    await resolved.store.updateActiveSession((current) => ({
      ...current,
      next_snapshot_sequence: snapshotUpload.next_snapshot_sequence,
    }));

    const usageSync = await resolved.syncUsage(session, resolved.now());

    session = await activeSessionWithFreshToken(
      resolved.store,
      resolved.client,
      "account",
      resolved.now(),
    );
    const accountSummary = await resolved.client.accountSummary(
      session.account.access_token,
      "cost_mode=calculate",
    );
    writeSyncResult(output, parsed.pretty, {
      schema_version: 2,
      status: "synced",
      local_report: localReport,
      local_usage: localUsage,
      usage_sync: usageSync,
      account_summary: accountSummary,
    });
    return collectionExitCode(localReport);
  } catch (error) {
    if (
      error instanceof AccountClientError &&
      ["device_deleted", "deleted", "stale_generation", "unauthorized"].includes(error.code)
    ) {
      await resolved.store.clearSession().catch(() => undefined);
      writeSyncResult(output, parsed.pretty, {
        schema_version: 2,
        status: "signed_out",
        reason: error.code,
        local_report: localReport,
        local_usage: localUsage,
        account_summary: null,
      });
      return 1;
    }
    writeSyncResult(output, parsed.pretty, {
      schema_version: 2,
      status: "account_unavailable",
      local_report: localReport,
      local_usage: localUsage,
      account_summary: null,
    });
    output.stderr(
      error instanceof AccountStateStoreError && error.code === "client_upgrade_required"
        ? error.message
        : "Local quota was collected, but Quota account sync failed and will retry later.",
    );
    return 1;
  }
}

function snapshotEnvelope(
  session: ActiveAccountSessionState,
  report: QuotaCollectionReport,
): QuotaSnapshotEnvelope {
  return {
    protocol_version: PROTOCOL_VERSION,
    device_id: session.device_id,
    generation: session.device_generation,
    sequence: session.next_snapshot_sequence,
    captured_at: report.captured_at,
    snapshots: report.results.flatMap((result) => result.snapshots),
  };
}

function validateControl(session: ActiveAccountSessionState, control: DeviceSyncResponse): void {
  if (
    control.account_id !== session.account_id ||
    control.device_id !== session.device_id ||
    control.device_generation !== session.device_generation
  ) {
    throw new AccountStateStoreError(
      "invalid_state",
      "The Quota sync control does not match the local account and device.",
    );
  }
}

function validateSnapshotUpload(
  session: ActiveAccountSessionState,
  response: QuotaSnapshotUploadResponse,
): void {
  if (
    response.device_id !== session.device_id ||
    response.device_generation !== session.device_generation ||
    response.accepted_sequence !== session.next_snapshot_sequence
  ) {
    throw new AccountStateStoreError("invalid_state", "The Quota upload response was invalid.");
  }
}

function collectionExitCode(report: QuotaCollectionReport): number {
  return report.results.length > 0 && report.results.every((result) => result.outcome === "success")
    ? 0
    : 1;
}

function writeSyncResult(
  output: CliOutput,
  pretty: boolean,
  result: Record<string, unknown>,
): void {
  output.stdout(renderJson(result, pretty));
}

function parseSyncArguments(
  args: readonly string[],
): { ok: true; pretty: boolean } | { ok: false; error: string } {
  let values: { format?: string; pretty?: boolean };
  try {
    values = parseArgs({
      args: [...args],
      options: { format: { type: "string" }, pretty: { type: "boolean" } },
      strict: true,
      allowPositionals: false,
    }).values;
  } catch (error) {
    return { ok: false, error: cliParseError(error) };
  }
  if (values.format !== undefined && values.format !== "json") {
    return { ok: false, error: "sync supports --format json." };
  }
  return { ok: true, pretty: values.pretty ?? false };
}

function defaultDependencies(): SyncDependencies {
  const client = new AccountClient();
  const store = new AccountStateStore();
  return {
    client,
    store,
    now: () => new Date(),
    collect: async () =>
      await collectQuotaReport({ providers: "all", clientVersion: QUOTA_CLI_VERSION }),
    collectLocalUsage: async (now) =>
      await collectLocalUsage(now, defaultLocalUsageDependencies(store)),
    refreshPricingCatalog: async () => {
      await refreshPricingCatalogCache(store, client);
    },
    syncUsage: async (session, now) =>
      await syncLocalUsage(session, now, defaultUsageSyncDependencies(client, store)),
  };
}

export function syncUsage(): string {
  return "Usage: quotacli sync [--format json] [--pretty]";
}
