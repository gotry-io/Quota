import { readdir, readFile } from "node:fs/promises";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  DeviceListResponseSchema,
  MAXIMUM_SNAPSHOTS_PER_ENVELOPE,
  OwnerCreateResponseSchema,
  OwnerSnapshotListResponseSchema,
  PairingApprovalRequestSchema,
  PairingCreateRequestSchema,
  PairingCreateResponseSchema,
  PairingDenialRequestSchema,
  PairingTokenIssuedResponseSchema,
  PairingTokenPendingResponseSchema,
  PairingTokenRequestSchema,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  RelayErrorEnvelopeSchema,
  RelayInfoSchema,
} from "../src/index.ts";

describe("quota protocol", () => {
  it("validates the one-time anonymous owner credential response", () => {
    expect(
      OwnerCreateResponseSchema.safeParse({
        owner_token: "synthetic-owner-token",
      }).success,
    ).toBe(true);
    expect(
      OwnerCreateResponseSchema.safeParse({
        owner_token: "synthetic-owner-token",
        owner_id: "owner_01",
      }).success,
    ).toBe(false);
    expect(OwnerCreateResponseSchema.safeParse({ owner_token: "" }).success).toBe(false);
  });

  it("accepts a normalized quota envelope", () => {
    const result = QuotaSnapshotEnvelopeSchema.safeParse({
      schema_version: 1,
      device_id: "device_01",
      sequence: 42,
      captured_at: "2026-08-02T12:00:00Z",
      snapshots: [
        {
          provider: "codex",
          account: {
            fingerprint: "account_01",
            fingerprint_scope: "global",
            plan: "plus",
          },
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

  it("bounds a snapshot envelope to the D1 request query budget", () => {
    const envelope = envelopeWithAccount({
      fingerprint: "account_01",
      fingerprint_scope: "source",
    });
    const item = envelope.snapshots[0];
    expect(item).toBeDefined();
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        snapshots: Array.from({ length: MAXIMUM_SNAPSHOTS_PER_ENVELOPE }, () => item),
      }).success,
    ).toBe(true);
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        snapshots: Array.from({ length: MAXIMUM_SNAPSHOTS_PER_ENVELOPE + 1 }, () => item),
      }).success,
    ).toBe(false);
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
              account: { fingerprint: "account_01", fingerprint_scope: "source" },
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

  it("requires a valid fingerprint scope", () => {
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse(envelopeWithAccount({ fingerprint: "v1-account" }))
        .success,
    ).toBe(false);
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse(
        envelopeWithAccount({ fingerprint: "account_01", fingerprint_scope: "provider" }),
      ).success,
    ).toBe(false);
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
      version: "0.0.1",
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

  it("validates the exact pairing creation and polling payloads", () => {
    expect(
      PairingCreateRequestSchema.safeParse({ device_display_name: "Kitchen Mac" }).success,
    ).toBe(true);
    expect(PairingCreateRequestSchema.safeParse({ device_display_name: "   " }).success).toBe(
      false,
    );
    expect(
      PairingCreateResponseSchema.safeParse({
        device_code: "device-secret",
        user_code: "ABCD-EFGH",
        expires_at: "2026-08-02T12:10:00Z",
        poll_interval_seconds: 5,
      }).success,
    ).toBe(true);
    expect(PairingTokenRequestSchema.safeParse({ device_code: "device-secret" }).success).toBe(
      true,
    );
    expect(PairingTokenRequestSchema.safeParse({ device_code: "   " }).success).toBe(false);
    expect(
      PairingTokenPendingResponseSchema.safeParse({
        status: "pending",
        poll_interval_seconds: 5,
      }).success,
    ).toBe(true);
    expect(
      PairingTokenIssuedResponseSchema.safeParse({
        device_id: "device_01",
        device_token: "relay-device-secret",
      }).success,
    ).toBe(true);

    expect(
      PairingCreateResponseSchema.safeParse({
        device_code: "device-secret",
        user_code: "ABCD-EFGH",
        expires_at: "2026-08-02T12:10:00Z",
        poll_interval_seconds: 5,
        verification_uri: "https://quota.gotry.io/pair",
      }).success,
    ).toBe(false);
    expect(
      PairingTokenPendingResponseSchema.safeParse({
        status: "issued",
        poll_interval_seconds: 5,
      }).success,
    ).toBe(false);
    expect(
      PairingTokenIssuedResponseSchema.safeParse({
        status: "issued",
        device_id: "device_01",
        device_token: "relay-device-secret",
      }).success,
    ).toBe(false);
  });

  it("keeps approval and denial request bodies route-specific and strict", () => {
    expect(PairingApprovalRequestSchema.safeParse({ user_code: "ABCD-EFGH" }).success).toBe(true);
    expect(PairingDenialRequestSchema.safeParse({ user_code: "ABCD-EFGH" }).success).toBe(true);
    expect(PairingApprovalRequestSchema.safeParse({ user_code: "   " }).success).toBe(false);
    expect(
      PairingApprovalRequestSchema.safeParse({
        user_code: "ABCD-EFGH",
        status: "approved",
      }).success,
    ).toBe(false);
    expect(PairingDenialRequestSchema.safeParse({}).success).toBe(false);
  });

  it("uses stable Relay error codes in a strict envelope", () => {
    const codes = [
      "invalid_request",
      "unauthorized",
      "forbidden",
      "not_found",
      "pairing_denied",
      "pairing_expired",
      "pairing_consumed",
      "rate_limited",
      "conflict",
      "internal_error",
    ] as const;

    for (const code of codes) {
      expect(
        RelayErrorEnvelopeSchema.safeParse({ error: { code, message: "Safe message" } }).success,
      ).toBe(true);
    }
    expect(
      RelayErrorEnvelopeSchema.safeParse({
        error: { code: "storage_failure", message: "Unsafe implementation detail" },
      }).success,
    ).toBe(false);
    expect(
      RelayErrorEnvelopeSchema.safeParse({
        error: { code: "not_found", message: "Missing", retryable: false },
      }).success,
    ).toBe(false);
  });

  it("validates owner observations and device lists without leaking owner fields", () => {
    expect(
      OwnerSnapshotListResponseSchema.safeParse({
        observations: [
          {
            device_id: "device_01",
            sequence: 3,
            captured_at: "2026-08-02T12:00:00Z",
            snapshot: snapshot("codex"),
            updated_at: "2026-08-02T12:00:01Z",
          },
        ],
      }).success,
    ).toBe(true);
    expect(
      OwnerSnapshotListResponseSchema.safeParse({
        observations: [
          {
            device_id: "device_01",
            display_name: "Kitchen Mac",
            sequence: 3,
            captured_at: "2026-08-02T12:00:00Z",
            snapshot: snapshot("codex"),
            updated_at: "2026-08-02T12:00:01Z",
          },
        ],
      }).success,
    ).toBe(false);

    expect(
      DeviceListResponseSchema.safeParse({
        devices: [
          {
            device_id: "device_01",
            display_name: "Kitchen Mac",
            created_at: "2026-08-02T12:00:00Z",
            last_seen_at: null,
            last_sequence: -1,
            revoked_at: null,
          },
        ],
      }).success,
    ).toBe(true);
    expect(
      DeviceListResponseSchema.safeParse({
        devices: [
          {
            device_id: "device_01",
            owner_id: "owner_01",
            display_name: "Kitchen Mac",
            created_at: "2026-08-02T12:00:00Z",
            last_seen_at: null,
            last_sequence: -1,
            revoked_at: null,
          },
        ],
      }).success,
    ).toBe(false);
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

function snapshot(
  provider: "codex" | "claude" | "grok" | "openrouter" | "deepseek" | "kimi" | "litellm",
) {
  return {
    provider,
    account: { fingerprint: `${provider}-fixture`, fingerprint_scope: "source" as const },
    windows: [{ id: "five_hour", title: "5 hour", used_percent: 10 }],
    source: "fixture",
    status: "available" as const,
    observed_at: "2026-08-02T12:00:00Z",
  };
}

function envelopeWithAccount(account: Record<string, string>) {
  return {
    schema_version: 1,
    device_id: "device_01",
    sequence: 1,
    captured_at: "2026-08-02T12:00:00Z",
    snapshots: [
      {
        provider: "codex",
        account,
        windows: [],
        source: "fixture",
        status: "available",
        observed_at: "2026-08-02T12:00:00Z",
      },
    ],
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
