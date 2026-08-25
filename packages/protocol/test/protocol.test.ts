import { readdir, readFile } from "node:fs/promises";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import * as protocol from "../src/index.ts";
import {
  AccountQuotaResponseSchema,
  AccountSummarySchema,
  AccountUsageResponseSchema,
  BrowserLoginExchangeRequestSchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  DeviceSyncResponseSchema,
  IOS_OAUTH_CLIENT_ID,
  IOS_OAUTH_REDIRECT_URI,
  IosLoginExchangeRequestSchema,
  IosOAuthTokenResponseSchema,
  IosSessionRefreshRequestSchema,
  LOCAL_PROVIDER_IDS,
  LOCAL_COLLECTION_PROTOCOL_VERSION,
  LOCAL_USAGE_PROTOCOL_VERSION,
  LocalProviderIdSchema,
  LocalUsageReportSchema,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_SNAPSHOTS_PER_ENVELOPE,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PricingCatalogSchema,
  PROTOCOL_VERSION,
  PROVIDER_IDS,
  ProviderIdSchema,
  PublicProfileSchema,
  PublicProfileSettingsSchema,
  PublicProfileUpdateRequestSchema,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotUploadResponseSchema,
  SessionRefreshResponseSchema,
  UsageBreakdownSchema,
  UsageHourlyFactSchema,
  UsageSubmissionSchema,
} from "../src/index.ts";

