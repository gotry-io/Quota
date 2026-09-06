import conformanceJson from "../fixtures/quota-pace-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import { QuotaSnapshotSchema, Rfc3339InstantSchema } from "../src/index.ts";

type PaceCase = {
  name: string;
  now: string;
  window: unknown;
  expected: Record<string, unknown>;
  expected_copy: string | null;
};

const conformance = conformanceJson as unknown as { cases: PaceCase[] };

/**
 * The pace fixture is read by three runtimes that do not share a type checker, so this file
 * is where its shape is stated: every case names a real quota window, a placeable clock, and
 * an outcome the rule can produce. What the rule answers for those inputs is
 * `packages/quota-model`'s test, and the same file is answered by Rust and Swift.
 */
describe("quota pace conformance", () => {
  it("states enough cases to pin the rule", () => {
    expect(conformance.cases.length).toBeGreaterThanOrEqual(12);
  });

  it("names a real quota window and a placeable clock in every case", () => {
    for (const testCase of conformance.cases) {
      expect(Rfc3339InstantSchema.safeParse(testCase.now).success, testCase.name).toBe(true);
      const snapshot = QuotaSnapshotSchema.safeParse({
        provider: "cursor",
        account: { fingerprint: "fp-pace", fingerprint_scope: "global" },
        windows: [testCase.window],
        status: "available",
        observed_at: testCase.now,
      });
      expect(snapshot.success, testCase.name).toBe(true);
    }
  });

  it("states one well-formed outcome per case", () => {
    for (const testCase of conformance.cases) {
      const { kind, tempo, delta_percent, projected_at_reset, exhausts_at } = testCase.expected;
      expect(["none", "lasts", "runs_out"], testCase.name).toContain(kind);
      if (kind === "none") {
        expect(Object.keys(testCase.expected), testCase.name).toEqual(["kind"]);
        expect(testCase.expected_copy, testCase.name).toBeNull();
        continue;
      }
      expect(["ahead", "on_track", "behind"], testCase.name).toContain(tempo);
      expect(Number.isInteger(delta_percent), testCase.name).toBe(true);
      expect(typeof projected_at_reset === "number", testCase.name).toBe(true);
      expect(projected_at_reset as number, testCase.name).toBeLessThanOrEqual(999);
      expect(typeof testCase.expected_copy === "string", testCase.name).toBe(true);
      if (kind === "runs_out") {
        expect(Rfc3339InstantSchema.safeParse(exhausts_at).success, testCase.name).toBe(true);
      } else {
        expect(exhausts_at, testCase.name).toBeUndefined();
      }
    }
  });

  it("covers every outcome and tempo the rule can produce", () => {
    const kinds = new Set(conformance.cases.map((testCase) => testCase.expected.kind));
    const tempos = new Set(
      conformance.cases.map((testCase) => testCase.expected.tempo).filter(Boolean),
    );
    expect([...kinds].sort()).toEqual(["lasts", "none", "runs_out"]);
    expect([...tempos].sort()).toEqual(["ahead", "behind", "on_track"]);
  });
});
