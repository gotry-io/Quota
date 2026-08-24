import conformanceJson from "../fixtures/wire-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import {
  AccountSummarySchema,
  QuotaSnapshotEnvelopeSchema,
  UsageSubmissionSchema,
} from "../src/index.ts";

type WireConformance = {
  contracts: Record<
    string,
    Array<{ name: string; accepted: boolean; payload: unknown; reason?: string }>
  >;
};

const conformance = conformanceJson as WireConformance;

/**
 * The zod schema is the definition; the Rust validator and the Swift decoder each restate
 * it for their own trust boundary. This file is the judge all three answer, so a payload
 * one of them starts accepting cannot pass unnoticed by the others.
 */
const schemas = {
  quota_snapshot_envelope: QuotaSnapshotEnvelopeSchema,
  account_summary: AccountSummarySchema,
  usage_submission: UsageSubmissionSchema,
};

describe("wire conformance", () => {
  it("covers every contract this runtime states", () => {
    expect(Object.keys(conformance.contracts).sort()).toEqual(Object.keys(schemas).sort());
  });

  for (const [contract, schema] of Object.entries(schemas)) {
    it(`answers the shared cases for ${contract}`, () => {
      const cases = conformance.contracts[contract];
      expect(cases?.length ?? 0).toBeGreaterThan(1);
      for (const testCase of cases ?? []) {
        expect(schema.safeParse(testCase.payload).success, testCase.name).toBe(testCase.accepted);
      }
    });
  }
});