describe("quota protocol", () => {
  it("accepts every managed provider and keeps local-only collectors out of the wire", () => {
    expect(PROVIDER_IDS).toContain("cursor");
    expect(ProviderIdSchema.safeParse("cursor").success).toBe(true);
    expect(LOCAL_PROVIDER_IDS).toEqual(expect.arrayContaining([...PROVIDER_IDS]));
    expect(LocalProviderIdSchema.safeParse("cursor").success).toBe(true);
  });

  it("prices every billing channel except the unknown sentinel", () => {
    expect(protocol.BillingChannelSchema.options).toContain("moonshot_direct");
    expect(protocol.PricedBillingChannelSchema.options).toEqual(
      protocol.BillingChannelSchema.options.filter((channel) => channel !== "unknown"),
    );
  });

  it("carries one managed-data version on quota and Usage", () => {
    expect(MANAGED_DATA_PROTOCOL_VERSION).toBe(5);
    expect(protocol.BILLING_AGENTS).toContain("cursor");
    const cursorEnvelope = { ...quotaEnvelope(), snapshots: [snapshot("cursor")] };
    expect(QuotaSnapshotEnvelopeSchema.safeParse(cursorEnvelope).success).toBe(true);
    // The shared fixture owns the retired managed-data version; this pins the control one,
    // which no data contract ever accepted.
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({ ...cursorEnvelope, protocol_version: 2 }).success,
    ).toBe(false);

    const cursorUsage = {
      ...usageSubmission(),
      coverage: { ...usageSubmission().coverage, agent: "cursor" as const },
      rows: usageSubmission().rows.map((row) => ({ ...row, agent: "cursor" as const })),
    };
    expect(UsageSubmissionSchema.safeParse(cursorUsage).success).toBe(true);
    expect(UsageSubmissionSchema.safeParse({ ...cursorUsage, protocol_version: 2 }).success).toBe(
      false,
    );
  });

  it("carries Device Health on every summary Device", () => {
    const summary = accountSummary();
    expect(AccountSummarySchema.safeParse(summary).success).toBe(true);
    // `health` is required and nullable: a Device that has never reported says so.
    expect(summary.devices.every((device) => device.health === null)).toBe(true);
    const missing = {
      ...summary,
      devices: summary.devices.map(({ health: _health, ...device }) => device),
    };
    expect(AccountSummarySchema.safeParse(missing).success).toBe(false);
  });

  it("accepts the sole quota upload contract with device generation", () => {
    const envelope = quotaEnvelope();
    expect(QuotaSnapshotEnvelopeSchema.parse(envelope)).toEqual(envelope);
    expect(PROTOCOL_VERSION).toBe(2);
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        protocol_version: undefined,
        schema_version: 1,
      }).success,
    ).toBe(false);
    expect(QuotaSnapshotEnvelopeSchema.safeParse({ ...envelope, generation: 0 }).success).toBe(
      false,
    );
  });

  it("bounds snapshot uploads and validates their acceptance response", () => {
    const envelope = quotaEnvelope();
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
    expect(
      QuotaSnapshotUploadResponseSchema.safeParse({
        protocol_version: 5,
        outcome: "accepted",
        device_id: "device_01",
        device_generation: 3,
        accepted_sequence: 42,
        next_snapshot_sequence: 43,
      }).success,
    ).toBe(true);
  });

  it("requires a reason only for a terminally rejected Usage upload", () => {
    const rejected = {
      protocol_version: 5,
      outcome: "rejected",
      device_id: "device_01",
      device_generation: 3,
      accepted_sequence: null,
      next_sequence: 43,
      usage_sync_revision: 9,
      deleted_before: null,
      rejection_reason: "duplicate_fact_identity",
    };
    expect(protocol.UsageUploadResponseSchema.safeParse(rejected).success).toBe(true);
    expect(
      protocol.UsageUploadResponseSchema.safeParse({
        ...rejected,
        rejection_reason: undefined,
      }).success,
    ).toBe(false);
    expect(
      protocol.UsageUploadResponseSchema.safeParse({
        ...rejected,
        outcome: "accepted",
        accepted_sequence: 42,
      }).success,
    ).toBe(false);
  });

  it("keeps absolute quota balances valid when their currency is not a wire unit", () => {
    const envelope = quotaEnvelope();
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        snapshots: [
          {
            ...envelope.snapshots[0],
            windows: [
              {
                id: "balance",
                title: "Balance",
                used_percent: 0,
                remaining_value: 12.34,
              },
            ],
          },
        ],
      }).success,
    ).toBe(true);
  });

  it("keeps public profiles opted-in and free of device identifiers", () => {
    const profile = {
      protocol_version: 2,
      username: "octocat",
      display_label: "octocat",
      quota: [
        {
          provider: "codex",
          plan: "Plus",
          windows: [{ title: "Weekly", used_percent: 25 }],
        },
      ],
      usage: {
        range: { from: "2026-08-01", to: "2026-08-13" },
        input_tokens: 10,
        output_tokens: 4,
        cost_status: "complete",
        amount_microusd: "1000",
        models: [{ name: "gpt-5", tokens: 14 }],
      },
    };
    expect(PublicProfileSchema.safeParse(profile).success).toBe(true);
    expect(
      PublicProfileSettingsSchema.safeParse({
        protocol_version: 2,
        enabled: false,
        slug: null,
      }).success,
    ).toBe(true);
    expect(
      PublicProfileUpdateRequestSchema.safeParse({
        protocol_version: 2,
        enabled: true,
        slug: "Octocat",
      }).success,
    ).toBe(false);
  });

  it("keeps local collection reports versioned, strict, and provider-consistent", () => {
    const report = {
      protocol_version: LOCAL_COLLECTION_PROTOCOL_VERSION,
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "codex",
          outcome: "success",
          snapshots: [snapshot("codex")],
        },
        {
          provider: "claude",
          outcome: "auth_required",
          snapshots: [],
          message: "Sign in again",
        },
        {
          // A refusal reads as unavailable to every other device and names itself here,
          // because only the Mac holding the credential can act on it.
          provider: "grok",
          outcome: "unavailable",
          snapshots: [],
          access_denied: true as const,
          message: "Check access",
        },
        {
          provider: "cursor",
          outcome: "success",
          snapshots: [snapshot("cursor")],
        },
      ],
    };
    expect(QuotaCollectionReportSchema.safeParse(report).success).toBe(true);
    expect(
      QuotaCollectionReportSchema.safeParse({
        ...report,
        results: [{ provider: "codex", outcome: "success", snapshots: [snapshot("claude")] }],
      }).success,
    ).toBe(false);
    expect(QuotaCollectionReportSchema.safeParse({ ...report, extra: true }).success).toBe(false);
  });

  it("defines strict native browser and device login payloads", () => {
    const installationID = "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998";
    const browser = {
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: "quotacli",
      code: "synthetic-login-code",
      code_verifier: "a".repeat(43),
      redirect_uri: "http://127.0.0.1:49152/callback",
      installation_id: installationID,
      device_display_name: "Kitchen Mac",
      platform: "macos",
    };
    expect(BrowserLoginExchangeRequestSchema.safeParse(browser).success).toBe(true);
    expect(OAuthTokenRequestSchema.safeParse(browser).success).toBe(true);
    expect(
      BrowserLoginExchangeRequestSchema.safeParse({
        ...browser,
        redirect_uri: "https://example.com/callback",
      }).success,
    ).toBe(false);
    expect(
      OAuthTokenRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: "quotacli",
        device_code: "synthetic-device-code",
      }).success,
    ).toBe(true);
    expect(
      DeviceAuthorizationRequestSchema.safeParse({
        protocol_version: 2,
        client_id: "quotacli",
        installation_id: installationID,
        device_display_name: "Kitchen Mac",
        platform: "macos",
      }).success,
    ).toBe(true);
    expect(
      DeviceAuthorizationResponseSchema.safeParse({
        protocol_version: 2,
        device_code: "synthetic-device-code",
        user_code: "ABCD-EFGH",
        verification_uri: "https://quota.gotry.io/activate",
        verification_uri_complete: null,
        expires_in: 600,
        interval: 5,
      }).success,
    ).toBe(true);
    expect(
      DeviceAuthorizationResponseSchema.safeParse({
        protocol_version: 2,
        device_code: "synthetic-device-code",
        user_code: "ABCD-EFGH",
        verification_uri: "http://quota.gotry.io/activate",
        verification_uri_complete: null,
        expires_in: 600,
        poll_interval_seconds: 5,
      }).success,
    ).toBe(false);
  });

  it("adds a strictly additive quota-ios account-only token contract", () => {
    const iosExchange = {
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: IOS_OAUTH_CLIENT_ID,
      code: "synthetic-login-code",
      code_verifier: "a".repeat(43),
      redirect_uri: IOS_OAUTH_REDIRECT_URI,
    };
    expect(IosLoginExchangeRequestSchema.safeParse(iosExchange).success).toBe(true);
    expect(OAuthTokenRequestSchema.safeParse(iosExchange).success).toBe(false);
    expect(
      IosLoginExchangeRequestSchema.safeParse({
        ...iosExchange,
        installation_id: "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998",
        device_display_name: "iPhone",
        platform: "ios",
      }).success,
    ).toBe(false);
    expect(
      IosLoginExchangeRequestSchema.safeParse({
        ...iosExchange,
        redirect_uri: "http://127.0.0.1:49152/callback",
      }).success,
    ).toBe(false);
    expect(
      IosLoginExchangeRequestSchema.safeParse({
        ...iosExchange,
        redirect_uri: "io.gotry.quota://oauth/callback",
      }).success,
    ).toBe(false);
    expect(protocol.PlatformSchema.safeParse("ios").success).toBe(false);
    expect(protocol.PlatformSchema.options).toEqual(["macos", "linux", "windows"]);

    const accountSession = {
      access_token: "synthetic-access-token",
      access_expires_at: "2026-08-02T12:15:00Z",
      refresh_token: "synthetic-refresh-token",
      refresh_expires_at: "2026-11-01T12:00:00Z",
    };
    const iosResponse = {
      protocol_version: 2,
      token_type: "Bearer",
      account_id: "account_01",
      account_session: accountSession,
    };
    expect(IosOAuthTokenResponseSchema.safeParse(iosResponse).success).toBe(true);
    expect(OAuthTokenResponseSchema.safeParse(iosResponse).success).toBe(false);
    expect(
      IosOAuthTokenResponseSchema.safeParse({
        ...iosResponse,
        device_id: "device_01",
        device_session: accountSession,
      }).success,
    ).toBe(false);
    expect(
      IosSessionRefreshRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: "synthetic-refresh-token",
      }).success,
    ).toBe(true);
    expect(
      IosSessionRefreshRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "device",
        refresh_token: "synthetic-refresh-token",
      }).success,
    ).toBe(false);
    expect(
      protocol.SessionRefreshRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        token_audience: "account",
        refresh_token: "synthetic-refresh-token",
      }).success,
    ).toBe(false);
  });

  it("returns separate account and device token families with authoritative sync control", () => {
    const token = {
      access_token: "synthetic-access-token",
      access_expires_at: "2026-08-02T12:15:00Z",
      refresh_token: "synthetic-refresh-token",
      refresh_expires_at: "2026-11-01T12:00:00Z",
    };
    const response = {
      protocol_version: 2,
      token_type: "Bearer",
      account_id: "account_01",
      device_id: "device_01",
      device_generation: 3,
      next_snapshot_sequence: 42,
      next_usage_sequence: 8,
      usage_deleted_before: null,
      usage_sync_revision: 9,
      account_session: token,
      device_session: token,
    };
    expect(OAuthTokenResponseSchema.safeParse(response).success).toBe(true);
    expect(
      DeviceSyncResponseSchema.safeParse({
        protocol_version: 2,
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
        next_snapshot_sequence: 42,
        next_usage_sequence: 8,
        usage_deleted_before: "2026-08-01T01:23:45.678Z",
        usage_sync_revision: 9,
      }).success,
    ).toBe(true);
    expect(
      DeviceProfileUpdateRequestSchema.safeParse({
        protocol_version: 2,
        display_name: "Studio Mac",
        platform: "macos",
      }).success,
    ).toBe(true);
    expect(
      DeviceProfileUpdateResponseSchema.safeParse({
        protocol_version: 2,
        status: "updated",
        device_id: "device_01",
      }).success,
    ).toBe(true);
    expect(
      SessionRefreshResponseSchema.safeParse({
        protocol_version: 2,
        token_type: "Bearer",
        token_audience: "device",
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
        device_session: token,
      }).success,
    ).toBe(true);
    expect(
      SessionRefreshResponseSchema.safeParse({
        protocol_version: 2,
        token_type: "Bearer",
        token_audience: "account",
        account_id: "account_01",
        device_id: "device_01",
        account_session: token,
      }).success,
    ).toBe(false);
  });

  it("validates token conservation and source-cost coverage on hourly facts", () => {
    const fact = usageFact();
    expect(UsageHourlyFactSchema.safeParse(fact).success).toBe(true);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, cache_read_tokens: 1_001 }).success).toBe(
      false,
    );
    expect(UsageHourlyFactSchema.safeParse({ ...fact, reasoning_tokens: 201 }).success).toBe(false);
    expect(
      UsageHourlyFactSchema.safeParse({
        ...fact,
        source_cost_microusd: "1200",
        source_cost_covered_requests: 0,
      }).success,
    ).toBe(false);
    expect(
      UsageHourlyFactSchema.safeParse({
        ...fact,
        billing_channel: "unknown",
        channel_source: "explicit",
      }).success,
    ).toBe(false);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, model: "GPT-5.5[1m]" }).success).toBe(true);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, model: "unknown" }).success).toBe(true);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, model: "😀".repeat(128) }).success).toBe(
      true,
    );
    expect(UsageHourlyFactSchema.safeParse({ ...fact, model: "😀".repeat(129) }).success).toBe(
      false,
    );
    expect(
      UsageHourlyFactSchema.safeParse({ ...fact, model: "model\u2028separator" }).success,
    ).toBe(true);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, model: "model\nwith-control" }).success).toBe(
      false,
    );
    expect(
      UsageHourlyFactSchema.safeParse({
        ...fact,
        agent: "grok",
        billing_channel: "xai_direct",
      }).success,
    ).toBe(true);
    expect(UsageHourlyFactSchema.safeParse({ ...fact, prompt: "secret" }).success).toBe(false);
  });

  it("uses the opaque model contract for model breakdown keys", () => {
    const breakdown = {
      dimension: "model" as const,
      key: "GPT-5.5[1m]",
      totals: emptyTotals(),
      cost: emptyCost(),
    };
    expect(UsageBreakdownSchema.safeParse(breakdown).success).toBe(true);
    expect(UsageBreakdownSchema.safeParse({ ...breakdown, key: "😀".repeat(128) }).success).toBe(
      true,
    );
    expect(UsageBreakdownSchema.safeParse({ ...breakdown, key: "😀".repeat(129) }).success).toBe(
      false,
    );
    expect(
      UsageBreakdownSchema.safeParse({ ...breakdown, key: "model\nwith-control" }).success,
    ).toBe(false);
    expect(
      UsageBreakdownSchema.safeParse({
        ...breakdown,
        dimension: "device",
        key: "d".repeat(128),
      }).success,
    ).toBe(true);
    expect(
      UsageBreakdownSchema.safeParse({
        ...breakdown,
        dimension: "device",
        key: "d".repeat(129),
      }).success,
    ).toBe(false);
  });

  it("requires canonical bounded UTC coverage and contained same-agent rows", () => {
    const submission = usageSubmission();
    expect(UsageSubmissionSchema.safeParse(submission).success).toBe(true);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [{ ...submission.rows[0], model: "unknown" }],
      }).success,
    ).toBe(true);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [{ ...submission.rows[0], model: "openrouter-3o[1m]" }],
      }).success,
    ).toBe(true);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: Array.from({ length: 65 }, (_, index) => ({
          ...submission.rows[0],
          model: `model-${index}`,
        })),
      }).success,
    ).toBe(true);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        write_mode: "merge_partial",
        coverage: { ...submission.coverage, status: "partial" },
        multipart: { batch_id: "batch_01", part_index: 0, part_count: 2 },
      }).success,
    ).toBe(true);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        multipart: { batch_id: "batch_01", part_index: 0, part_count: 65 },
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        coverage: { ...submission.coverage, start_at: "2026-08-02T00:30:00Z" },
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        coverage: { ...submission.coverage, start_at: "2023-02-29T00:00:00Z" },
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [{ ...submission.rows[0], usage_hour: 12 }],
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        coverage: { ...submission.coverage, end_at: submission.coverage.start_at },
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [{ ...submission.rows[0], bucket_start_utc: submission.coverage.end_at }],
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [{ ...submission.rows[0], agent: "claude_code" }],
      }).success,
    ).toBe(false);
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        rows: [submission.rows[0], { ...submission.rows[0] }],
      }).success,
    ).toBe(false);
  });

  it("validates account quota and Usage as one normalized read summary", () => {
    expect(AccountSummarySchema.safeParse(accountSummary()).success).toBe(true);
    expect(
      AccountQuotaResponseSchema.safeParse({
        protocol_version: 5,
        quota: accountSummary().quota,
      }).success,
    ).toBe(true);
    expect(
      AccountUsageResponseSchema.safeParse({
        protocol_version: 5,
        usage: accountSummary().usage,
      }).success,
    ).toBe(true);
    expect(
      AccountUsageResponseSchema.safeParse({
        protocol_version: 5,
        usage: {
          ...accountSummary().usage,
          cost: {
            ...emptyCost(),
            status: "unavailable",
            unpriced_rows: 2,
            unpriced: [
              {
                billing_channel: "openai_direct",
                model: "model-a",
                reason: "unknown_model",
                rows: 1,
              },
            ],
            unpriced_truncated: true,
          },
        },
      }).success,
    ).toBe(true);
    expect(
      AccountUsageResponseSchema.safeParse({
        protocol_version: 5,
        usage: {
          ...accountSummary().usage,
          cost: { ...emptyCost(), unpriced_truncated: false },
        },
      }).success,
    ).toBe(false);
    expect(
      AccountSummarySchema.safeParse({
        ...accountSummary(),
        devices: [{ ...accountSummary().devices[0], owner_id: "owner_legacy" }],
      }).success,
    ).toBe(false);
  });

  it("refuses a coverage window computed from a missing lower bound", () => {
    const submission = usageSubmission();
    expect(
      UsageSubmissionSchema.safeParse({
        ...submission,
        coverage: {
          ...submission.coverage,
          start_at: "1970-01-01T00:00:00Z",
          end_at: "1970-02-01T00:00:00Z",
        },
        rows: [],
      }).success,
    ).toBe(false);
    // The private local report states whatever range the app asked for and is not bounded here.
    expect(
      LocalUsageReportSchema.safeParse({
        protocol_version: LOCAL_USAGE_PROTOCOL_VERSION,
        generated_at: "2026-08-02T12:30:00Z",
        aggregation_timezone: "UTC",
        range: { from: "1970-01-01", to: "1970-02-01" },
        status: "partial",
        model_catalog_revision: null,
        coverage: [
          {
            agent: "codex",
            start_at: "1970-01-01T00:00:00Z",
            end_at: "1970-02-01T00:00:00Z",
            status: "partial",
          },
        ],
      }).success,
    ).toBe(true);
  });

  it("keeps local Usage available independently from an account", () => {
    const report = {
      protocol_version: 3,
      generated_at: "2026-08-02T12:30:00Z",
      aggregation_timezone: "Asia/Singapore",
      range: { from: "2026-07-04", to: "2026-08-02" },
      status: "partial",
      model_catalog_revision: "model_2026_08_02",
      coverage: [
        {
          agent: "codex",
          start_at: "2026-07-03T00:00:00Z",
          end_at: "2026-08-02T13:00:00Z",
          status: "partial",
        },
      ],
    };
    expect(LOCAL_USAGE_PROTOCOL_VERSION).toBe(3);
    const parsed = LocalUsageReportSchema.parse(report);
    expect(parsed.model_catalog_revision).toBe("model_2026_08_02");
    expect(LocalUsageReportSchema.safeParse({ ...report, status: "complete" }).success).toBe(false);
    expect(
      LocalUsageReportSchema.safeParse({
        ...report,
        status: "unavailable",
        aggregation_timezone: null,
        model_catalog_revision: null,
        coverage: [],
      }).success,
    ).toBe(true);
    expect(
      LocalUsageReportSchema.safeParse({
        ...report,
        aggregation_timezone: null,
      }).success,
    ).toBe(false);
    expect(
      LocalUsageReportSchema.safeParse({ ...report, model_catalog_revision: undefined }).success,
    ).toBe(false);
  });

  it("validates a versioned effective-dated pricing catalog without embedding prices", () => {
    expect(PricingCatalogSchema.safeParse(pricingCatalog()).success).toBe(true);
    expect(
      PricingCatalogSchema.safeParse({
        ...pricingCatalog(),
        entries: [{ ...pricingCatalog().entries[0], effective_to: "2026-01-01" }],
      }).success,
    ).toBe(false);
    expect(
      PricingCatalogSchema.safeParse({
        ...pricingCatalog(),
        entries: [{ ...pricingCatalog().entries[0], source_url: "http://prices.invalid" }],
      }).success,
    ).toBe(false);
  });

  it("does not export owner, pairing, discovery, or self-hosted protocol surfaces", () => {
    expect(
      Object.keys(protocol).filter((name) =>
        /Owner|Pairing|RelayInfo|RelayMessage|SelfHosted/i.test(name),
      ),
    ).toEqual([]);
  });

  it("keeps versioned JSON Schema identifiers and references locally resolvable", async () => {
    const schemaDirectory = fileURLToPath(new URL("../schema/", import.meta.url));
    const schemaFiles = (await readdir(schemaDirectory))
      .filter((file) => file.endsWith(".json"))
      .sort();
    expect(schemaFiles.length).toBeGreaterThan(0);
    expect(schemaFiles).toContain("model-catalog-v1.json");
    expect(schemaFiles).toContain("local-usage.json");
    expect(schemaFiles).toContain("quota-snapshot.json");
    // Only a separately versioned catalog carries a version in its name.
    expect(schemaFiles.filter((file) => /-v\d+\.json$/.test(file))).toEqual([
      "model-catalog-v1.json",
      "pricing-catalog-v2.json",
    ]);

    for (const schemaFile of schemaFiles) {
      const schema = JSON.parse(await readFile(`${schemaDirectory}/${schemaFile}`, "utf8")) as {
        $id: string;
      };
      expect(basename(new URL(schema.$id).pathname)).toBe(schemaFile);
      for (const reference of collectSchemaReferences(schema)) {
        const referencedFile = reference.split("#", 1)[0];
        if (referencedFile) expect(schemaFiles).toContain(referencedFile);
      }
    }
  });
});

