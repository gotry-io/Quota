import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;
export const MAXIMUM_SNAPSHOTS_PER_ENVELOPE = 32;

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

export const FingerprintScopeSchema = z.enum(["global", "source"]);
export type FingerprintScope = z.infer<typeof FingerprintScopeSchema>;

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
    fingerprint_scope: FingerprintScopeSchema,
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
    snapshots: z.array(QuotaSnapshotSchema).max(MAXIMUM_SNAPSHOTS_PER_ENVELOPE),
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

export const RelayErrorCodeSchema = z.enum([
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
]);
export type RelayErrorCode = z.infer<typeof RelayErrorCodeSchema>;

export const RelayErrorEnvelopeSchema = z
  .object({
    error: z
      .object({
        code: RelayErrorCodeSchema,
        message: z.string().min(1),
      })
      .strict(),
  })
  .strict();
export type RelayErrorEnvelope = z.infer<typeof RelayErrorEnvelopeSchema>;

export const OwnerCreateResponseSchema = z
  .object({
    owner_token: z.string().min(1),
  })
  .strict();
export type OwnerCreateResponse = z.infer<typeof OwnerCreateResponseSchema>;

export const PairingCreateRequestSchema = z
  .object({
    device_display_name: z.string().trim().min(1).max(128),
  })
  .strict();
export type PairingCreateRequest = z.infer<typeof PairingCreateRequestSchema>;

export const PairingCreateResponseSchema = z
  .object({
    device_code: z.string().trim().min(1),
    user_code: z.string().trim().min(1),
    expires_at: z.string().datetime({ offset: true }),
    poll_interval_seconds: z.number().int().positive(),
  })
  .strict();
export type PairingCreateResponse = z.infer<typeof PairingCreateResponseSchema>;

export const PairingTokenRequestSchema = z
  .object({
    device_code: z.string().trim().min(1),
  })
  .strict();
export type PairingTokenRequest = z.infer<typeof PairingTokenRequestSchema>;

export const PairingTokenPendingResponseSchema = z
  .object({
    status: z.literal("pending"),
    poll_interval_seconds: z.number().int().positive(),
  })
  .strict();
export type PairingTokenPendingResponse = z.infer<typeof PairingTokenPendingResponseSchema>;

export const PairingTokenIssuedResponseSchema = z
  .object({
    device_id: z.string().min(1),
    device_token: z.string().min(1),
  })
  .strict();
export type PairingTokenIssuedResponse = z.infer<typeof PairingTokenIssuedResponseSchema>;

export const PairingApprovalRequestSchema = z
  .object({
    user_code: z.string().trim().min(1),
  })
  .strict();
export type PairingApprovalRequest = z.infer<typeof PairingApprovalRequestSchema>;

export const PairingDenialRequestSchema = z
  .object({
    user_code: z.string().trim().min(1),
  })
  .strict();
export type PairingDenialRequest = z.infer<typeof PairingDenialRequestSchema>;

export const OwnerSnapshotObservationSchema = z
  .object({
    device_id: z.string().min(1),
    sequence: z.number().int().nonnegative(),
    captured_at: z.string().datetime({ offset: true }),
    snapshot: QuotaSnapshotSchema,
    updated_at: z.string().datetime({ offset: true }),
  })
  .strict();
export type OwnerSnapshotObservation = z.infer<typeof OwnerSnapshotObservationSchema>;

export const OwnerSnapshotListResponseSchema = z
  .object({
    observations: z.array(OwnerSnapshotObservationSchema),
  })
  .strict();
export type OwnerSnapshotListResponse = z.infer<typeof OwnerSnapshotListResponseSchema>;

export const RelayDeviceSchema = z
  .object({
    device_id: z.string().min(1),
    display_name: z.string().min(1),
    created_at: z.string().datetime({ offset: true }),
    last_seen_at: z.string().datetime({ offset: true }).nullable(),
    last_sequence: z.number().int().min(-1),
    revoked_at: z.string().datetime({ offset: true }).nullable(),
  })
  .strict();
export type RelayDevice = z.infer<typeof RelayDeviceSchema>;

export const DeviceListResponseSchema = z
  .object({
    devices: z.array(RelayDeviceSchema),
  })
  .strict();
export type DeviceListResponse = z.infer<typeof DeviceListResponseSchema>;

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
