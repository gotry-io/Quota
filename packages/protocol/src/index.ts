import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

export const ProviderIdSchema = z.enum(["codex", "claude", "grok"]);
export type ProviderId = z.infer<typeof ProviderIdSchema>;

export const QuotaStatusSchema = z.enum([
  "available",
  "stale",
  "auth_required",
  "unavailable",
  "unsupported",
  "error",
]);
export type QuotaStatus = z.infer<typeof QuotaStatusSchema>;

export const QuotaWindowSchema = z
  .object({
    id: z.string().min(1),
    title: z.string().min(1),
    used_percent: z.number().min(0).max(100),
    resets_at: z.string().datetime({ offset: true }).optional(),
    duration_seconds: z.number().int().nonnegative().optional(),
  })
  .strict();
export type QuotaWindow = z.infer<typeof QuotaWindowSchema>;

export const QuotaAccountSchema = z
  .object({
    fingerprint: z.string().min(1),
    label: z.string().min(1).optional(),
    plan: z.string().min(1).optional(),
  })
  .strict();
export type QuotaAccount = z.infer<typeof QuotaAccountSchema>;

export const QuotaSnapshotSchema = z
  .object({
    provider: ProviderIdSchema,
    account: QuotaAccountSchema,
    windows: z.array(QuotaWindowSchema),
    source: z.string().min(1),
    status: QuotaStatusSchema,
    observed_at: z.string().datetime({ offset: true }),
    valid_until: z.string().datetime({ offset: true }).optional(),
  })
  .strict();
export type QuotaSnapshot = z.infer<typeof QuotaSnapshotSchema>;

export const QuotaSnapshotEnvelopeSchema = z
  .object({
    schema_version: z.literal(PROTOCOL_VERSION),
    device_id: z.string().min(1),
    sequence: z.number().int().nonnegative(),
    captured_at: z.string().datetime({ offset: true }),
    snapshots: z.array(QuotaSnapshotSchema),
  })
  .strict();
export type QuotaSnapshotEnvelope = z.infer<typeof QuotaSnapshotEnvelopeSchema>;

export const CollectionOutcomeSchema = z.enum([
  "success",
  "auth_required",
  "unavailable",
  "unsupported",
  "error",
]);
export type CollectionOutcome = z.infer<typeof CollectionOutcomeSchema>;

const QuotaCollectionSuccessResultSchema = z
  .object({
    provider: ProviderIdSchema,
    outcome: z.literal("success"),
    snapshots: z.array(QuotaSnapshotSchema).min(1),
    source: z.string().min(1).optional(),
    message: z.string().min(1).optional(),
  })
  .strict();

const QuotaCollectionFailureResultSchema = z
  .object({
    provider: ProviderIdSchema,
    outcome: z.enum(["auth_required", "unavailable", "unsupported", "error"]),
    snapshots: z.array(QuotaSnapshotSchema).max(0),
    source: z.string().min(1).optional(),
    message: z.string().min(1).optional(),
  })
  .strict();

export const QuotaCollectionResultSchema = z
  .discriminatedUnion("outcome", [
    QuotaCollectionSuccessResultSchema,
    QuotaCollectionFailureResultSchema,
  ])
  .superRefine((result, context) => {
    for (const [index, snapshot] of result.snapshots.entries()) {
      if (snapshot.provider !== result.provider) {
        context.addIssue({
          code: "custom",
          path: ["snapshots", index, "provider"],
          message: "Snapshot provider must match collection result provider.",
        });
      }
    }
  });
export type QuotaCollectionResult = z.infer<typeof QuotaCollectionResultSchema>;

export const QuotaCollectionReportSchema = z
  .object({
    schema_version: z.literal(PROTOCOL_VERSION),
    captured_at: z.string().datetime({ offset: true }),
    results: z.array(QuotaCollectionResultSchema),
  })
  .strict();
export type QuotaCollectionReport = z.infer<typeof QuotaCollectionReportSchema>;

export const RelayCapabilitiesSchema = z
  .object({
    realtime: z.boolean(),
    persistent_snapshots: z.boolean(),
    instant_device_revocation: z.boolean(),
    history: z.boolean(),
    multi_tenant: z.boolean(),
  })
  .strict();
export type RelayCapabilities = z.infer<typeof RelayCapabilitiesSchema>;

export const RelayInfoSchema = z
  .object({
    instance_id: z.string().min(1),
    mode: z.enum(["managed", "self_hosted"]),
    version: z.string().min(1),
    api_versions: z.array(z.literal(PROTOCOL_VERSION)).min(1),
    auth_methods: z.array(z.literal("bearer")),
    capabilities: RelayCapabilitiesSchema,
  })
  .strict();
export type RelayInfo = z.infer<typeof RelayInfoSchema>;

const RelayHelloMessageSchema = z
  .object({
    type: z.literal("hello"),
    protocol_version: z.literal(PROTOCOL_VERSION),
    connection_id: z.string().min(1),
  })
  .strict();

const RelaySnapshotPushMessageSchema = z
  .object({
    type: z.literal("snapshot.push"),
    request_id: z.string().min(1),
    payload: QuotaSnapshotEnvelopeSchema,
  })
  .strict();

const RelaySnapshotRequestMessageSchema = z
  .object({
    type: z.literal("snapshot.request"),
    request_id: z.string().min(1),
    device_ids: z.array(z.string().min(1)),
  })
  .strict();

const RelayErrorMessageSchema = z
  .object({
    type: z.literal("error"),
    request_id: z.string().min(1).optional(),
    code: z.string().min(1),
    message: z.string().min(1),
  })
  .strict();

export const RelayMessageSchema = z.discriminatedUnion("type", [
  RelayHelloMessageSchema,
  RelaySnapshotPushMessageSchema,
  RelaySnapshotRequestMessageSchema,
  RelayErrorMessageSchema,
]);
export type RelayMessage = z.infer<typeof RelayMessageSchema>;
