import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import {
  AccountDevicesResponseSchema,
  AccountQuotaResponseSchema,
  AccountResponseSchema,
  AccountSummarySchema,
  AccountUsageHourlyResponseSchema,
  AccountUsageResponseSchema,
  AccountUsageSummarySchema,
  BrowserLoginExchangeRequestSchema,
  DeleteDeviceResponseSchema,
  DeviceAuthorizationDecisionRequestSchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceHealthUploadRequestSchema,
  DeviceHealthUploadResponseSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  DeviceSyncResponseSchema,
  IosLoginExchangeRequestSchema,
  IosOAuthTokenResponseSchema,
  IosSessionRefreshRequestSchema,
  LocalUsageReportSchema,
  LogoutResponseSchema,
  ModelCatalogSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PricingCatalogSchema,
  PublicProfileSchema,
  PublicProfileSettingsSchema,
  PublicProfileUpdateRequestSchema,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotUploadResponseSchema,
  RelayErrorEnvelopeSchema,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  UsageSubmissionSchema,
  UsageUploadResponseSchema,
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
  IosLoginExchangeRequestSchema,
  IosOAuthTokenResponseSchema,
  IosSessionRefreshRequestSchema,
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
  DeviceHealthUploadRequestSchema,
  DeviceHealthUploadResponseSchema,
  LogoutResponseSchema,
  DeleteDeviceResponseSchema,
  QuotaSnapshotUploadResponseSchema,
  RelayErrorEnvelopeSchema,
]);

const UsagePayloadSchema = z.union([
  UsageSubmissionSchema,
  UsageUploadResponseSchema,
  AccountUsageSummarySchema,
]);

const outputs = [
  {
    filename: "quota-snapshot.json",
    title: "Quota snapshot upload",
    schema: QuotaSnapshotEnvelopeSchema,
    comment: "Device-scoped quota upload. The device token must match device_id and generation.",
  },
  {
    filename: "quota-collection-report.json",
    title: "Quota local collection report",
    schema: QuotaCollectionReportSchema,
    comment: "Success snapshots must use the same provider as their collection result.",
  },
  {
    filename: "account-http.json",
    title: "Quota account HTTP payloads",
    schema: AccountHttpPayloadSchema,
    comment: "Direct Account to Device managed contract.",
  },
  {
    filename: "usage.json",
    title: "Quota Usage payloads",
    schema: UsagePayloadSchema,
    comment:
      "Runtime validation additionally enforces token subset conservation, source-cost coverage, unique same-agent contained rows, and bounded ordered UTC-hour coverage.",
  },
  {
    filename: "local-usage.json",
    title: "Quota local Usage report",
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
