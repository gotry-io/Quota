import { readFile, readdir } from "node:fs/promises";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  RelayInfoSchema,
} from "../src/index.ts";

describe("quota protocol", () => {
  it("accepts a normalized quota envelope", () => {
    const result = QuotaSnapshotEnvelopeSchema.safeParse({
      schema_version: 1,
      device_id: "device_01",
      sequence: 42,
      captured_at: "2026-08-02T12:00:00Z",
      snapshots: [
        {
          provider: "codex",
          account: { fingerprint: "account_01", plan: "plus" },
          windows: [
            {
              id: "five_hour",
              title: "5 hour",
              used_percent: 25,
              resets_at: "2026-08-02T15:00:00Z",
            },
          ],
          source: "codex_api",
          status: "available",
          observed_at: "2026-08-02T12:00:00Z",
        },
      ],
    });

    expect(result.success).toBe(true);
  });

  it("accepts a collection report with mixed outcomes", () => {
    const result = QuotaCollectionReportSchema.safeParse({
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "codex",
          outcome: "success",
          snapshots: [
            {
              provider: "codex",
              account: { fingerprint: "account_01" },
              windows: [{ id: "five_hour", title: "5 hour", used_percent: 10 }],
              source: "chatgpt_usage_api",
              status: "available",
              observed_at: "2026-08-02T12:00:00Z",
            },
          ],
          source: "chatgpt_usage_api",
        },
        {
          provider: "claude",
          outcome: "auth_required",
          snapshots: [],
          message: "Sign in again",
        },
        {
          provider: "grok",
          outcome: "unsupported",
          snapshots: [],
          source: "grok_billing_api",
          message: "Method not found",
        },
      ],
    });
    expect(result.success).toBe(true);
  });

  it("rejects empty successes, failure snapshots, and cross-provider snapshots", () => {
    const base = {
      schema_version: 1,
      captured_at: "2026-08-02T12:00:00Z",
    } as const;

    expect(
      QuotaCollectionReportSchema.safeParse({
        ...base,
        results: [{ provider: "codex", outcome: "success", snapshots: [] }],
      }).success,
    ).toBe(false);

    expect(
      QuotaCollectionReportSchema.safeParse({
        ...base,
        results: [{ provider: "claude", outcome: "auth_required" }],
      }).success,
    ).toBe(false);

    expect(
      QuotaCollectionReportSchema.safeParse({
        ...base,
        results: [
          {
            provider: "codex",
            outcome: "auth_required",
            snapshots: [snapshot("codex")],
          },
        ],
      }).success,
    ).toBe(false);

    expect(
      QuotaCollectionReportSchema.safeParse({
        ...base,
        results: [
          {
            provider: "codex",
            outcome: "success",
            snapshots: [snapshot("claude")],
          },
        ],
      }).success,
    ).toBe(false);
  });

  it("allows a relay to publish only implemented capabilities", () => {
    const result = RelayInfoSchema.safeParse({
      instance_id: "relay_01",
      mode: "self_hosted",
      version: "0.1.0",
      api_versions: [1],
      auth_methods: [],
      capabilities: {
        realtime: false,
        persistent_snapshots: false,
        instant_device_revocation: false,
        history: false,
        multi_tenant: false,
      },
    });

    expect(result.success).toBe(true);
  });

  it("rejects unknown wire fields", () => {
    const result = QuotaSnapshotEnvelopeSchema.safeParse({
      schema_version: 1,
      device_id: "device_01",
      sequence: 42,
      captured_at: "2026-08-02T12:00:00Z",
      snapshots: [],
      unexpected: true,
    });

    expect(result.success).toBe(false);
  });

  it("keeps versioned JSON Schema identifiers and references locally resolvable", async () => {
    const schemaDirectory = fileURLToPath(new URL("../schema/", import.meta.url));
    const schemaFiles = (await readdir(schemaDirectory))
      .filter((file) => file.endsWith(".json"))
      .sort();
    expect(schemaFiles.length).toBeGreaterThan(0);

    for (const schemaFile of schemaFiles) {
      const schema = JSON.parse(await readFile(`${schemaDirectory}/${schemaFile}`, "utf8")) as {
        $id: string;
      };
      expect(basename(new URL(schema.$id).pathname)).toBe(schemaFile);

      for (const reference of collectSchemaReferences(schema)) {
        const referencedFile = reference.split("#", 1)[0];
        if (referencedFile) {
          expect(schemaFiles).toContain(referencedFile);
        }
      }
    }
  });
});

function snapshot(provider: "codex" | "claude" | "grok") {
  return {
    provider,
    account: { fingerprint: `${provider}-fixture` },
    windows: [{ id: "five_hour", title: "5 hour", used_percent: 10 }],
    source: "fixture",
    status: "available" as const,
    observed_at: "2026-08-02T12:00:00Z",
  };
}

function collectSchemaReferences(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.flatMap(collectSchemaReferences);
  }
  if (!value || typeof value !== "object") {
    return [];
  }

  const record = value as Record<string, unknown>;
  const references =
    typeof record.$ref === "string" && !record.$ref.startsWith("#") ? [record.$ref] : [];
  return references.concat(Object.values(record).flatMap(collectSchemaReferences));
}
