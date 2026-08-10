import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  BillingAgent,
  UsageSubmissionV2,
  UsageUploadResponse,
} from "@gotry-io/quota-protocol";
import type { NormalizedUsageEvent, UsageScanResult } from "@gotry-io/quota-provider";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AccountStateStore, type ActiveAccountSessionState } from "../src/account/state.ts";
import { syncUsage, type UsageSyncDependencies } from "../src/account/usage-sync.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-usage-sync-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("Usage sync", () => {
  it("filters a deletion watermark inside an hour and uploads only complete aggregated facts", async () => {
    const dependencies = await makeDependencies([
      event("2026-08-09T10:01:00Z", 10),
      event("2026-08-09T10:06:00Z", 20),
    ]);

    const result = await syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies);

    expect(result).toMatchObject({ uploaded: 1, pending: 0 });
    const submission = vi.mocked(dependencies.client.uploadUsage).mock.calls[0]?.[1];
    expect(submission).toMatchObject({
      sequence: 0,
      coverage: { agent: "codex", start_at: "2026-08-09T10:00:00Z" },
      rows: [{ input_tokens: 20, requests: 1 }],
    });
    expect(JSON.stringify(submission)).not.toContain("source_file_id");
    expect(await dependencies.store.loadSession()).toMatchObject({
      next_usage_sequence: 1,
      usage_sync_revision: 1,
    });
  });

  it("never uploads or advances a partial scan", async () => {
    const dependencies = await makeDependencies([], "partial");

    const result = await syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies);

    expect(result.uploaded).toBe(0);
    expect(result.coverage).toEqual([
      {
        agent: "codex",
        start_at: "2026-08-09T10:00:00Z",
        end_at: "2026-08-09T12:00:00Z",
        status: "partial",
      },
      {
        agent: "claude_code",
        start_at: "2026-08-09T10:00:00Z",
        end_at: "2026-08-09T12:00:00Z",
        status: "partial",
      },
    ]);
    expect(dependencies.client.uploadUsage).not.toHaveBeenCalled();
  });

  it("recovers a missing local cursor from the earliest readable event", async () => {
    const dependencies = await makeDependencies([event("2026-08-09T10:06:00Z", 20)]);
    const session = {
      ...activeSession(),
      next_usage_sequence: 7,
      usage_sync_revision: 7,
    };
    await dependencies.store.saveActiveSession(session);

    const result = await syncUsage(session, new Date("2026-08-09T12:30:00Z"), dependencies);

    expect(result).toMatchObject({ uploaded: 1, pending: 0 });
    expect(vi.mocked(dependencies.client.uploadUsage).mock.calls[0]?.[1]).toMatchObject({
      sequence: 7,
      coverage: {
        agent: "codex",
        start_at: "2026-08-09T10:00:00Z",
        end_at: "2026-08-09T12:00:00Z",
      },
    });
  });

  it("keeps an immutable outbox entry across a failed request and retries the same id and sequence", async () => {
    const dependencies = await makeDependencies([event("2026-08-09T10:06:00Z", 20)]);
    vi.mocked(dependencies.client.uploadUsage).mockRejectedValueOnce(new Error("offline"));

    await expect(
      syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies),
    ).rejects.toThrow("offline");
    const pending = (await dependencies.store.loadArtifact("usage-outbox.json")) as {
      queues: Array<{ entries: UsageSubmissionV2[] }>;
    };
    expect(pending.queues[0]?.entries).toHaveLength(1);
    const first = pending.queues[0]?.entries[0];

    await syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies);

    const retried = vi.mocked(dependencies.client.uploadUsage).mock.calls[1]?.[1];
    expect(retried?.submission_id).toBe(first?.submission_id);
    expect(retried?.sequence).toBe(first?.sequence);
  });

  it("keeps an acknowledged submission until its session checkpoint is durable", async () => {
    const dependencies = await makeDependencies([event("2026-08-09T10:06:00Z", 20)]);
    vi.spyOn(dependencies.store, "updateActiveSession").mockRejectedValueOnce(
      new Error("session checkpoint failed"),
    );

    await expect(
      syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies),
    ).rejects.toThrow("session checkpoint failed");
    const pending = (await dependencies.store.loadArtifact("usage-outbox.json")) as {
      queues: Array<{ entries: UsageSubmissionV2[] }>;
    };
    expect(pending.queues[0]?.entries).toHaveLength(1);

    await syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies);

    const uploads = vi.mocked(dependencies.client.uploadUsage).mock.calls.map((call) => call[1]);
    expect(uploads[1]?.submission_id).toBe(uploads[0]?.submission_id);
    expect(uploads[1]?.sequence).toBe(uploads[0]?.sequence);
  });

  it("replays an acknowledged submission if removing it from the outbox fails", async () => {
    const dependencies = await makeDependencies([event("2026-08-09T10:06:00Z", 20)]);
    const saveArtifact = dependencies.store.saveArtifact.bind(dependencies.store);
    let failRemoval = true;
    vi.spyOn(dependencies.store, "saveArtifact").mockImplementation(async (name, value) => {
      const artifact = value as { queues?: Array<{ entries: UsageSubmissionV2[] }> };
      if (
        failRemoval &&
        name === "usage-outbox.json" &&
        artifact.queues?.some((queue) => queue.entries.length === 0)
      ) {
        failRemoval = false;
        throw new Error("outbox removal failed");
      }
      await saveArtifact(name, value);
    });

    await expect(
      syncUsage(activeSession(), new Date("2026-08-09T12:30:00Z"), dependencies),
    ).rejects.toThrow("outbox removal failed");
    const checkpoint = await dependencies.store.loadSession();
    expect(checkpoint).toMatchObject({ next_usage_sequence: 1, usage_sync_revision: 1 });

    vi.mocked(dependencies.client.uploadUsage).mockImplementationOnce(async (_token, submission) =>
      duplicate(submission),
    );
    await syncUsage(
      checkpoint as ActiveAccountSessionState,
      new Date("2026-08-09T12:30:00Z"),
      dependencies,
    );

    const uploads = vi.mocked(dependencies.client.uploadUsage).mock.calls.map((call) => call[1]);
    expect(uploads[1]?.submission_id).toBe(uploads[0]?.submission_id);
    expect(uploads[1]?.sequence).toBe(uploads[0]?.sequence);
    expect(await dependencies.store.loadArtifact("usage-outbox.json")).toMatchObject({
      queues: [{ entries: [] }],
    });
  });
});

