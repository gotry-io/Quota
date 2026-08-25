import conformanceJson from "../fixtures/wire-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import {
  AccountSummaryReadSchema,
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
 *
 * A write is answered by the schema that guards it and a read by the schema a client reads
 * with, because that is which side of the boundary each contract is on. See ADR 0023.
 */
const schemas = {
  quota_snapshot_envelope: QuotaSnapshotEnvelopeSchema,
  account_summary: AccountSummaryReadSchema,
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

/** Every object node in a payload, named by the path that reaches it. */
function objectPaths(node: unknown, path: string[] = []): string[][] {
  if (Array.isArray(node))
    return node.flatMap((item, index) => objectPaths(item, [...path, `${index}`]));
  if (node === null || typeof node !== "object") return [];
  return [
    path,
    ...Object.entries(node).flatMap(([key, value]) => objectPaths(value, [...path, key])),
  ];
}

/**
 * A reader has to tolerate a key at any depth, not only at the top, because a Relay newer than
 * this build can add one anywhere. Deriving the cases from the accepted payload keeps that honest
 * as the contract grows: a nested shape nobody opened fails here rather than in a client that
 * quietly stopped reading its Account.
 */
describe("a managed read tolerates what its producer refuses", () => {
  const accepted = conformance.contracts.account_summary?.find((testCase) => testCase.accepted);

  it("accepts a field a newer Relay could add at any depth", () => {
    expect(accepted).toBeDefined();
    const paths = objectPaths(accepted?.payload);
    expect(paths.length).toBeGreaterThan(4);
    for (const path of paths) {
      const payload = structuredClone(accepted?.payload) as Record<string, unknown>;
      let target = payload;
      for (const key of path) target = target[key] as Record<string, unknown>;
      target.a_field_from_a_newer_relay = true;
      const where = path.join(".") || "the summary itself";
      expect(AccountSummaryReadSchema.safeParse(payload).success, where).toBe(true);
      expect(AccountSummarySchema.safeParse(payload).success, where).toBe(false);
    }
  });
});
