import conformanceJson from "../../protocol/fixtures/quota-observation-conformance.json" with {
  type: "json",
};
import {
  type QuotaSnapshot,
  QuotaSnapshotSchema,
  type QuotaStatus,
} from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import {
  mergeQuotaObservations,
  observedSnapshotStatus,
  type QuotaObservationInput,
  snapshotValidUntil,
} from "../src/index.ts";

type ConformanceFixture = {
  freshness: Array<{
    name: string;
    now: string;
    snapshot: QuotaSnapshot;
    expected: { valid_until: string; status: QuotaStatus };
  }>;
  merge: Array<{
    name: string;
    now: string;
    observations: QuotaObservationInput[];
    expected: Array<{
      identity: { provider: string; fingerprint: string; scope: string; source_id: string | null };
      selected_device_id: string;
      is_stale: boolean;
      sources: Array<{
        device_id: string;
        observed_at: string;
        is_stale: boolean;
        snapshot?: QuotaSnapshot;
      }>;
    }>;
  }>;
};

const conformance = conformanceJson as unknown as ConformanceFixture;

describe("observation freshness conformance", () => {
  it("derives the same validity boundary as the native service", () => {
    expect(conformance.freshness.length).toBeGreaterThan(0);
    for (const testCase of conformance.freshness) {
      expect(new Date(snapshotValidUntil(testCase.snapshot)).toISOString(), testCase.name).toBe(
        new Date(testCase.expected.valid_until).toISOString(),
      );
      expect(observedSnapshotStatus(testCase.snapshot, new Date(testCase.now)), testCase.name).toBe(
        testCase.expected.status,
      );
    }
  });

  it("refuses a reading that still carries the retired validity stamp", () => {
    const stamped = { ...conformance.freshness[1]!.snapshot, valid_until: "2099-01-01T00:00:00Z" };
    expect(QuotaSnapshotSchema.safeParse(stamped).success).toBe(false);
    expect(QuotaSnapshotSchema.safeParse(conformance.freshness[1]!.snapshot).success).toBe(true);
  });
});

describe("subscription merge conformance", () => {
  it("resolves subscriptions the way the native service resolves them", () => {
    expect(conformance.merge.length).toBeGreaterThan(0);
    for (const testCase of conformance.merge) {
      const merged = mergeQuotaObservations(testCase.observations, new Date(testCase.now));
      const actual = merged.map((item) => ({
        identity: item.identity,
        selected_device_id: item.selected_device_id,
        is_stale: item.is_stale,
        sources: item.sources,
      }));
      const expected = testCase.expected.map((item) => ({
        ...item,
        sources: item.sources.map((source) => {
          const observation = testCase.observations.find(
            (candidate) =>
              candidate.device_id === source.device_id &&
              candidate.snapshot.account.fingerprint === item.identity.fingerprint &&
              candidate.snapshot.observed_at === source.observed_at,
          );
          return { ...source, snapshot: observation?.snapshot };
        }),
      }));
      expect(actual, testCase.name).toEqual(expected);
    }
  });

  it("returns nothing for an account that has never reported", () => {
    expect(mergeQuotaObservations([])).toEqual([]);
  });
});
