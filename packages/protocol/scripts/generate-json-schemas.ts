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
  DeviceSyncResponseSchema,
  LogoutResponseSchema,
  LocalUsageReportSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PricingCatalogSchema,
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
  LogoutResponseSchema,
  DeleteDeviceResponseSchema,
  QuotaSnapshotUploadResponseSchema,
  RelayErrorEnvelopeSchema,
]);

const UsagePayloadSchema = z.union([
  UsageSubmissionSchema,
  UsageUploadResponseSchema,
  AccountUsageSummarySchema,
  LocalUsageReportSchema,
]);

const outputs = [
  {
    filename: "quota-snapshot-v2.json",
    title: "Quota snapshot upload v2",
    schema: QuotaSnapshotEnvelopeSchema,
    comment: "Device-scoped quota upload. The device token must match device_id and generation.",
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
    filename: "usage-v2.json",
    title: "Quota Usage payloads v2",
    schema: UsagePayloadSchema,
    comment:
      "Runtime validation additionally enforces token subset conservation, source-cost coverage, unique same-agent contained rows, and bounded ordered UTC-hour coverage.",
  },
  {
    filename: "pricing-catalog-v2.json",
    title: "Quota pricing catalog v2",
    schema: PricingCatalogSchema,
    comment:
      "quota-model additionally rejects duplicate IDs and entries whose channel/model/effective range/dimensions could resolve ambiguously.",
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
