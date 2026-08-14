import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import {
  AccountDevicesResponseSchema,
  AccountQuotaResponseSchema,
  AccountQuotaResponseV3Schema,
  AccountResponseSchema,
  AccountSummarySchema,
  AccountSummaryV3Schema,
  PublicProfileSchema,
  PublicProfileSettingsSchema,
  PublicProfileUpdateRequestSchema,
  AccountUsageHourlyResponseSchema,
  AccountUsageHourlyResponseV3Schema,
  AccountUsageResponseSchema,
  AccountUsageResponseV3Schema,
  AccountUsageSummaryV3Schema,
  AccountUsageSummarySchema,
  BrowserLoginExchangeRequestSchema,
  DeleteDeviceResponseSchema,
  DeviceAuthorizationDecisionRequestSchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  DeviceSyncResponseSchema,
  LogoutResponseSchema,
  LocalUsageReportSchema,
  LocalUsageReportV2Schema,
  ModelCatalogSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PricingCatalogSchema,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotEnvelopeV3Schema,
  QuotaSnapshotUploadResponseSchema,
  QuotaSnapshotUploadResponseV3Schema,
  RelayErrorEnvelopeSchema,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  UsageSubmissionSchema,
  UsageSubmissionV3Schema,
  UsageUploadResponseSchema,
  UsageUploadResponseV3Schema,
} from "../src/index.ts";

const directory = join(dirname(fileURLToPath(import.meta.url)), "../schema");

const AccountHttpPayloadSchema = z.union([
  AccountResponseSchema,
  AccountDevicesResponseSchema,
  AccountQuotaResponseSchema,
  AccountSummarySchema,
  PublicProfileSchema,
  PublicProfileSettingsSchema,
  PublicProfileUpdateRequestSchema,
  AccountUsageResponseSchema,
  AccountUsageHourlyResponseSchema,
  BrowserLoginExchangeRequestSchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceAuthorizationDecisionRequestSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  DeviceSyncResponseSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  LogoutResponseSchema,
  DeleteDeviceResponseSchema,
  QuotaSnapshotUploadResponseSchema,
  RelayErrorEnvelopeSchema,
]);

const UsagePayloadSchema = z.union([
  UsageSubmissionSchema,
  UsageUploadResponseSchema,
  AccountUsageSummarySchema,
  LocalUsageReportV2Schema,
]);

const AccountHttpV3PayloadSchema = z.union([
  AccountQuotaResponseV3Schema,
  AccountSummaryV3Schema,
  AccountUsageResponseV3Schema,
  AccountUsageHourlyResponseV3Schema,
  QuotaSnapshotUploadResponseV3Schema,
  UsageUploadResponseV3Schema,
  RelayErrorEnvelopeSchema,
]);

const UsageV3PayloadSchema = z.union([
  UsageSubmissionV3Schema,
  UsageUploadResponseV3Schema,
  AccountUsageSummaryV3Schema,
]);

const outputs = [
  {
    filename: "quota-snapshot-v2.json",
    title: "Quota snapshot upload v2",
    schema: QuotaSnapshotEnvelopeSchema,
    comment: "Device-scoped quota upload. The device token must match device_id and generation.",
  },
  {
    filename: "quota-snapshot-v3.json",
    title: "Quota snapshot upload v3",
    schema: QuotaSnapshotEnvelopeV3Schema,
    comment: "Device-scoped quota upload with the current managed provider catalog.",
  },
  {
    filename: "quota-collection-report-v2.json",
    title: "Quota local collection report v2",
    schema: QuotaCollectionReportSchema,
    comment: "Success snapshots must use the same provider as their collection result.",
  },
  {
    filename: "account-http-v2.json",
    title: "Quota account HTTP payloads v2",
    schema: AccountHttpPayloadSchema,
    comment: "Direct Account to Device managed contract.",
  },
  {
    filename: "account-http-v3.json",
    title: "Quota managed data HTTP payloads v3",
    schema: AccountHttpV3PayloadSchema,
    comment: "Quota and Usage managed data contracts; OAuth and device control remain v2.",
  },
  {
    filename: "usage-v2.json",
    title: "Quota Usage payloads v2",
    schema: UsagePayloadSchema,
    comment:
      "Runtime validation additionally enforces token subset conservation, source-cost coverage, unique same-agent contained rows, and bounded ordered UTC-hour coverage.",
  },
  {
    filename: "usage-v3.json",
    title: "Quota Usage payloads v3",
    schema: UsageV3PayloadSchema,
    comment:
      "Adds Cursor while preserving the v2 token, identity, coverage, and integrity invariants.",
  },
  {
    filename: "local-usage-v3.json",
    title: "Quota local Usage report v3",
    schema: LocalUsageReportSchema,
    comment:
      "Local-only Usage collection status and coverage; period summaries are precomputed in the private state snapshot.",
  },
  {
    filename: "pricing-catalog-v2.json",
    title: "Quota pricing catalog v2",
    schema: PricingCatalogSchema,
    comment:
      "quota-model additionally rejects duplicate IDs and entries whose channel/model/effective range/dimensions could resolve ambiguously.",
  },
  {
    filename: "model-catalog-v1.json",
    title: "Quota report-time model catalog v1",
    schema: ModelCatalogSchema,
    comment:
      "The catalog source is packages/protocol/catalog/model-catalog.json; quota-model additionally rejects duplicate IDs and overlapping aliases.",
  },
] as const;

mkdirSync(directory, { recursive: true });
for (const output of outputs) {
  const generated = z.toJSONSchema(output.schema, {
    target: "draft-2020-12",
    io: "input",
    reused: "ref",
  });
  const document = {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: `https://quota.gotry.io/schema/${output.filename}`,
    title: output.title,
    $comment: output.comment,
    ...generated,
  };
  writeFileSync(join(directory, output.filename), `${JSON.stringify(document, null, 2)}\n`);
}
