import conformanceJson from "../fixtures/provider-web-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { ProviderIdSchema, QuotaSnapshotSchema } from "../src/index.ts";

/**
 * The shape of `provider-web-conformance.json`, which states what a stored browser session
 * answers for the three providers whose web session both Quota clients read.
 *
 * The Rust collectors and Swift's `QuotaProviderWeb` each drive the file; this is what keeps a
 * case from being written in a shape only one of them happens to read. A reading a case expects
 * is a real `QuotaSnapshot`, so a case cannot state a snapshot the wire contract would refuse.
 */
const ErrorCategorySchema = z.enum(["auth_required", "unavailable", "unsupported", "error"]);

const ExchangeSchema = z
  .object({
    method: z.enum(["GET", "POST"]),
    path: z.string().startsWith("/"),
    status: z.number().int().min(100).max(599),
    /** A JSON document, or `body_base64` for the one provider that answers in binary. */
    body: z.unknown().optional(),
    body_base64: z.string().optional(),
  })
  .strict()
  .refine(
    (exchange) => "body" in exchange !== (exchange.body_base64 !== undefined),
    "an exchange names exactly one body",
  );

const CaseSchema = z
  .object({
    provider: ProviderIdSchema,
    name: z.string().min(1),
    now: z.string().datetime(),
    cookie_header: z.string().min(1).max(8192),
    exchanges: z.array(ExchangeSchema).max(8),
    expect: z
      .object({
        validated: z.union([
          z
            .object({
              account_fingerprint: z.string().regex(/^[0-9a-f]{64}$/),
              account_label: z.string().min(1).max(128).nullable(),
            })
            .strict(),
          ErrorCategorySchema,
        ]),
        snapshot: QuotaSnapshotSchema.nullable(),
        snapshot_error: ErrorCategorySchema.optional(),
      })
      .strict()
      .refine(
        (expect) => (expect.snapshot === null) === (expect.snapshot_error !== undefined),
        "a reading is a snapshot or a category, never both and never neither",
      ),
  })
  .strict();

const FixtureSchema = z
  .object({
    $comment: z.string().min(1),
    sources: z.record(z.string(), z.string().min(1)),
    cases: z.array(CaseSchema).min(1),
  })
  .strict();

describe("provider web conformance", () => {
  it("states every case in the shape both runtimes read", () => {
    const parsed = FixtureSchema.safeParse(conformanceJson);
    expect(parsed.error?.message ?? "valid").toBe("valid");
  });

  it("covers each provider's success and refusal, and names the rung each failure reports", () => {
    const fixture = FixtureSchema.parse(conformanceJson);
    expect(Object.keys(fixture.sources).sort()).toEqual(["claude", "codex", "grok"]);
    for (const provider of Object.keys(fixture.sources)) {
      const cases = fixture.cases.filter((testCase) => testCase.provider === provider);
      expect(cases.length, provider).toBeGreaterThanOrEqual(3);
      expect(
        cases.some((testCase) => testCase.expect.snapshot !== null),
        provider,
      ).toBe(true);
      expect(
        cases.some((testCase) => typeof testCase.expect.validated === "string"),
        provider,
      ).toBe(true);
    }
    // A case names a provider the fixture states a rung for; nothing else is drivable.
    for (const testCase of fixture.cases) {
      expect(fixture.sources[testCase.provider], testCase.name).toBeDefined();
    }
  });
});