function snapshot(provider: "codex" | "claude" | "cursor") {
  return {
    provider,
    account: { fingerprint: `${provider}-fixture`, fingerprint_scope: "source" as const },
    windows: [{ id: "five_hour", title: "5 hour", used_percent: 10 }],
    status: "available" as const,
    observed_at: "2026-08-02T12:00:00Z",
  };
}

function quotaEnvelope() {
  return {
    protocol_version: 5 as const,
    device_id: "device_01",
    generation: 3,
    sequence: 42,
    captured_at: "2026-08-02T12:00:00Z",
    snapshots: [snapshot("codex")],
  };
}

function usageFact() {
  return {
    bucket_start_utc: "2026-08-02T12:00:00Z",
    usage_date: "2026-08-02",
    usage_hour: 20,
    agent: "codex" as const,
    billing_channel: "openai_direct" as const,
    channel_source: "agent_default" as const,
    model: "gpt-5",
    context_bucket: "le_128k" as const,
    service_tier: "default",
    speed: "standard",
    inference_geo: "global",
    input_tokens: 1_000,
    cache_read_tokens: 100,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 200,
    reasoning_tokens: 50,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
  };
}

function usageSubmission() {
  return {
    protocol_version: 5 as const,
    submission_id: "submission_01",
    device_id: "device_01",
    generation: 3,
    sequence: 7,
    parser_revision: "parser_1",
    aggregation_timezone: "Asia/Singapore",
    coverage: {
      agent: "codex" as const,
      start_at: "2026-08-02T12:00:00Z",
      end_at: "2026-08-02T13:00:00Z",
      status: "complete" as const,
    },
    rows: [usageFact()],
  };
}