async function makeDependencies(
  events: readonly NormalizedUsageEvent[],
  status: "complete" | "partial" = "complete",
): Promise<UsageSyncDependencies> {
  const store = new AccountStateStore({ root: temporaryDirectory });
  await store.loadOrCreateInstallation();
  await store.saveActiveSession(activeSession());
  return {
    store,
    aggregationTimezone: () => "UTC",
    scan: vi.fn(async (agent: BillingAgent, startAt: string, endAt: string) =>
      scanResult(agent, startAt, endAt, status, agent === "codex" ? events : []),
    ),
    client: {
      uploadUsage: vi.fn(async (_token: string, submission: UsageSubmissionV2) =>
        accepted(submission),
      ),
    },
  };
}

function scanResult(
  agent: BillingAgent,
  startAt: string,
  endAt: string,
  status: "complete" | "partial",
  events: readonly NormalizedUsageEvent[],
): UsageScanResult {
  return {
    records: events.map((value, index) => ({
      event: value,
      cursor: {
        source_file_id: `opaque-${index}`,
        byte_offset: index,
        record_hash: `hash-${index}`,
      },
    })),
    coverage: { agent, start_at: startAt, end_at: endAt, status, reasons: [] },
    scanned_source_count: 1,
  };
}

function event(occurredAt: string, inputTokens: number): NormalizedUsageEvent {
  return {
    occurred_at: occurredAt,
    agent: "codex",
    model: "gpt-5.6",
    billing_channel: "openai_direct",
    channel_source: "agent_default",
    input_tokens: inputTokens,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 2,
    reasoning_tokens: 1,
    requests: 1,
    context_bucket: "le_128k",
    service_tier: "standard",
    speed: "standard",
    inference_geo: "unknown",
    billable_tools: {},
    source_cost_covered_requests: 0,
  };
}

function accepted(submission: UsageSubmissionV2): UsageUploadResponse {
  return {
    protocol_version: 2,
    outcome: "accepted",
    device_id: submission.device_id,
    device_generation: submission.generation,
    accepted_sequence: submission.sequence,
    next_sequence: submission.sequence + 1,
    usage_sync_revision: submission.sequence + 1,
    deleted_before: null,
  };
}

function duplicate(submission: UsageSubmissionV2): UsageUploadResponse {
  return { ...accepted(submission), outcome: "duplicate" };
}

function activeSession(): ActiveAccountSessionState {
  return {
    schema_version: 1,
    status: "active",
    account_id: "account_test",
    device_id: "device_test",
    device_generation: 3,
    next_snapshot_sequence: 7,
    next_usage_sequence: 0,
    usage_sync_revision: 0,
    usage_deleted_before: "2026-08-09T10:05:00Z",
    upload_not_before: "1970-01-01T00:00:00Z",
    account: {
      account_id: "account_test",
      access_token: "account-synthetic-access-token",
      access_expires_at: "2026-08-09T12:45:00Z",
      refresh_token: "account-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
    device: {
      account_id: "account_test",
      device_id: "device_test",
      device_generation: 3,
      access_token: "device-synthetic-access-token",
      access_expires_at: "2026-08-09T12:45:00Z",
      refresh_token: "device-synthetic-refresh-token",
      refresh_expires_at: "2026-11-09T12:00:00Z",
    },
  };
}
