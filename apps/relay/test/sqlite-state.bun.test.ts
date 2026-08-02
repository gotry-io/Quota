import { describe, expect, it } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SQLiteRelayState } from "../src/state/sqlite-state.ts";

describe("SQLiteRelayState", () => {
  it("persists the latest normalized snapshot", async () => {
    const state = await makeState();
    await state.recordSnapshot({
      schema_version: 1,
      device_id: "device_01",
      sequence: 1,
      captured_at: "2026-08-02T01:00:00Z",
      snapshots: [
        {
          provider: "codex",
          account: { fingerprint: "account_01" },
          windows: [{ id: "five_hour", title: "5 hour", used_percent: 20 }],
          source: "codex_api",
          status: "available",
          observed_at: "2026-08-02T01:00:00Z",
        },
      ],
    });

    const snapshots = await state.listLatestSnapshots("owner_01");
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0]?.snapshot.provider).toBe("codex");
  });

  it("ignores replayed and out-of-order device sequences", async () => {
    const state = await makeState();

    await state.recordSnapshot(envelope(2, 20, "2026-08-02T02:00:00Z"));
    await state.recordSnapshot(envelope(2, 99, "2026-08-02T03:00:00Z"));
    await state.recordSnapshot(envelope(1, 10, "2026-08-02T01:00:00Z"));

    const snapshots = await state.listLatestSnapshots("owner_01");
    const device = await state.getDevice("device_01");
    expect(snapshots[0]?.snapshot.windows[0]?.used_percent).toBe(20);
    expect(device?.last_sequence).toBe(2);
    expect(device?.last_seen_at).not.toBe("2026-08-02T01:00:00Z");
  });

  it("rejects snapshots from a revoked device", async () => {
    const state = await makeState();
    await state.revokeDevice("owner_01", "device_01", "2026-08-02T00:30:00Z");

    await expect(state.recordSnapshot(envelope(1, 20, "2026-08-02T01:00:00Z"))).rejects.toThrow(
      "missing or revoked",
    );
    expect(await state.listLatestSnapshots("owner_01")).toHaveLength(0);
  });
});

async function makeState(): Promise<SQLiteRelayState> {
  const directory = mkdtempSync(join(tmpdir(), "quota-relay-test-"));
  const state = new SQLiteRelayState(join(directory, "relay.db"));
  await state.initialize();
  await state.ensureOwner("owner_01", "2026-08-02T00:00:00Z");
  await state.registerDevice({
    id: "device_01",
    owner_id: "owner_01",
    display_name: "Edge Mac",
    token_hash: "test-token-hash",
    created_at: "2026-08-02T00:00:00Z",
  });
  return state;
}

function envelope(sequence: number, usedPercent: number, capturedAt: string) {
  return {
    schema_version: 1 as const,
    device_id: "device_01",
    sequence,
    captured_at: capturedAt,
    snapshots: [
      {
        provider: "codex" as const,
        account: { fingerprint: "account_01" },
        windows: [{ id: "five_hour", title: "5 hour", used_percent: usedPercent }],
        source: "codex_api",
        status: "available" as const,
        observed_at: capturedAt,
      },
    ],
  };
}
