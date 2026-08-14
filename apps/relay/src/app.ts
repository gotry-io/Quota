import { validateModelCatalog, validatePricingCatalog } from "@gotry-io/quota-model";
import {
  AccountDevicesResponseSchema,
  AccountQuotaResponseSchema,
  AccountQuotaResponseV3Schema,
  AccountResponseSchema,
  AccountSummarySchema,
  AccountSummaryV3Schema,
  AccountUsageHourlyResponseSchema,
  AccountUsageHourlyResponseV3Schema,
  AccountUsageResponseSchema,
  AccountUsageResponseV3Schema,
  BILLING_AGENTS,
  BILLING_AGENTS_V3,
  DeleteDeviceResponseSchema,
  DeviceAuthorizationDecisionRequestSchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceSyncResponseSchema,
  LogoutResponseSchema,
  MAXIMUM_USAGE_READ_ROWS,
  MAXIMUM_USAGE_SUBMISSION_BYTES,
  MODEL_CATALOG,
  MANAGED_DATA_PROTOCOL_VERSION,
  type ModelCatalog,
  ModelCatalogSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PROTOCOL_VERSION,
  PROVIDER_IDS,
  type PricingCatalog,
  PricingCatalogSchema,
  PublicProfileSchema,
  PublicProfileSettingsSchema,
  PublicProfileUpdateRequestSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotEnvelopeV3Schema,
  QuotaSnapshotUploadResponseSchema,
  QuotaSnapshotUploadResponseV3Schema,
  type RelayErrorCode,
  type RelayErrorEnvelope,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  UsageCostModeSchema,
  UsageDateRangeSchema,
  UsageSubmissionSchema,
  UsageSubmissionV3Schema,
  UsageUploadResponseSchema,
  UsageUploadResponseV3Schema,
  UtcHourSchema,
} from "@gotry-io/quota-protocol";
import type {
  AccountMaintenanceInput,
  AccountPrincipal,
  AccountScope,
  AccountState,
  DevicePrincipal,
  DeviceScope,
  UsageState,
  UsageAgent,
} from "@gotry-io/relay-core";
import { type Context, Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { WebAccountAuth } from "./account/better-auth.ts";
import { consumeNamedRateLimit, publicProfileRateLimit } from "./account/rate-limit.ts";
import { AccountFlowError, type AccountService, isLoopbackRedirect } from "./account/service.ts";
import { managedServiceInfo } from "./config.ts";
import { PRICING_CATALOG, PRICING_CATALOG_ETAG } from "./pricing-catalog.ts";
import { normalizePublicSlug, publicProfileFromAccount } from "./public-profile.ts";
import { bearerToken, type SecretHasher } from "./security.ts";
import { buildUsageCost, buildUsageSummary, UsageSummaryLimitError } from "./usage-summary.ts";

const maximumCredentialBodyBytes = 64 * 1024;
const maximumSnapshotBodyBytes = 256 * 1024;
const maximumAccountDevices = 256;
const maximumAccountSnapshots = 8_192;
const maximumAccountUsageSummaryRows = 100_000;
const recentAuthenticationMilliseconds = 10 * 60 * 1000;
const activeDeviceMilliseconds = 15 * 60 * 1000;
const expiredSessionRetentionMilliseconds = 7 * 24 * 60 * 60 * 1000;
const maintenanceBatchLimit = 100;

const rateLimits = {
  nativeAuthorize: { limit: 60, windowSeconds: 10 * 60 },
  deviceCode: { limit: 30, windowSeconds: 10 * 60 },
  token: { limit: 180, windowSeconds: 10 * 60 },
  sessionMutation: { limit: 60, windowSeconds: 10 * 60 },
  destructiveMutation: { limit: 10, windowSeconds: 60 * 60 },
  publicProfile: publicProfileRateLimit,
} as const;

interface StrictSchema<Output> {
  safeParse(value: unknown): { success: true; data: Output } | { success: false };
}

export interface RelayAppOptions {
  state: AccountState;
  usageState: UsageState;
  accountService: AccountService;
  webAuth: WebAccountAuth;
  hasher: SecretHasher;
  now?: () => Date;
  pricingCatalog?: PricingCatalog;
  modelCatalog?: ModelCatalog;
}

export function accountMaintenanceInput(checkedAt: Date): AccountMaintenanceInput {
  const retainedAfter = new Date(
    checkedAt.getTime() - expiredSessionRetentionMilliseconds,
  ).toISOString();
  return {
    grant_expired_before: checkedAt.toISOString(),
    session_expired_before: retainedAfter,
    session_revoked_before: retainedAfter,
    limit: maintenanceBatchLimit,
  };
}

export function createRelayApp(options: RelayAppOptions): Hono {
  const app = new Hono();
  const now = options.now ?? (() => new Date());
  const parsedCatalog = PricingCatalogSchema.parse(options.pricingCatalog ?? PRICING_CATALOG);
  const catalogValidation = validatePricingCatalog(parsedCatalog);
  if (!catalogValidation.valid) {
    throw new Error("Pricing catalog validation failed");
  }
  const catalog = catalogValidation.catalog;
  const catalogETag = options.pricingCatalog
    ? `"${options.pricingCatalog.revision}"`
    : PRICING_CATALOG_ETAG;
  const parsedModelCatalog = ModelCatalogSchema.parse(options.modelCatalog ?? MODEL_CATALOG);
  const modelCatalogValidation = validateModelCatalog(parsedModelCatalog);
  if (!modelCatalogValidation.valid) {
    throw new Error("Model catalog validation failed");
  }
  const modelCatalog = modelCatalogValidation.catalog;
  const modelCatalogETag = options.modelCatalog
    ? '"' + options.modelCatalog.revision + '"'
    : '"' + modelCatalog.revision + '"';

  app.get("/healthz", (context) => context.json({ status: "ok", ...managedServiceInfo() }));
  for (const path of [
    "/api/auth/v2/*",
    "/oauth/v2/*",
    "/api/v2/account",
    "/api/v2/account/*",
    "/api/v2/device/*",
    "/api/v3/account/*",
    "/api/v3/device/*",
  ]) {
    app.use(path, async (context, next) => {
      context.header("Cache-Control", "no-store");
      await next();
    });
  }
  for (const path of ["/api/auth/v2/*", "/oauth/v2/*"]) {
    app.use(path, bodyLimit({ maxSize: maximumCredentialBodyBytes, onError: requestBodyTooLarge }));
  }
  app.use(
    "/api/v2/device/snapshots",
    bodyLimit({ maxSize: maximumSnapshotBodyBytes, onError: requestBodyTooLarge }),
  );
  app.use(
    "/api/v3/device/snapshots",
    bodyLimit({ maxSize: maximumSnapshotBodyBytes, onError: requestBodyTooLarge }),
  );
  app.use(
    "/api/v2/device/usage",
    bodyLimit({ maxSize: MAXIMUM_USAGE_SUBMISSION_BYTES, onError: requestBodyTooLarge }),
  );
  app.use(
    "/api/v3/device/usage",
    bodyLimit({ maxSize: MAXIMUM_USAGE_SUBMISSION_BYTES, onError: requestBodyTooLarge }),
  );

  app.get("/readyz", async (context) => {
    try {
      const checkedAt = now();
      await options.state.performMaintenance(accountMaintenanceInput(checkedAt));
      await options.state.ping();
      return context.json({ status: "ready" });
    } catch {
      return context.json({ status: "unavailable" }, 503);
    }
  });
  app.get("/api/v2/info", (context) => context.json(managedServiceInfo()));
  app.on(["GET", "POST"], "/api/auth/v2/*", async (context) => {
    const response = await options.webAuth.handler(context.req.raw);
    response.headers.set("Cache-Control", "no-store");
    return response;
  });

  app.get("/oauth/v2/authorize", async (context) => {
    const allowed = [
      "response_type",
      "client_id",
      "redirect_uri",
      "state",
      "code_challenge",
      "code_challenge_method",
    ];
    if (!hasOnlyQueryKeys(context, allowed) || context.req.query("response_type") !== "code") {
      return invalidRequest(context);
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "native-authorize",
      anonymousClientSubject(context),
      rateLimits.nativeAuthorize,
      now(),
    );
    if (limited) {
      return limited;
    }
    try {
      const login = await options.accountService.beginBrowserLogin(
        {
          client_id: context.req.query("client_id") ?? "",
          redirect_uri: context.req.query("redirect_uri") ?? "",
          state: context.req.query("state") ?? "",
          code_challenge: context.req.query("code_challenge") ?? "",
          code_challenge_method: context.req.query("code_challenge_method") ?? "",
        },
        now(),
      );
      const callback = new URL("/oauth/v2/complete", context.req.url);
      callback.searchParams.set("login_token", login.login_token);
      return await options.webAuth.beginGitHubSignIn(context.req.raw.headers, callback.toString());
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  app.get("/oauth/v2/complete", async (context) => {
    if (!hasOnlyQueryKeys(context, ["login_token"])) return invalidRequest(context);
    const loginToken = context.req.query("login_token");
    const webSession = await options.webAuth.getSession(context.req.raw.headers);
    if (!loginToken || loginToken.length > 4_096 || !webSession) return unauthorized(context);
    if (!(await options.state.getAccount(webSession.user.id))) return unauthorized(context);
    try {
      const completion = await options.accountService.completeBrowserLogin(
        loginToken,
        webSession.user.id,
        webSession.user.name,
        now(),
      );
      if (!isLoopbackRedirect(completion.redirect_uri)) {
        throw new AccountFlowError("invalid_state");
      }
      const redirect = new URL(completion.redirect_uri);
      redirect.searchParams.set("code", completion.code);
      redirect.searchParams.set("state", completion.client_state);
      return context.redirect(redirect.toString(), 302);
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  app.post("/oauth/v2/device/code", async (context) => {
    const body = await parseJSON(context, DeviceAuthorizationRequestSchema);
    if (body instanceof Response) {
      return body;
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "device-code",
      anonymousClientSubject(context),
      rateLimits.deviceCode,
      now(),
    );
    if (limited) {
      return limited;
    }
    try {
      const created = await options.accountService.beginDeviceLogin(body, now());
      return context.json(
        DeviceAuthorizationResponseSchema.parse({
          protocol_version: PROTOCOL_VERSION,
          device_code: created.device_code,
          user_code: created.user_code,
          verification_uri: created.verification_uri,
          verification_uri_complete: created.verification_uri_complete,
          expires_in: 10 * 60,
          interval: created.interval,
        }),
        201,
      );
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  app.post("/oauth/v2/device/authorize", async (context) => {
    const principal = await authorizeAccount(context, options, "account:manage", now());
    if (principal instanceof Response) {
      return principal;
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "device-authorize",
      principal.account_id,
      rateLimits.sessionMutation,
      now(),
    );
    if (limited) {
      return limited;
    }
    const unsafe = requireRecentWebMutation(context, principal, now());
    if (unsafe) {
      return unsafe;
    }
    const body = await parseJSON(context, DeviceAuthorizationDecisionRequestSchema);
    if (body instanceof Response) {
      return body;
    }
    const outcome = await options.accountService.decideDeviceGrant(
      body.user_code,
      principal.account_id,
      body.decision,
      now(),
    );
    switch (outcome) {
      case "approved":
      case "denied":
        return context.body(null, 204);
      case "not_found":
        return notFound(context);
      case "expired":
        return relayError(context, 400, "expired_token", "The login request expired.");
      case "already_decided":
      case "consumed":
        return relayError(context, 409, "conflict", "The login request is no longer pending.");
    }
  });

  app.post("/oauth/v2/token", async (context) => {
    const raw = await parseRawJSON(context);
    if (raw instanceof Response) {
      return raw;
    }
    const tokenRequest = OAuthTokenRequestSchema.safeParse(raw);
    const refreshRequest = SessionRefreshRequestSchema.safeParse(raw);
    if (!tokenRequest.success && !refreshRequest.success) {
      return invalidRequest(context);
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "oauth-token",
      anonymousClientSubject(context),
      rateLimits.token,
      now(),
    );
    if (limited) {
      return limited;
    }
    try {
      if (refreshRequest.success) {
        const refreshed = await options.accountService.refresh(
          refreshRequest.data.refresh_token,
          refreshRequest.data.token_audience,
          now(),
        );
        const common = {
          protocol_version: PROTOCOL_VERSION,
          token_type: "Bearer" as const,
          token_audience: refreshRequest.data.token_audience,
          account_id: refreshed.principal.account_id,
        };
        return context.json(
          SessionRefreshResponseSchema.parse(
            refreshed.principal.kind === "account"
              ? {
                  ...common,
                  token_audience: "account",
                  account_session: sessionToken(refreshed),
                }
              : {
                  ...common,
                  token_audience: "device",
                  device_id: refreshed.principal.device_id,
                  device_generation: refreshed.principal.generation,
                  device_session: sessionToken(refreshed),
                },
          ),
        );
      }
      if (!tokenRequest.success) {
        return invalidRequest(context);
      }
      const request = tokenRequest.data;
      if (request.grant_type === "authorization_code") {
        const issued = await options.accountService.exchangeAuthorizationCode(request, now());
        return context.json(OAuthTokenResponseSchema.parse(oauthTokenResponse(issued)));
      }
      const polled = await options.accountService.pollDeviceToken(
        request.device_code,
        request.client_id,
        now(),
      );
      if (polled.outcome === "issued") {
        return context.json(OAuthTokenResponseSchema.parse(oauthTokenResponse(polled.response)));
      }
      context.header("Retry-After", String(polled.interval));
      return relayError(
        context,
        400,
        polled.outcome,
        "The device authorization request is not ready.",
      );
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  app.post("/oauth/v2/revoke", async (context) => {
    const token = bearerToken(context.req.header("Authorization"));
    const tokenAudience = token ? refreshTokenAudience(token) : null;
    if (!token || !tokenAudience) {
      return unauthorized(context);
    }
    const refreshTokenHash = await options.hasher.hash(`${tokenAudience}-refresh`, token);
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "session-revoke",
      refreshTokenHash,
      rateLimits.sessionMutation,
      now(),
    );
    if (limited) {
      return limited;
    }
    await options.state.revokeRefreshSession({
      refresh_token_hash: refreshTokenHash,
      token_audience: tokenAudience,
      revoked_at: now().toISOString(),
    });
    return context.body(null, 204);
  });

  app.get("/api/v2/account", async (context) => {
    const principal = await accountReader(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const account = await options.state.getAccount(principal.account_id);
    if (!account) {
      return unauthorized(context);
    }
    return context.json(
      AccountResponseSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        account: publicAccount(account),
      }),
    );
  });

  app.get("/api/v2/account/devices", async (context) => {
    const principal = await accountReader(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const devices = await options.state.listAccountDevices(principal.account_id);
    if (devices.length > maximumAccountDevices) {
      return resultLimit(context);
    }
    return context.json(
      AccountDevicesResponseSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        devices: devices.map((device) => publicDevice(device, now())),
      }),
    );
  });

  for (const route of [
    {
      path: "/api/v2/account/snapshots",
      version: PROTOCOL_VERSION,
      schema: AccountQuotaResponseSchema,
    },
    {
      path: "/api/v3/account/snapshots",
      version: MANAGED_DATA_PROTOCOL_VERSION,
      schema: AccountQuotaResponseV3Schema,
    },
  ] as const) {
    app.get(route.path, async (context) => {
      const principal = await accountReader(context, options, now());
      if (principal instanceof Response) return principal;
      const stored = await options.state.listLatestSnapshots(principal.account_id);
      const quota = route.version === PROTOCOL_VERSION ? v2Quota(stored) : stored;
      if (quota.length > maximumAccountSnapshots) return resultLimit(context);
      return context.json(route.schema.parse({ protocol_version: route.version, quota }));
    });
  }

  for (const route of [
    {
      path: "/api/v2/account/summary",
      version: PROTOCOL_VERSION,
      schema: AccountSummarySchema,
      agents: BILLING_AGENTS,
    },
    {
      path: "/api/v3/account/summary",
      version: MANAGED_DATA_PROTOCOL_VERSION,
      schema: AccountSummaryV3Schema,
      agents: BILLING_AGENTS_V3,
    },
  ] as const) {
    app.get(route.path, async (context) => {
      const principal = await accountReader(context, options, now());
      if (principal instanceof Response) return principal;
      const selected = await accountUsageQuery(
        context,
        principal,
        options,
        catalog,
        modelCatalog,
        now(),
        {
          allByDefault: true,
          includeHourlyBreakdowns: false,
          agents: route.agents,
        },
      );
      if (selected instanceof Response) return selected;
      const account = await options.state.getAccount(principal.account_id);
      if (!account) return unauthorized(context);
      const [devices, storedQuota] = await Promise.all([
        options.state.listAccountDevices(principal.account_id),
        options.state.listLatestSnapshots(principal.account_id),
      ]);
      const quota = route.version === PROTOCOL_VERSION ? v2Quota(storedQuota) : storedQuota;
      if (devices.length > maximumAccountDevices || quota.length > maximumAccountSnapshots) {
        return resultLimit(context);
      }
      return context.json(
        route.schema.parse({
          protocol_version: route.version,
          generated_at: now().toISOString(),
          account: publicAccount(account),
          devices: devices.map((device) => publicDevice(device, now())),
          quota,
          usage: selected.summary,
        }),
      );
    });
  }

  app.get("/api/v2/account/public-profile", async (context) => {
    const principal = await accountReader(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const account = await options.state.getAccount(principal.account_id);
    if (!account) {
      return unauthorized(context);
    }
    const slug = normalizePublicSlug(account.display_label ?? "");
    return context.json(
      PublicProfileSettingsSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        enabled: true,
        slug,
      }),
    );
  });

  app.put("/api/v2/account/public-profile", async (context) => {
    const principal = await authorizeAccount(context, options, "account:manage", now());
    if (principal instanceof Response) {
      return principal;
    }
    const originError = requireWebOrigin(context, principal);
    if (originError) {
      return originError;
    }
    const body = await parseJSON(context, PublicProfileUpdateRequestSchema);
    if (body instanceof Response) {
      return body;
    }
    const account = await options.state.getAccount(principal.account_id);
    if (!account) {
      return unauthorized(context);
    }
    const slug = normalizePublicSlug(account.display_label ?? "");
    if (!slug) {
      return invalidRequest(context);
    }
    const outcome = await options.state.setPublicProfile(
      principal.account_id,
      true,
      slug,
      now().toISOString(),
    );
    if (outcome === "conflict") {
      return relayError(context, 409, "conflict", "That public username is already in use.");
    }
    return context.json(
      PublicProfileSettingsSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        enabled: true,
        slug,
      }),
    );
  });

  app.get("/api/v2/public/profiles/:username", async (context) => {
    const username = context.req.param("username");
    const slug = normalizePublicSlug(username ?? "");
    if (!slug) {
      return notFound(context);
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "public-profile",
      slug,
      rateLimits.publicProfile,
      now(),
    );
    if (limited) {
      return limited;
    }
    const account = await options.state.getAccountByPublicSlug(slug);
    if (!account) {
      return notFound(context);
    }
    const snapshots = await options.state.listLatestSnapshots(account.id);
    const usageRows = await options.usageState.queryAccountUsage(account.id, {
      agents: BILLING_AGENTS,
      limit: maximumAccountUsageSummaryRows,
    });
    if (usageRows.truncated) {
      return resultLimit(context);
    }
    const today = now().toISOString().slice(0, 10);
    const usage = buildUsageSummary(
      usageRows,
      retainedUsageRange(usageRows.rows, today),
      "calculate",
      catalog,
      false,
    );
    return context.json(
      PublicProfileSchema.parse(
        publicProfileFromAccount({
          slug,
          displayLabel: account.display_label,
          snapshots: v2Quota(snapshots),
          usage,
        }),
      ),
    );
  });

  for (const route of [
    {
      paths: ["/api/v2/account/usage", "/api/v2/account/usage/summary"],
      version: PROTOCOL_VERSION,
      schema: AccountUsageResponseSchema,
      agents: BILLING_AGENTS,
    },
    {
      paths: ["/api/v3/account/usage", "/api/v3/account/usage/summary"],
      version: MANAGED_DATA_PROTOCOL_VERSION,
      schema: AccountUsageResponseV3Schema,
      agents: BILLING_AGENTS_V3,
    },
  ] as const) {
    for (const path of route.paths)
      app.get(path, async (context) => {
        const principal = await accountReader(context, options, now());
        if (principal instanceof Response) {
          return principal;
        }
        const selected = await accountUsageQuery(
          context,
          principal,
          options,
          catalog,
          modelCatalog,
          now(),
          { allByDefault: false, includeHourlyBreakdowns: false, agents: route.agents },
        );
        return selected instanceof Response
          ? selected
          : context.json(
              route.schema.parse({
                protocol_version: route.version,
                usage: selected.summary,
              }),
            );
      });
  }

  for (const route of [
    {
      path: "/api/v2/account/usage/hourly",
      version: PROTOCOL_VERSION,
      schema: AccountUsageHourlyResponseSchema,
      agents: BILLING_AGENTS,
    },
    {
      path: "/api/v3/account/usage/hourly",
      version: MANAGED_DATA_PROTOCOL_VERSION,
      schema: AccountUsageHourlyResponseV3Schema,
      agents: BILLING_AGENTS_V3,
    },
  ] as const)
    app.get(route.path, async (context) => {
      const principal = await accountReader(context, options, now());
      if (principal instanceof Response) {
        return principal;
      }
      if (
        !hasOnlyQueryKeys(context, ["start_at", "end_at", "device_id", "cost_mode", "usage_agents"])
      ) {
        return invalidRequest(context);
      }
      const requestedAgents = context.req.query("usage_agents");
      if (requestedAgents !== undefined && requestedAgents !== "all") {
        return invalidRequest(context);
      }
      const start = UtcHourSchema.safeParse(context.req.query("start_at"));
      const end = UtcHourSchema.safeParse(context.req.query("end_at"));
      const mode = UsageCostModeSchema.safeParse(context.req.query("cost_mode") ?? "calculate");
      if (
        !start.success ||
        !end.success ||
        !mode.success ||
        Date.parse(end.data) <= Date.parse(start.data) ||
        Date.parse(end.data) - Date.parse(start.data) > 31 * 24 * 60 * 60 * 1000
      ) {
        return invalidRequest(context);
      }
      const deviceId = context.req.query("device_id");
      if (
        deviceId &&
        !(await options.state.accountOwnsVisibleDevice(principal.account_id, deviceId))
      ) {
        return notFound(context);
      }
      const result = await options.usageState.queryAccountUsage(principal.account_id, {
        ...(deviceId ? { device_id: deviceId } : {}),
        agents: route.agents,
        start_at: start.data,
        end_at: end.data,
        limit: MAXIMUM_USAGE_READ_ROWS,
      });
      if (result.truncated) {
        return resultLimit(context);
      }
      try {
        return context.json(
          route.schema.parse({
            protocol_version: route.version,
            start_at: start.data,
            end_at: end.data,
            facts: result.rows,
            coverage: result.coverage.map((item) => ({
              device_id: item.device_id,
              agent: item.agent,
              start_at: item.start_at,
              end_at: item.end_at,
              status: item.status,
            })),
            cost: buildUsageCost(result.rows, mode.data, catalog),
            ...(result.coverage_truncated ? { coverage_truncated: true } : {}),
          }),
        );
      } catch (error) {
        if (error instanceof UsageSummaryLimitError) {
          return resultLimit(context);
        }
        throw error;
      }
    });

  app.delete("/api/v2/account/devices/:device_id", async (context) => {
    const principal = await authorizeAccount(context, options, "account:manage", now());
    if (principal instanceof Response) {
      return principal;
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "device-delete",
      principal.account_id,
      rateLimits.destructiveMutation,
      now(),
    );
    if (limited) {
      return limited;
    }
    const unsafe = requireRecentWebMutation(context, principal, now());
    if (unsafe) {
      return unsafe;
    }
    const deletedAt = now().toISOString();
    const deleted = await options.state.deleteDeviceData(
      principal.account_id,
      context.req.param("device_id"),
      deletedAt,
    );
    if (!deleted) {
      return notFound(context);
    }
    return context.json(
      DeleteDeviceResponseSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        status: "deleted",
        device_id: deleted.device_id,
        device_generation: deleted.generation,
        deleted_before: deleted.deleted_before,
      }),
    );
  });

  app.get("/api/v2/device/sync", async (context) => {
    const principal = await deviceWriter(context, options, "sync:read:self", now());
    if (principal instanceof Response) {
      return principal;
    }
    const control = await options.state.getDeviceSyncControl(
      principal.device_id,
      principal.generation,
    );
    if (!control) {
      return unauthorized(context);
    }
    return context.json(
      DeviceSyncResponseSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        account_id: principal.account_id,
        device_id: principal.device_id,
        device_generation: control.generation,
        next_snapshot_sequence: control.next_snapshot_sequence,
        next_usage_sequence: control.next_usage_sequence,
        usage_deleted_before: control.usage_deleted_before,
        usage_sync_revision: control.usage_sync_revision,
      }),
    );
  });

  app.post("/api/v2/device/logout", async (context) => {
    const principal = await deviceWriter(context, options, "session:revoke:self", now());
    if (principal instanceof Response) {
      return principal;
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "device-logout",
      principal.device_id,
      rateLimits.sessionMutation,
      now(),
    );
    if (limited) {
      return limited;
    }
    await options.state.revokePrincipalFamily(principal, now().toISOString(), true);
    return context.json(
      LogoutResponseSchema.parse({ protocol_version: PROTOCOL_VERSION, status: "signed_out" }),
    );
  });

  for (const route of [
    {
      path: "/api/v2/device/snapshots",
      version: PROTOCOL_VERSION,
      requestSchema: QuotaSnapshotEnvelopeSchema,
      responseSchema: QuotaSnapshotUploadResponseSchema,
    },
    {
      path: "/api/v3/device/snapshots",
      version: MANAGED_DATA_PROTOCOL_VERSION,
      requestSchema: QuotaSnapshotEnvelopeV3Schema,
      responseSchema: QuotaSnapshotUploadResponseV3Schema,
    },
  ] as const)
    app.put(route.path, async (context) => {
      const principal = await deviceWriter(context, options, "quota:write:self", now());
      if (principal instanceof Response) {
        return principal;
      }
      const envelope =
        route.version === PROTOCOL_VERSION
          ? await parseJSON(context, QuotaSnapshotEnvelopeSchema)
          : await parseJSON(context, QuotaSnapshotEnvelopeV3Schema);
      if (envelope instanceof Response) {
        return envelope;
      }
      if (envelope.device_id !== principal.device_id) {
        return forbidden(context);
      }
      const currentEnvelope = QuotaSnapshotEnvelopeV3Schema.parse({
        ...envelope,
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      });
      const outcome = await options.state.recordSnapshot(
        principal,
        currentEnvelope,
        now().toISOString(),
      );
      if (outcome === "sequence_conflict") {
        return relayError(
          context,
          409,
          "sequence_conflict",
          "The snapshot sequence was not accepted.",
        );
      }
      if (outcome === "stale_device") {
        return relayError(context, 409, "stale_generation", "The device generation is stale.");
      }
      const control = await options.state.getDeviceSyncControl(
        principal.device_id,
        principal.generation,
      );
      if (!control) {
        return unauthorized(context);
      }
      return context.json(
        route.responseSchema.parse({
          protocol_version: route.version,
          outcome,
          device_id: principal.device_id,
          device_generation: principal.generation,
          accepted_sequence: envelope.sequence,
          next_snapshot_sequence: control.next_snapshot_sequence,
        }),
      );
    });

  for (const route of [
    {
      path: "/api/v2/device/usage",
      version: PROTOCOL_VERSION,
      requestSchema: UsageSubmissionSchema,
      responseSchema: UsageUploadResponseSchema,
    },
    {
      path: "/api/v3/device/usage",
      version: MANAGED_DATA_PROTOCOL_VERSION,
      requestSchema: UsageSubmissionV3Schema,
      responseSchema: UsageUploadResponseV3Schema,
    },
  ] as const)
    app.put(route.path, async (context) => {
      const principal = await deviceWriter(context, options, "usage:write:self", now());
      if (principal instanceof Response) {
        return principal;
      }
      const submission =
        route.version === PROTOCOL_VERSION
          ? await parseJSON(context, UsageSubmissionSchema)
          : await parseJSON(context, UsageSubmissionV3Schema);
      if (submission instanceof Response) {
        return submission;
      }
      if (submission.device_id !== principal.device_id) {
        return forbidden(context);
      }
      const currentSubmission = UsageSubmissionV3Schema.parse({
        ...submission,
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      });
      const outcome = await options.usageState.recordUsage(
        principal,
        currentSubmission,
        now().toISOString(),
      );
      const control = await options.state.getDeviceSyncControl(
        principal.device_id,
        principal.generation,
      );
      if (!control) {
        return unauthorized(context);
      }
      const wireOutcome =
        outcome.outcome === "stale_device"
          ? "stale_generation"
          : outcome.outcome === "deleted_range"
            ? "deleted"
            : outcome.outcome;
      const body = route.responseSchema.parse({
        protocol_version: route.version,
        outcome: wireOutcome,
        device_id: principal.device_id,
        device_generation: principal.generation,
        accepted_sequence:
          outcome.outcome === "accepted" || outcome.outcome === "duplicate"
            ? submission.sequence
            : null,
        next_sequence:
          "next_sequence" in outcome ? outcome.next_sequence : control.next_usage_sequence,
        usage_sync_revision:
          "usage_sync_revision" in outcome
            ? outcome.usage_sync_revision
            : control.usage_sync_revision,
        deleted_before: outcome.outcome === "deleted_range" ? control.usage_deleted_before : null,
        ...(outcome.outcome === "rejected" ? { rejection_reason: outcome.rejection_reason } : {}),
      });
      const status =
        outcome.outcome === "sequence_conflict" ||
        outcome.outcome === "stale_device" ||
        outcome.outcome === "deleted_range"
          ? 409
          : 200;
      return context.json(body, status);
    });

  app.get("/api/v2/pricing/catalog", (context) => {
    if (!hasOnlyQueryKeys(context, ["usage_agents"])) return invalidRequest(context);
    const requestedAgents = context.req.query("usage_agents");
    if (requestedAgents !== undefined && requestedAgents !== "all") {
      return invalidRequest(context);
    }
    context.header("ETag", catalogETag);
    context.header("Cache-Control", "public, max-age=300, must-revalidate");
    if (context.req.header("If-None-Match") === catalogETag) {
      return context.body(null, 304);
    }
    return context.json(catalog);
  });

  app.get("/api/v2/model/catalog", (context) => {
    if (!hasOnlyQueryKeys(context, [])) return invalidRequest(context);
    context.header("ETag", modelCatalogETag);
    context.header("Cache-Control", "public, max-age=300, must-revalidate");
    if (context.req.header("If-None-Match") === modelCatalogETag) {
      return context.body(null, 304);
    }
    return context.json(modelCatalog);
  });

  app.notFound((context) => notFound(context));
  app.onError((_error, context) =>
    relayError(context, 500, "internal_error", "QuotaRelay could not complete the request."),
  );
  return app;
}

async function accountUsageQuery(
  context: Context,
  principal: AccountPrincipal,
  options: RelayAppOptions,
  catalog: PricingCatalog,
  modelCatalog: ModelCatalog,
  checkedAt: Date,
  summaryOptions: {
    allByDefault: boolean;
    includeHourlyBreakdowns: boolean;
    agents: readonly UsageAgent[];
  } = {
    allByDefault: false,
    includeHourlyBreakdowns: false,
    agents: BILLING_AGENTS_V3,
  },
) {
  if (
    !hasOnlyQueryKeys(context, [
      "from",
      "to",
      "device_id",
      "cost_mode",
      "usage_agents",
      "model_catalog",
      "usage_clients",
    ])
  ) {
    return invalidRequest(context);
  }
  const requestedAgents = context.req.query("usage_agents");
  const modelCatalogQuery = context.req.query("model_catalog");
  const usageClientsQuery = context.req.query("usage_clients");
  if (
    (modelCatalogQuery !== undefined && modelCatalogQuery !== "1") ||
    (usageClientsQuery !== undefined && usageClientsQuery !== "1")
  ) {
    return invalidRequest(context);
  }
  const modelCatalogOptIn = modelCatalogQuery === "1";
  const usageClientsOptIn = usageClientsQuery === "1";
  if (requestedAgents !== undefined && requestedAgents !== "all") {
    return invalidRequest(context);
  }
  const defaultTo = checkedAt.toISOString().slice(0, 10);
  const defaultFrom = new Date(checkedAt.getTime() - 29 * 24 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 10);
  const requestedFrom = context.req.query("from");
  const requestedTo = context.req.query("to");
  const allDates =
    summaryOptions.allByDefault && requestedFrom === undefined && requestedTo === undefined;
  const range = allDates
    ? null
    : UsageDateRangeSchema.safeParse({
        from: requestedFrom ?? defaultFrom,
        to: requestedTo ?? defaultTo,
      });
  const mode = UsageCostModeSchema.safeParse(context.req.query("cost_mode") ?? "calculate");
  if (range?.success === false || !mode.success) {
    return invalidRequest(context);
  }
  const deviceId = context.req.query("device_id");
  if (deviceId && !(await options.state.accountOwnsVisibleDevice(principal.account_id, deviceId))) {
    return notFound(context);
  }
  const result = await options.usageState.queryAccountUsage(principal.account_id, {
    ...(deviceId ? { device_id: deviceId } : {}),
    agents: summaryOptions.agents,
    ...(range?.success
      ? {
          from: range.data.from,
          to: range.data.to,
          ...usageDateUtcBounds(range.data),
        }
      : {}),
    limit: summaryOptions.includeHourlyBreakdowns
      ? MAXIMUM_USAGE_READ_ROWS
      : maximumAccountUsageSummaryRows,
  });
  if (result.truncated) {
    return resultLimit(context);
  }
  try {
    return {
      summary: buildUsageSummary(
        result,
        range?.success ? range.data : retainedUsageRange(result.rows, defaultTo),
        mode.data,
        catalog,
        summaryOptions.includeHourlyBreakdowns,
        modelCatalogOptIn ? modelCatalog : undefined,
        usageClientsOptIn,
      ),
    };
  } catch (error) {
    if (error instanceof UsageSummaryLimitError) {
      return resultLimit(context);
    }
    throw error;
  }
}

function retainedUsageRange(
  rows: readonly { usage_date: string }[],
  currentDate: string,
): { from: string; to: string } {
  if (rows.length === 0) return { from: currentDate, to: currentDate };
  const dates = rows.map((row) => row.usage_date).sort();
  return { from: dates[0] ?? currentDate, to: dates.at(-1) ?? currentDate };
}

const v2ProviderIDs = new Set<string>(PROVIDER_IDS);

function v2Quota<T extends { snapshot: { provider: string } }>(quota: readonly T[]): T[] {
  return quota.filter((observation) => v2ProviderIDs.has(observation.snapshot.provider));
}

function usageDateUtcBounds(range: { from: string; to: string }): {
  start_at: string;
  end_at: string;
} {
  const maximumIanaOffsetHours = 14;
  const start = Date.parse(`${range.from}T00:00:00Z`) - maximumIanaOffsetHours * 3_600_000;
  const end = Date.parse(`${range.to}T00:00:00Z`) + (24 + maximumIanaOffsetHours) * 3_600_000;
  return {
    start_at: new Date(start).toISOString().replace(".000Z", "Z"),
    end_at: new Date(end).toISOString().replace(".000Z", "Z"),
  };
}

async function accountReader(
  context: Context,
  options: RelayAppOptions,
  checkedAt: Date,
): Promise<AccountPrincipal | Response> {
  return authorizeAccount(context, options, "account:read", checkedAt);
}

async function deviceWriter(
  context: Context,
  options: RelayAppOptions,
  scope: DeviceScope,
  checkedAt: Date,
): Promise<DevicePrincipal | Response> {
  const token = bearerToken(context.req.header("Authorization"));
  if (!token) {
    return unauthorized(context);
  }
  const principal = await options.state.authorizeDeviceSession(
    await options.hasher.hash("device-access", token),
    checkedAt.toISOString(),
  );
  if (!principal) {
    return unauthorized(context);
  }
  return principal.scopes.includes(scope) ? principal : forbidden(context);
}

async function authorizeAccount(
  context: Context,
  options: RelayAppOptions,
  scope: AccountScope,
  checkedAt: Date,
): Promise<AccountPrincipal | Response> {
  const token = bearerToken(context.req.header("Authorization"));
  if (token) {
    const principal = await options.state.authorizeAccountSession(
      await options.hasher.hash("account-access", token),
      checkedAt.toISOString(),
    );
    if (!principal) return unauthorized(context);
    return principal.scopes.includes(scope) ? principal : forbidden(context);
  }
  const webSession = await options.webAuth.getSession(context.req.raw.headers);
  if (!webSession) return unauthorized(context);
  if (!(await options.state.getAccount(webSession.user.id))) return unauthorized(context);
  const principal: AccountPrincipal = {
    kind: "account",
    session_id: webSession.session.id,
    family_id: webSession.session.id,
    account_id: webSession.user.id,
    device_id: null,
    client_kind: "web",
    scopes: ["account:read", "account:manage", "session:revoke:self"],
    authenticated_at: webSession.session.createdAt.toISOString(),
  };
  return principal.scopes.includes(scope) ? principal : forbidden(context);
}

function requireRecentWebMutation(
  context: Context,
  principal: AccountPrincipal,
  checkedAt: Date,
): Response | null {
  const authenticatedAt = Date.parse(principal.authenticated_at);
  if (
    !Number.isFinite(authenticatedAt) ||
    checkedAt.getTime() - authenticatedAt > recentAuthenticationMilliseconds
  ) {
    return forbidden(context);
  }
  return requireWebOrigin(context, principal);
}

function refreshTokenAudience(value: string): "account" | "device" | null {
  if (/^qar_[A-Za-z0-9_-]{43}$/.test(value)) return "account";
  if (/^qdr_[A-Za-z0-9_-]{43}$/.test(value)) return "device";
  return null;
}

function requireWebOrigin(context: Context, principal: AccountPrincipal): Response | null {
  if (principal.client_kind !== "web") return forbidden(context);
  const origin = context.req.header("Origin");
  const fetchSite = context.req.header("Sec-Fetch-Site");
  return origin === new URL(context.req.url).origin && (!fetchSite || fetchSite === "same-origin")
    ? null
    : forbidden(context);
}

async function enforceRateLimit(
  context: Context,
  state: AccountState,
  hasher: SecretHasher,
  action: string,
  subject: string,
  policy: { limit: number; windowSeconds: number },
  checkedAt: Date,
): Promise<Response | null> {
  const result = await consumeNamedRateLimit(state, hasher, action, subject, policy, checkedAt);
  if (result.allowed) {
    return null;
  }
  context.header("Retry-After", String(result.retryAfterSeconds));
  return relayError(context, 429, "rate_limited", "Too many requests. Retry later.");
}

function publicAccount(account: { id: string; display_label: string | null; created_at: string }) {
  return {
    account_id: account.id,
    display_label: account.display_label,
    created_at: account.created_at,
  };
}

function publicDevice(
  device: {
    id: string;
    display_name: string | null;
    platform: string | null;
    generation: number;
    created_at: string;
    last_login_at: string;
    last_seen_at: string | null;
    signed_out_at: string | null;
  },
  checkedAt: Date,
) {
  const status = device.signed_out_at
    ? "signed_out"
    : device.last_seen_at &&
        checkedAt.getTime() - Date.parse(device.last_seen_at) <= activeDeviceMilliseconds
      ? "active"
      : "offline";
  return {
    device_id: device.id,
    display_name: device.display_name ?? "Quota client",
    platform: device.platform ?? "linux",
    device_generation: device.generation,
    status,
    created_at: device.created_at,
    last_login_at: device.last_login_at,
    last_seen_at: device.last_seen_at,
    signed_out_at: device.signed_out_at,
  };
}

function oauthTokenResponse(
  issued: Awaited<ReturnType<AccountService["exchangeAuthorizationCode"]>>,
) {
  return {
    protocol_version: PROTOCOL_VERSION,
    token_type: issued.token_type,
    account_id: issued.account_id,
    device_id: issued.device_id,
    device_generation: issued.device_generation,
    next_snapshot_sequence: issued.next_snapshot_sequence,
    next_usage_sequence: issued.next_usage_sequence,
    usage_deleted_before: issued.usage_deleted_before,
    usage_sync_revision: issued.usage_sync_revision,
    account_session: {
      access_token: issued.account_access_token,
      access_expires_at: issued.account_access_expires_at,
      refresh_token: issued.account_refresh_token,
      refresh_expires_at: issued.account_refresh_expires_at,
    },
    device_session: {
      access_token: issued.device_access_token,
      access_expires_at: issued.device_access_expires_at,
      refresh_token: issued.device_refresh_token,
      refresh_expires_at: issued.device_refresh_expires_at,
    },
  };
}

function sessionToken(value: {
  access_token: string;
  refresh_token: string;
  access_expires_at: string;
  refresh_expires_at: string;
}) {
  return {
    access_token: value.access_token,
    access_expires_at: value.access_expires_at,
    refresh_token: value.refresh_token,
    refresh_expires_at: value.refresh_expires_at,
  };
}

async function parseJSON<Output>(
  context: Context,
  schema: StrictSchema<Output>,
): Promise<Output | Response> {
  const raw = await parseRawJSON(context);
  if (raw instanceof Response) {
    return raw;
  }
  const parsed = schema.safeParse(raw);
  return parsed.success ? parsed.data : invalidRequest(context);
}

async function parseRawJSON(context: Context): Promise<unknown | Response> {
  try {
    return JSON.parse(await context.req.text());
  } catch {
    return invalidRequest(context);
  }
}

function hasOnlyQueryKeys(context: Context, allowed: readonly string[]): boolean {
  const keys = [...new URL(context.req.url).searchParams.keys()];
  return new Set(keys).size === keys.length && keys.every((key) => allowed.includes(key));
}

function anonymousClientSubject(context: Context): string {
  return context.req.header("CF-Connecting-IP") ?? "managed-global";
}

function requestBodyTooLarge(context: Context): Response {
  return relayError(context, 413, "invalid_request", "The request body exceeds the route limit.");
}

function invalidRequest(context: Context): Response {
  return relayError(context, 400, "invalid_request", "The request is invalid.");
}

function resultLimit(context: Context): Response {
  return relayError(
    context,
    413,
    "invalid_request",
    "The requested result exceeds the route limit.",
  );
}

function unauthorized(context: Context): Response {
  context.header("WWW-Authenticate", 'Bearer realm="QuotaRelay"');
  return relayError(context, 401, "unauthorized", "A valid bearer token is required.");
}

function forbidden(context: Context): Response {
  return relayError(context, 403, "forbidden", "The principal lacks the required scope.");
}

function notFound(context: Context): Response {
  return relayError(context, 404, "not_found", "The requested resource was not found.");
}

function accountFlowError(context: Context, error: unknown): Response {
  if (error instanceof AccountFlowError) {
    const code =
      error.code === "invalid_client" || error.code === "invalid_request"
        ? "invalid_request"
        : error.code === "expired_token"
          ? "expired_token"
          : "invalid_grant";
    return relayError(context, 400, code, "The account request could not be completed.");
  }
  return relayError(context, 502, "internal_error", "Identity verification is unavailable.");
}

function relayError(
  context: Context,
  status: 400 | 401 | 403 | 404 | 409 | 413 | 429 | 500 | 502,
  code: RelayErrorCode,
  message: string,
): Response {
  const body: RelayErrorEnvelope = { error: { code, message } };
  return context.json(body, status);
}
