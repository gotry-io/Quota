import { readdir, readFile } from "node:fs/promises";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import * as protocol from "../src/index.ts";
import {
  AccountSummaryReadSchema,
  AccountSummarySchema,
  AccountUsageActivityResponseReadSchema,
  AccountUsageActivityResponseSchema,
  BrowserLoginExchangeRequestSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  DeviceSyncResponseSchema,
  IOS_OAUTH_CLIENT_ID,
  IOS_OAUTH_REDIRECT_URI,
  IosLoginExchangeRequestSchema,
  IosOAuthTokenResponseSchema,
  IosSessionRefreshRequestSchema,
  LOCAL_PROVIDER_IDS,
  LocalProviderIdSchema,
  LocalUsageReportSchema,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_SNAPSHOTS_PER_ENVELOPE,
  OAuthTokenResponseSchema,
  PROTOCOL_VERSION,
  PROVIDER_IDS,
  PricingCatalogSchema,
  ProviderIdSchema,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotUploadResponseSchema,
  SessionRefreshResponseSchema,
  UsageRowSchema,
  UsageUploadSchema,
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
    expect(MANAGED_DATA_PROTOCOL_VERSION).toBe(6);
    expect(protocol.BILLING_AGENTS).toContain("cursor");
    const cursorEnvelope = { ...quotaEnvelope(), snapshots: [snapshot("cursor")] };
    expect(QuotaSnapshotEnvelopeSchema.safeParse(cursorEnvelope).success).toBe(true);
    // The shared fixture owns the retired managed-data version; this pins the control one,
    // which no data contract ever accepted.
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({ ...cursorEnvelope, protocol_version: 2 }).success,
    ).toBe(false);

    const upload = usageUpload();
    const cursorUsage = {
      ...upload,
      agent: "cursor" as const,
      hours: upload.hours.map((hour) => ({
        ...hour,
        rows: hour.rows.map((row) => ({ ...row, agent: "cursor" as const })),
      })),
    };
    expect(UsageUploadSchema.safeParse(cursorUsage).success).toBe(true);
    expect(UsageUploadSchema.safeParse({ ...cursorUsage, protocol_version: 2 }).success).toBe(
      false,
    );
  });

  it("refuses a summary Device that asserts something about itself", () => {
    const summary = accountSummary();
    expect(AccountSummarySchema.safeParse(summary).success).toBe(true);
    // A Device says when it was last seen and when its newest reading was taken. A status it
    // decided for itself is not the wire.
    const claiming = {
      ...summary,
      devices: summary.devices.map((device) => ({ ...device, status: "active" })),
    };
    expect(AccountSummarySchema.safeParse(claiming).success).toBe(false);
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
        protocol_version: 6,
        device_id: "device_01",
        device_generation: 3,
        accepted: ["codex"],
        ignored: ["cursor"],
      }).success,
    ).toBe(true);
  });

  it("answers a Usage upload with the hours it decided, and nothing else", () => {
    const answered = {
      protocol_version: 6,
      device_id: "device_01",
      device_generation: 3,
      accepted: ["2026-08-02T12:00:00Z"],
      ignored: ["2026-08-02T11:00:00Z"],
    };
    expect(protocol.UsageUploadResponseSchema.safeParse(answered).success).toBe(true);
    // The sequence, the receipt, and the rejection reason all belonged to an append.
    expect(
      protocol.UsageUploadResponseSchema.safeParse({ ...answered, next_sequence: 43 }).success,
    ).toBe(false);
    expect(
      protocol.UsageUploadResponseSchema.safeParse({
        ...answered,
        accepted: ["2026-08-02T12:30:00Z"],
      }).success,
    ).toBe(false);
  });

  it("carries a window's headline cadence and tolerates an unknown member on read", () => {
    const envelope = quotaEnvelope();
    const window = {
      id: "five_hour",
      title: "5 Hours",
      used_percent: 10,
      primary_cadence: "five_hour" as const,
    };
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        snapshots: [{ ...envelope.snapshots[0], windows: [window] }],
      }).success,
    ).toBe(true);

    const unknown = { ...window, primary_cadence: "yearly" };
    expect(
      QuotaSnapshotEnvelopeSchema.safeParse({
        ...envelope,
        snapshots: [{ ...envelope.snapshots[0], windows: [unknown] }],
      }).success,
    ).toBe(false);

    const summary = accountSummary();
    const subscription = summary.subscriptions[0];
    if (!subscription) {
      throw new Error("accountSummary fixture has a subscription");
    }
    const payload = {
      ...summary,
      subscriptions: [
        {
          ...subscription,
          snapshot: { ...subscription.snapshot, windows: [unknown] },
        },
      ],
    };
    expect(AccountSummarySchema.safeParse(payload).success).toBe(false);
    expect(AccountSummaryReadSchema.safeParse(payload).success).toBe(true);
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

  it("keeps local collection reports strict and provider-consistent", () => {
    const report = {
      captured_at: "2026-08-02T12:00:00Z",
      results: [
        {
          provider: "codex",
          outcome: "success",
          snapshots: [snapshot("codex")],
          sources: [{ source_id: "chatgpt_usage_api", outcome: "success", category: "success" }],
        },
        {
          // Each rung names itself, so an expired OAuth grant and a browser session that
          // went stale are two findings rather than one shrug.
          provider: "claude",
          outcome: "auth_required",
          snapshots: [],
          message: "Open Claude Code to refresh the sign-in",
          sources: [
            {
              source_id: "anthropic_oauth_usage_api",
              outcome: "auth_required",
              category: "auth_required",
            },
          ],
        },
        {
          // A refusal reads as unavailable to every other device and names itself here,
          // because only the Mac holding the credential can act on it.
          provider: "grok",
          outcome: "unavailable",
          snapshots: [],
          access_denied: true as const,
          message: "Check access",
          sources: [
            {
              source_id: "grok_billing_api",
              outcome: "unavailable",
              category: "access_denied",
            },
          ],
        },
        {
          provider: "cursor",
          outcome: "success",
          snapshots: [snapshot("cursor")],
          sources: [{ source_id: "cursor_app_auth", outcome: "success", category: "success" }],
        },
      ],
    };
    expect(QuotaCollectionReportSchema.safeParse(report).success).toBe(true);
    expect(
      QuotaCollectionReportSchema.safeParse({
        ...report,
        results: [
          { provider: "codex", outcome: "success", snapshots: [snapshot("claude")], sources: [] },
        ],
      }).success,
    ).toBe(false);
    // A provider that was never set up here reports no sources, not a missing field.
    expect(
      QuotaCollectionReportSchema.safeParse({
        ...report,
        results: [{ provider: "codex", outcome: "auth_required", snapshots: [] }],
      }).success,
    ).toBe(false);
    expect(QuotaCollectionReportSchema.safeParse({ ...report, extra: true }).success).toBe(false);
  });

  it("takes one login payload, from the one client that registers a Device", () => {
    const browser = {
      protocol_version: 2,
      grant_type: "authorization_code",
      client_id: "quotabar",
      code: "synthetic-login-code",
      code_verifier: "a".repeat(43),
      redirect_uri: "http://127.0.0.1:49152/callback",
      installation_id: "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998",
      device_display_name: "Kitchen Mac",
      platform: "macos",
    };
    expect(BrowserLoginExchangeRequestSchema.safeParse(browser).success).toBe(true);
    expect(
      BrowserLoginExchangeRequestSchema.safeParse({
        ...browser,
        redirect_uri: "https://example.com/callback",
      }).success,
    ).toBe(false);
    // Authorization Code with PKCE is the only grant, so a request naming another one is not a
    // login payload at all.
    expect(
      BrowserLoginExchangeRequestSchema.safeParse({
        ...browser,
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
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
    expect(BrowserLoginExchangeRequestSchema.safeParse(iosExchange).success).toBe(false);
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
    // QuotaBar is the only client that registers a Device, and it runs on one platform.
    expect(protocol.PlatformSchema.options).toEqual(["macos"]);
    expect(protocol.platformDisplayName("macos")).toBe("macOS");
    expect(protocol.platformDisplayName("linux")).toBe("Unknown");

    const session = {
      access_token: "synthetic-access-token",
      access_expires_at: "2026-08-02T12:15:00Z",
      refresh_token: "synthetic-refresh-token",
      refresh_expires_at: "2026-11-01T12:00:00Z",
    };
    const iosResponse = {
      protocol_version: 2,
      token_type: "Bearer",
      account_id: "account_01",
      display_label: "octocat",
      session,
    };
    expect(IosOAuthTokenResponseSchema.safeParse(iosResponse).success).toBe(true);
    expect(OAuthTokenResponseSchema.safeParse(iosResponse).success).toBe(false);
    expect(
      IosOAuthTokenResponseSchema.safeParse({ ...iosResponse, device_id: "device_01" }).success,
    ).toBe(false);
    // Signing in names the Account, so a client says whose account it reached before it has
    // read one. An Account that kept no label still states the key.
    expect(
      IosOAuthTokenResponseSchema.safeParse({ ...iosResponse, display_label: null }).success,
    ).toBe(true);
    const { display_label: _iosLabel, ...unnamedIosResponse } = iosResponse;
    expect(IosOAuthTokenResponseSchema.safeParse(unnamedIosResponse).success).toBe(false);
    expect(
      IosSessionRefreshRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        refresh_token: "synthetic-refresh-token",
      }).success,
    ).toBe(true);
    expect(
      protocol.SessionRefreshRequestSchema.safeParse({
        protocol_version: 2,
        grant_type: "refresh_token",
        client_id: IOS_OAUTH_CLIENT_ID,
        refresh_token: "synthetic-refresh-token",
      }).success,
    ).toBe(false);
  });

  it("returns one token family and the Device it may write", () => {
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
      display_label: "octocat",
      device_id: "device_01",
      device_generation: 3,
      usage_deleted_before: null,
      usage_sync_revision: 9,
      session: token,
    };
    expect(OAuthTokenResponseSchema.safeParse(response).success).toBe(true);
    expect(OAuthTokenResponseSchema.safeParse({ ...response, display_label: null }).success).toBe(
      true,
    );
    expect(OAuthTokenResponseSchema.safeParse({ ...response, display_label: "  " }).success).toBe(
      false,
    );
    const { display_label: _label, ...unnamed } = response;
    expect(OAuthTokenResponseSchema.safeParse(unnamed).success).toBe(false);
    // A second token family is not an extra field to ignore on a write; it is a refusal.
    expect(OAuthTokenResponseSchema.safeParse({ ...response, write_session: token }).success).toBe(
      false,
    );
    expect(
      protocol.SessionRefreshResponseSchema.safeParse({
        protocol_version: 2,
        token_type: "Bearer",
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
        session: token,
      }).success,
    ).toBe(true);
    expect(
      DeviceSyncResponseSchema.safeParse({
        protocol_version: 2,
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
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
    // A rotation answers with the Device it is still bound to, and nothing that would let a
    // reader think there is a second family behind it.
    expect(
      SessionRefreshResponseSchema.safeParse({
        protocol_version: 2,
        token_type: "Bearer",
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
        session: token,
      }).success,
    ).toBe(true);
    expect(
      SessionRefreshResponseSchema.safeParse({
        protocol_version: 2,
        token_type: "Bearer",
        account_id: "account_01",
        device_id: "device_01",
        device_generation: 3,
        session: token,
        account_session: token,
      }).success,
    ).toBe(false);
  });

  it("validates token conservation and source-cost coverage on a row", () => {
    const row = usageRow();
    expect(UsageRowSchema.safeParse(row).success).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, cache_read_tokens: 1_001 }).success).toBe(false);
    expect(UsageRowSchema.safeParse({ ...row, reasoning_tokens: 201 }).success).toBe(false);
    expect(
      UsageRowSchema.safeParse({
        ...row,
        source_cost_microusd: "1200",
        source_cost_covered_requests: 0,
      }).success,
    ).toBe(false);
    expect(
      UsageRowSchema.safeParse({
        ...row,
        billing_channel: "unknown",
        channel_source: "explicit",
      }).success,
    ).toBe(false);
    expect(UsageRowSchema.safeParse({ ...row, model: "GPT-5.5[1m]" }).success).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, model: "unknown" }).success).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, model: "😀".repeat(128) }).success).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, model: "😀".repeat(129) }).success).toBe(false);
    expect(UsageRowSchema.safeParse({ ...row, model: "model\u2028separator" }).success).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, model: "model\nwith-control" }).success).toBe(false);
    expect(
      UsageRowSchema.safeParse({ ...row, agent: "grok", billing_channel: "xai_direct" }).success,
    ).toBe(true);
    expect(UsageRowSchema.safeParse({ ...row, prompt: "secret" }).success).toBe(false);
    // A row is placed by the hour that carries it, so it names no instant of its own.
    expect(
      UsageRowSchema.safeParse({ ...row, bucket_start_utc: "2026-08-02T12:00:00Z" }).success,
    ).toBe(false);
    expect(UsageRowSchema.safeParse({ ...row, usage_date: "2026-08-02" }).success).toBe(false);
  });

  it("uses the opaque model contract for a period's model leaves", () => {
    const period = {
      totals: emptyTotals(),
      cost: emptyCost(),
      partial: false,
      agents: [
        {
          agent: "codex",
          providers: [
            {
              provider: "openai",
              models: [{ model: "GPT-5.5[1m]", totals: emptyTotals(), cost: emptyCost() }],
            },
          ],
        },
      ],
    };
    expect(protocol.UsagePeriodSchema.safeParse(period).success).toBe(true);
    const withModel = (model: string) => ({
      ...period,
      agents: [
        {
          agent: "codex",
          providers: [
            { provider: "openai", models: [{ model, totals: emptyTotals(), cost: emptyCost() }] },
          ],
        },
      ],
    });
    expect(protocol.UsagePeriodSchema.safeParse(withModel("😀".repeat(128))).success).toBe(true);
    expect(protocol.UsagePeriodSchema.safeParse(withModel("😀".repeat(129))).success).toBe(false);
    expect(protocol.UsagePeriodSchema.safeParse(withModel("model\nwith-control")).success).toBe(
      false,
    );
  });

  it("bounds an upload by hours and by the rows inside one hour", () => {
    const upload = usageUpload();
    const hour = upload.hours[0];
    expect(hour).toBeDefined();
    expect(UsageUploadSchema.safeParse(upload).success).toBe(true);
    const withRows = (count: number) => ({
      ...upload,
      hours: [
        {
          ...hour,
          rows: Array.from({ length: count }, (_, index) => ({
            ...usageRow(),
            model: `model-${index}`,
          })),
        },
      ],
    });
    expect(
      UsageUploadSchema.safeParse(withRows(protocol.MAXIMUM_USAGE_ROWS_PER_HOUR)).success,
    ).toBe(true);
    expect(
      UsageUploadSchema.safeParse(withRows(protocol.MAXIMUM_USAGE_ROWS_PER_HOUR + 1)).success,
    ).toBe(false);
    const withHours = (count: number) => ({
      ...upload,
      hours: Array.from({ length: count }, (_, index) => ({
        ...hour,
        bucket_start_utc: new Date(Date.UTC(2026, 7, 2, 0) + index * 3_600_000)
          .toISOString()
          .replace(".000Z", "Z"),
      })),
    });
    expect(
      UsageUploadSchema.safeParse(withHours(protocol.MAXIMUM_USAGE_HOURS_PER_UPLOAD)).success,
    ).toBe(true);
    expect(
      UsageUploadSchema.safeParse(withHours(protocol.MAXIMUM_USAGE_HOURS_PER_UPLOAD + 1)).success,
    ).toBe(false);
  });

  it("tells a payload that does not fit apart from one the contract does not describe", () => {
    const upload = usageUpload();
    const hour = upload.hours[0];
    const tooMany = {
      ...upload,
      hours: [
        {
          ...hour,
          rows: Array.from({ length: protocol.MAXIMUM_USAGE_ROWS_PER_HOUR + 1 }, (_, index) => ({
            ...usageRow(),
            model: `model-${index}`,
          })),
        },
      ],
    };
    const oversized = UsageUploadSchema.safeParse(tooMany);
    expect(oversized.success).toBe(false);
    expect(protocol.exceedsContractBound(oversized.error)).toBe(true);

    // A shape the contract does not describe is not a size, and neither is anything that is not
    // a refusal at all.
    const wrong = UsageUploadSchema.safeParse({ ...upload, agent: "not_an_agent" });
    expect(wrong.success).toBe(false);
    expect(protocol.exceedsContractBound(wrong.error)).toBe(false);
    expect(protocol.exceedsContractBound(new Error("D1_ERROR"))).toBe(false);
    expect(protocol.exceedsContractBound(undefined)).toBe(false);
  });

  it("validates subscriptions and Usage as one normalized read summary", () => {
    expect(AccountSummarySchema.safeParse(accountSummary()).success).toBe(true);
    expect(
      AccountUsageActivityResponseSchema.safeParse({
        protocol_version: 6,
        days: [{ date: "2026-08-02", totals: emptyTotals(), cost: emptyCost(), partial: false }],
      }).success,
    ).toBe(true);
    expect(
      AccountUsageActivityResponseSchema.safeParse({
        protocol_version: 6,
        days: [
          {
            date: "2026-08-02",
            totals: emptyTotals(),
            cost: emptyCost(),
            partial: false,
            agents: emptyPeriod().agents,
          },
        ],
      }).success,
    ).toBe(true);
    expect(
      AccountUsageActivityResponseSchema.safeParse({
        protocol_version: 6,
        days: [{ date: "2026-08-02", totals: emptyTotals(), cost: emptyCost() }],
      }).success,
    ).toBe(false);
    expect(
      AccountUsageActivityResponseSchema.safeParse({
        protocol_version: 6,
        days: [
          {
            date: "2026-08-02",
            totals: emptyTotals(),
            cost: emptyCost(),
            partial: false,
            extra: true,
          },
        ],
      }).success,
    ).toBe(false);
    expect(
      AccountUsageActivityResponseReadSchema.safeParse({
        protocol_version: 6,
        days: [
          {
            date: "2026-08-02",
            totals: emptyTotals(),
            cost: emptyCost(),
            partial: false,
            extra: true,
          },
        ],
      }).success,
    ).toBe(true);
    const summary = accountSummary();
    expect(
      AccountSummarySchema.safeParse({
        ...summary,
        usage: {
          ...summary.usage,
          all: {
            ...summary.usage.all,
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
        },
      }).success,
    ).toBe(true);
    expect(
      AccountSummarySchema.safeParse({
        ...summary,
        usage: {
          ...summary.usage,
          all: { ...summary.usage.all, cost: { ...emptyCost(), unpriced_truncated: false } },
        },
      }).success,
    ).toBe(false);
    expect(
      AccountSummarySchema.safeParse({
        ...summary,
        devices: [{ ...summary.devices[0], owner_id: "owner_legacy" }],
      }).success,
    ).toBe(false);
    // The observations a subscription was resolved from are not the read; the resolution is.
    expect(
      AccountSummarySchema.safeParse({
        ...summary,
        quota: [{ device_id: "device_01", snapshot: snapshot("codex") }],
      }).success,
    ).toBe(false);
  });

  it("refuses an hour computed from a missing lower bound", () => {
    const upload = usageUpload();
    expect(
      UsageUploadSchema.safeParse({
        ...upload,
        hours: [{ ...upload.hours[0], bucket_start_utc: "1970-01-01T00:00:00Z", rows: [] }],
      }).success,
    ).toBe(false);
    // The private local report states whatever range the app asked for and is not bounded here.
    expect(
      LocalUsageReportSchema.safeParse({
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
    windows: [{ id: "five_hour", title: "5 Hours", used_percent: 10 }],
    status: "available" as const,
    observed_at: "2026-08-02T12:00:00Z",
  };
}

function quotaEnvelope() {
  return {
    protocol_version: 6 as const,
    generation: 3,
    snapshots: [snapshot("codex")],
  };
}

function usageRow() {
  return {
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

function usageUpload() {
  return {
    protocol_version: 6 as const,
    generation: 3,
    agent: "codex" as const,
    hours: [
      {
        bucket_start_utc: "2026-08-02T12:00:00Z",
        scan_version: 7,
        partial: false,
        rows: [usageRow()],
      },
    ],
  };
}

function emptyTotals() {
  return {
    total_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 0,
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

function emptyPeriod() {
  return { totals: emptyTotals(), cost: emptyCost(), partial: false, agents: [] };
}

function accountSummary() {
  return {
    protocol_version: 6 as const,
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-07-01T00:00:00Z",
    },
    devices: [
      {
        id: "device_01",
        display_name: "Kitchen Mac",
        platform: "macos" as const,
        last_seen_at: "2026-08-02T12:00:00Z",
        last_observed_at: "2026-08-02T12:00:00Z",
      },
    ],
    subscriptions: [
      {
        key: "codex|codex-fixture|source|device_01",
        provider: "codex" as const,
        snapshot: snapshot("codex"),
        sources: [{ device_id: "device_01", observed_at: "2026-08-02T12:00:00Z" }],
      },
    ],
    usage: {
      today: emptyPeriod(),
      last_7_days: emptyPeriod(),
      last_30_days: emptyPeriod(),
      all: emptyPeriod(),
    },
    pricing_revision: "pricing_2026_08_02",
    model_catalog_revision: "model_2026_08_02",
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