function emptyTotals() {
  return {
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 0,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: null,
    source_cost_covered_requests: 0,
  };
}

function emptyCost() {
  return {
    mode: "calculate" as const,
    basis: "none" as const,
    status: "complete" as const,
    amount_microusd: null,
    catalog_revision: null,
    calculated_rows: 0,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
  };
}

function accountSummary() {
  return {
    protocol_version: 5 as const,
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-07-01T00:00:00Z",
    },
    devices: [
      {
        device_id: "device_01",
        display_name: "Kitchen Mac",
        platform: "macos" as const,
        device_generation: 3,
        status: "active" as const,
        created_at: "2026-07-01T00:00:00Z",
        last_login_at: "2026-08-01T00:00:00Z",
        last_seen_at: "2026-08-02T12:00:00Z",
        signed_out_at: null,
        health: null,
      },
    ],
    quota: [{ device_id: "device_01", snapshot: snapshot("codex") }],
    usage: {
      range: { from: "2026-08-01", to: "2026-08-02" },
      totals: emptyTotals(),
      cost: emptyCost(),
      coverage: "complete",
      breakdowns: [],
    },
  };
}

function pricingCatalog() {
  return {
    protocol_version: 2 as const,
    revision: "pricing_2026_08_02",
    published_at: "2026-08-02T00:00:00Z",
    entries: [
      {
        entry_id: "openai_gpt_5_default",
        billing_channel: "openai_direct" as const,
        model: "gpt-5",
        aliases: ["gpt-5-latest"],
        effective_from: "2026-08-01",
        effective_to: null,
        service_tier: "default",
        speed: "standard",
        inference_geo: "global",
        context_bucket: "le_128k" as const,
        currency: "USD" as const,
        rates: {
          uncached_input_per_million: "1.25",
          cache_read_per_million: "0.125",
          cache_write_5m_per_million: null,
          cache_write_1h_per_million: null,
          cache_write_inferred_per_million: null,
          output_per_million: "10",
          web_search_per_request: null,
          web_fetch_per_request: null,
        },
        source_url: "https://example.com/pricing",
        verified_at: "2026-08-02T00:00:00Z",
      },
    ],
  };
}

function collectSchemaReferences(value: unknown): string[] {
  if (Array.isArray(value)) return value.flatMap(collectSchemaReferences);
  if (!value || typeof value !== "object") return [];
  const record = value as Record<string, unknown>;
  const references =
    typeof record.$ref === "string" && !record.$ref.startsWith("#") ? [record.$ref] : [];
  return references.concat(Object.values(record).flatMap(collectSchemaReferences));
}
