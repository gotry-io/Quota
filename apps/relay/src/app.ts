import {
  mergeQuotaObservations,
  quotaSubscriptionKey,
  validateModelCatalog,
  validatePricingCatalog,
} from "@gotry-io/quota-model";
import {
  AccountResponseSchema,
  AccountSummarySchema,
  AccountUsageActivityResponseSchema,
  BrowserLoginExchangeRequestSchema,
  DeleteDeviceResponseSchema,
  DeviceProfileUpdateRequestSchema,
  DeviceProfileUpdateResponseSchema,
  DeviceSyncResponseSchema,
  IanaTimezoneSchema,
  IosLoginExchangeRequestSchema,
  IosOAuthTokenResponseSchema,
  IosSessionRefreshRequestSchema,
  IosSessionRefreshResponseSchema,
  LogoutResponseSchema,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_USAGE_SUBMISSION_BYTES,
  MODEL_CATALOG,
  type ModelCatalog,
  ModelCatalogSchema,
  OAuthTokenResponseSchema,
  PROTOCOL_VERSION,
  type PricingCatalog,
  PricingCatalogSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotUploadResponseSchema,
  type RelayErrorCode,
  type RelayErrorEnvelope,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  UsageActivityRangeSchema,
  UsageUploadResponseSchema,
  UsageUploadSchema,
} from "@gotry-io/quota-protocol";
import type {
  AccountMaintenanceInput,
  AccountState,
  DeviceRecord,
  DeviceWriterPrincipal,
  SessionPrincipal,
  SessionScope,
  StoredQuotaSnapshot,
  UsageState,
} from "@gotry-io/relay-core";
import { type Context, Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { consumeNamedRateLimit } from "./account/rate-limit.ts";
import {
  AccountFlowError,
  type AccountService,
  accessTokenDomain,
  isIosRedirect,
  isLoopbackRedirect,
  refreshTokenDomain,
} from "./account/service.ts";
import {
  clearedHandoffCookie,
  clearedSessionCookie,
  DEFAULT_RETURN_PATH,
  safeReturnPath,
  type WebSessionPort,
} from "./account/web-session.ts";
import { managedServiceInfo } from "./config.ts";
import { PRICING_CATALOG, PRICING_CATALOG_ETAG } from "./pricing-catalog.ts";
import { bearerToken, canonicalRequestDigest, type SecretHasher } from "./security.ts";
import { planLocalPeriods } from "./local-periods.ts";
import { buildAccountUsage, buildActivityDays, UsageSummaryLimitError } from "./usage-summary.ts";

/** The issuer GitHub states in its authorization-code redirect (RFC 9207). */
const GITHUB_ISSUER = "https://github.com/login/oauth";

const maximumCredentialBodyBytes = 64 * 1024;
const maximumSnapshotBodyBytes = 256 * 1024;
const maximumAccountDevices = 256;
const maximumAccountSnapshots = 8_192;
const maximumAccountDailyRows = 100_000;
const recentAuthenticationMilliseconds = 10 * 60 * 1000;
const activeDeviceMilliseconds = 15 * 60 * 1000;
const expiredSessionRetentionMilliseconds = 7 * 24 * 60 * 60 * 1000;
/**
 * How long Relay keeps a quota observation after the moment it describes.
 *
 * Readers stop presenting a reading as current a day after it was observed. Keeping it a
 * while longer leaves a device's last reading available while that device is merely asleep,
 * and still bounds what an account accumulates from a provider it no longer collects.
 */
const quotaSnapshotRetentionMilliseconds = 7 * 24 * 60 * 60 * 1000;
/**
 * How long Relay keeps stored Usage.
 *
 * `usage_hourly` answers only the UTC day at a local period's edge, so it is kept for a device
 * that has been away rather than for a read. `usage_daily` is what every long read folds, so it
 * outlives both the hours behind it and the widest window `all` covers, and an account cannot
 * accumulate rows until its own summary stops being answerable.
 */
const usageHourRetentionDays = 400;
const usageDayRetentionDays = 800;
/**
 * How far back `all` reaches: at most this many UTC days, ending today.
 *
 * It is a window rather than everything, because "everything" is unbounded and a read that grows
 * with an account's whole history eventually cannot be answered at all. Retention keeps the
 * rollup longer than this, so the window is what the answer states rather than what happens to
 * be stored.
 */
const accountUsageAllDays = 730;
const maintenanceBatchLimit = 100;
const dayMilliseconds = 24 * 60 * 60 * 1000;

function requireValidPricingCatalog(value: PricingCatalog): PricingCatalog {
  const validation = validatePricingCatalog(value);
  if (!validation.valid) {
    throw new Error("Pricing catalog validation failed");
  }
  return validation.catalog;
}

function requireValidModelCatalog(value: ModelCatalog): ModelCatalog {
  const validation = validateModelCatalog(value);
  if (!validation.valid) {
    throw new Error("Model catalog validation failed");
  }
  return validation.catalog;
}

const rateLimits = {
  nativeAuthorize: { limit: 60, windowSeconds: 10 * 60 },
  token: { limit: 180, windowSeconds: 10 * 60 },
  webSignIn: { limit: 30, windowSeconds: 10 * 60 },
  sessionMutation: { limit: 60, windowSeconds: 10 * 60 },
  destructiveMutation: { limit: 10, windowSeconds: 60 * 60 },
} as const;

interface StrictSchema<Output> {
  safeParse(value: unknown): { success: true; data: Output } | { success: false };
}

export interface RelayAppOptions {
  state: AccountState;
  usageState: UsageState;
  accountService: AccountService;
  webSessions: WebSessionPort;
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
    snapshot_observed_before: new Date(
      checkedAt.getTime() - quotaSnapshotRetentionMilliseconds,
    ).toISOString(),
    // A stored hour carries no milliseconds, and these are compared as text.
    usage_hour_before: `${daysBefore(checkedAt, usageHourRetentionDays).toISOString().slice(0, 19)}Z`,
    usage_day_before: utcDate(daysBefore(checkedAt, usageDayRetentionDays)),
    limit: maintenanceBatchLimit,
  };
}

function daysBefore(instant: Date, days: number): Date {
  return new Date(instant.getTime() - days * dayMilliseconds);
}

function utcDate(instant: Date): string {
  return instant.toISOString().slice(0, 10);
}

export function createRelayApp(options: RelayAppOptions): Hono {
  const app = new Hono();
  const now = options.now ?? (() => new Date());
  // Checked-in defaults are schema-constructed by their source modules and semantic-validation
  // tested, so app construction skips the pricing validator's pairwise scan. Costing validates
  // the catalog it is handed, but memoizes by identity, so this one object is scanned at most
  // once per isolate rather than once per request.
  const catalog = options.pricingCatalog
    ? requireValidPricingCatalog(PricingCatalogSchema.parse(options.pricingCatalog))
    : PRICING_CATALOG;
  const catalogETag = options.pricingCatalog
    ? `"${options.pricingCatalog.revision}"`
    : PRICING_CATALOG_ETAG;
  const modelCatalog = options.modelCatalog
    ? requireValidModelCatalog(ModelCatalogSchema.parse(options.modelCatalog))
    : MODEL_CATALOG;
  const modelCatalogETag = options.modelCatalog
    ? '"' + options.modelCatalog.revision + '"'
    : '"' + modelCatalog.revision + '"';

  app.get("/healthz", (context) => context.json({ status: "ok", ...managedServiceInfo() }));
  for (const path of [
    "/api/auth/*",
    "/oauth/v2/*",
    "/api/v2/account",
    "/api/v2/account/*",
    "/api/v2/device/*",
    "/api/v6/account/*",
    "/api/v6/device/*",
  ]) {
    app.use(path, async (context, next) => {
      context.header("Cache-Control", "no-store");
      await next();
    });
  }
  for (const path of ["/api/auth/*", "/oauth/v2/*"]) {
    app.use(path, bodyLimit({ maxSize: maximumCredentialBodyBytes, onError: requestBodyTooLarge }));
  }
  app.use(
    "/api/v6/device/snapshots",
    bodyLimit({ maxSize: maximumSnapshotBodyBytes, onError: requestBodyTooLarge }),
  );
  app.use(
    "/api/v6/device/usage",
    bodyLimit({ maxSize: MAXIMUM_USAGE_SUBMISSION_BYTES, onError: requestBodyTooLarge }),
  );
  app.use(
    "/api/v2/device/profile",
    bodyLimit({ maxSize: maximumCredentialBodyBytes, onError: requestBodyTooLarge }),
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
  // Sign-in is a plain navigation: the browser leaves for GitHub carrying a signed cookie that
  // states which sign-in this is, and comes back to the callback below with nothing else.
  app.get("/api/auth/github/start", async (context) => {
    if (!hasOnlyQueryKeys(context, ["return_to"])) return invalidRequest(context);
    const requested = context.req.query("return_to");
    const returnTo = requested === undefined ? DEFAULT_RETURN_PATH : safeReturnPath(requested);
    if (returnTo === null) return invalidRequest(context);
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "web-signin",
      anonymousClientSubject(context),
      rateLimits.webSignIn,
      now(),
    );
    if (limited) return limited;
    return beginGitHubSignIn(context, options, returnTo, now());
  });

  app.get("/api/auth/github/callback", async (context) => {
    // GitHub names itself in the redirect (`iss`, RFC 9207). A callback that names any other
    // issuer is not GitHub's; one that names none is an older GitHub and still is.
    if (!hasOnlyQueryKeys(context, ["code", "state", "iss"])) return invalidRequest(context);
    const issuer = context.req.query("iss");
    if (issuer !== undefined && issuer !== GITHUB_ISSUER) return invalidRequest(context);
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "web-signin",
      anonymousClientSubject(context),
      rateLimits.webSignIn,
      now(),
    );
    if (limited) return limited;
    let completed: Awaited<ReturnType<WebSessionPort["completeSignIn"]>>;
    try {
      completed = await options.webSessions.completeSignIn(
        {
          cookie: context.req.header("Cookie") ?? null,
          state: context.req.query("state") ?? null,
          code: context.req.query("code") ?? null,
        },
        now(),
      );
    } catch (error) {
      // The class and message of a failure here name a subsystem (fetch, D1, WebCrypto), never
      // a credential; without them a production sign-in that dies mid-verification is invisible.
      console.error("web_signin_failed", {
        name: error instanceof Error ? error.name : typeof error,
        message: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
      });
      return relayError(context, 502, "internal_error", "Identity verification is unavailable.");
    }
    if (completed.outcome !== "signed_in") {
      // The reason is a category, never a value: enough to tell a lost cookie from a refused
      // code when a sign-in fails in production, and nothing a log reader could replay.
      console.warn("web_signin_rejected", { reason: completed.reason });
      context.header("Set-Cookie", clearedHandoffCookie(), { append: true });
      return relayError(
        context,
        400,
        "invalid_request",
        "The sign-in request could not be completed.",
      );
    }
    context.header("Set-Cookie", completed.session, { append: true });
    context.header("Set-Cookie", completed.handoff, { append: true });
    return context.redirect(completed.return_to, 302);
  });

  app.post("/api/auth/logout", async (context) => {
    const principal = await options.webSessions.authorize(context.req.raw.headers, now());
    if (!principal) return unauthorized(context);
    const unsafe = requireWebOrigin(context, principal);
    if (unsafe) return unsafe;
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "web-logout",
      principal.account_id,
      rateLimits.sessionMutation,
      now(),
    );
    if (limited) return limited;
    await options.state.revokePrincipalFamily(principal, now().toISOString(), false);
    context.header("Set-Cookie", clearedSessionCookie(), { append: true });
    return context.json(
      LogoutResponseSchema.parse({ protocol_version: PROTOCOL_VERSION, status: "signed_out" }),
    );
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
      const callback = `/oauth/v2/complete?login_token=${encodeURIComponent(login.login_token)}`;
      return await beginGitHubSignIn(context, options, callback, now());
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  app.get("/oauth/v2/complete", async (context) => {
    if (!hasOnlyQueryKeys(context, ["login_token"])) return invalidRequest(context);
    const loginToken = context.req.query("login_token");
    const principal = await options.webSessions.authorize(context.req.raw.headers, now());
    if (!loginToken || loginToken.length > 4_096 || !principal) return unauthorized(context);
    const account = await options.state.getAccount(principal.account_id);
    if (!account) return unauthorized(context);
    try {
      const completion = await options.accountService.completeBrowserLogin(
        loginToken,
        principal.account_id,
        account.display_label ?? "GitHub account",
        now(),
      );
      if (!isLoopbackRedirect(completion.redirect_uri) && !isIosRedirect(completion.redirect_uri)) {
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

  app.post("/oauth/v2/token", async (context) => {
    const raw = await parseRawJSON(context);
    if (raw instanceof Response) {
      return raw;
    }
    const tokenRequest = BrowserLoginExchangeRequestSchema.safeParse(raw);
    const iosTokenRequest = IosLoginExchangeRequestSchema.safeParse(raw);
    const refreshRequest = SessionRefreshRequestSchema.safeParse(raw);
    const iosRefreshRequest = IosSessionRefreshRequestSchema.safeParse(raw);
    if (
      !tokenRequest.success &&
      !iosTokenRequest.success &&
      !refreshRequest.success &&
      !iosRefreshRequest.success
    ) {
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
      if (iosRefreshRequest.success) {
        const refreshed = await options.accountService.refresh(
          iosRefreshRequest.data.refresh_token,
          iosRefreshRequest.data.client_id,
          now(),
        );
        return context.json(
          IosSessionRefreshResponseSchema.parse({
            protocol_version: PROTOCOL_VERSION,
            token_type: "Bearer",
            account_id: refreshed.principal.account_id,
            session: sessionToken(refreshed),
          }),
        );
      }
      if (refreshRequest.success) {
        const refreshed = await options.accountService.refresh(
          refreshRequest.data.refresh_token,
          refreshRequest.data.client_id,
          now(),
        );
        // A collection session names its Device. One that does not is not this client's.
        if (
          refreshed.principal.device_id === null ||
          refreshed.principal.device_generation === null
        ) {
          throw new AccountFlowError("invalid_grant");
        }
        return context.json(
          SessionRefreshResponseSchema.parse({
            protocol_version: PROTOCOL_VERSION,
            token_type: "Bearer",
            account_id: refreshed.principal.account_id,
            device_id: refreshed.principal.device_id,
            device_generation: refreshed.principal.device_generation,
            session: sessionToken(refreshed),
          }),
        );
      }
      if (iosTokenRequest.success) {
        const issued = await options.accountService.exchangeIosAuthorizationCode(
          iosTokenRequest.data,
          now(),
        );
        return context.json(IosOAuthTokenResponseSchema.parse(iosOAuthTokenResponse(issued)));
      }
      if (!tokenRequest.success) {
        return invalidRequest(context);
      }
      const issued = await options.accountService.exchangeAuthorizationCode(
        tokenRequest.data,
        now(),
      );
      return context.json(OAuthTokenResponseSchema.parse(oauthTokenResponse(issued)));
    } catch (error) {
      return accountFlowError(context, error);
    }
  });

  // Signing out is holding the refresh token, not holding a scope: the whole family goes, and
  // the Device the session spoke for is marked signed out with it.
  app.post("/oauth/v2/revoke", async (context) => {
    const token = bearerToken(context.req.header("Authorization"));
    const domain = token ? refreshTokenDomain(token) : null;
    if (!token || !domain) {
      return unauthorized(context);
    }
    const refreshTokenHash = await options.hasher.hash(domain, token);
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

  app.get("/api/v6/account/summary", async (context) => {
    const checkedAt = now();
    const principal = await accountReader(context, options, checkedAt);
    if (principal instanceof Response) return principal;
    if (!hasOnlyQueryKeys(context, ["tz"])) return invalidRequest(context);
    const timezone = requestedTimezone(context);
    if (timezone === null) return invalidRequest(context);
    // A local day begins at local midnight, so the caller's calendar decides where the three
    // trailing periods start and end — and, one local midnight at a time, when this answer stops
    // being the one they already hold.
    const plan = planLocalPeriods(timezone, checkedAt);
    const conditional = await answerConditionally(context, principal, options, {
      catalogRevision: catalog.revision,
      modelCatalogRevision: modelCatalog.revision,
      checkedAt,
      rolloverKey: summaryRolloverKey(plan.localDate, checkedAt),
    });
    if (conditional) return conditional;
    const [account, devices, stored, daily, boundary] = await Promise.all([
      options.state.getAccount(principal.account_id),
      options.state.listAccountDevices(principal.account_id),
      options.state.listLatestSnapshots(principal.account_id),
      options.usageState.queryDailyUsage(principal.account_id, {
        from: utcDate(daysBefore(checkedAt, accountUsageAllDays - 1)),
        limit: maximumAccountDailyRows,
      }),
      options.usageState.queryBoundaryHours(principal.account_id, {
        ranges: plan.boundaries.map((edge) => edge.range),
        limit: maximumAccountDailyRows,
      }),
    ]);
    if (!account) return unauthorized(context);
    // `daily.truncated` is not a failure here. The rollup is read newest first, so what a
    // truncated read drops is the far end of `all` — which is a window this route defines — and
    // never a day the three trailing periods fold. An account that has outgrown one response
    // gets a shorter history, not a permanently unanswerable summary.
    if (
      devices.length > maximumAccountDevices ||
      stored.length > maximumAccountSnapshots ||
      boundary.truncated
    ) {
      return resultLimit(context);
    }
    const lastObserved = newestObservationPerDevice(stored);
    try {
      return context.json(
        AccountSummarySchema.parse({
          protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
          account: publicAccount(account),
          devices: devices.map((device) => publicDevice(device, lastObserved)),
          subscriptions: resolvedSubscriptions(stored, checkedAt),
          usage: buildAccountUsage({
            daily: daily.rows,
            boundaries: plan.boundaries.map((edge, index) => ({
              periods: edge.periods,
              rows: boundary.ranges[index] ?? [],
            })),
            days: plan.days,
            catalog,
            modelCatalog,
          }),
          pricing_revision: catalog.revision,
          model_catalog_revision: modelCatalog.revision,
        }),
      );
    } catch (error) {
      if (error instanceof UsageSummaryLimitError) return resultLimit(context);
      throw error;
    }
  });

  app.get("/api/v6/account/usage/activity", async (context) => {
    const checkedAt = now();
    const principal = await accountReader(context, options, checkedAt);
    if (principal instanceof Response) return principal;
    if (!hasOnlyQueryKeys(context, ["from", "to"])) return invalidRequest(context);
    const range = UsageActivityRangeSchema.safeParse({
      from: context.req.query("from"),
      to: context.req.query("to"),
    });
    if (!range.success) return invalidRequest(context);
    // The range is pinned by the request, so nothing about this answer turns over on its own.
    const conditional = await answerConditionally(context, principal, options, {
      catalogRevision: catalog.revision,
      modelCatalogRevision: modelCatalog.revision,
      checkedAt,
      rolloverKey: null,
    });
    if (conditional) return conditional;
    const daily = await options.usageState.queryDailyUsage(principal.account_id, {
      from: range.data.from,
      to: range.data.to,
      limit: maximumAccountDailyRows,
    });
    if (daily.truncated) return resultLimit(context);
    try {
      return context.json(
        AccountUsageActivityResponseSchema.parse({
          protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
          days: buildActivityDays({ rows: daily.rows, catalog }),
        }),
      );
    } catch (error) {
      if (error instanceof UsageSummaryLimitError) return resultLimit(context);
      throw error;
    }
  });

  app.delete("/api/v2/account", async (context) => {
    const principal = await authorizeAccount(context, options, "account:manage", now());
    if (principal instanceof Response) {
      return principal;
    }
    const limited = await enforceRateLimit(
      context,
      options.state,
      options.hasher,
      "account-delete",
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
    if (!(await options.state.deleteAccountData(principal.account_id))) {
      return notFound(context);
    }
    context.header("Set-Cookie", clearedSessionCookie(), { append: true });
    return context.body(null, 204);
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
    const principal = await deviceWriter(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const control = await options.state.getDeviceSyncControl(
      principal.device_id,
      principal.device_generation,
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
        usage_deleted_before: control.usage_deleted_before,
        usage_sync_revision: control.usage_sync_revision,
      }),
    );
  });

  app.put("/api/v2/device/profile", async (context) => {
    const principal = await deviceWriter(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const raw = await parseRawJSON(context);
    if (raw instanceof Response) {
      return raw;
    }
    const parsed = DeviceProfileUpdateRequestSchema.safeParse(raw);
    if (!parsed.success) {
      return invalidRequest(context);
    }
    const updated = await options.state.updateDeviceProfile(
      principal.device_id,
      principal.device_generation,
      parsed.data.display_name,
      parsed.data.platform,
      now().toISOString(),
    );
    if (!updated) {
      return unauthorized(context);
    }
    return context.json(
      DeviceProfileUpdateResponseSchema.parse({
        protocol_version: PROTOCOL_VERSION,
        status: "updated",
        device_id: principal.device_id,
      }),
    );
  });

  app.put("/api/v6/device/snapshots", async (context) => {
    const principal = await deviceWriter(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const envelope = await parseJSON(context, QuotaSnapshotEnvelopeSchema);
    if (envelope instanceof Response) {
      return envelope;
    }
    const written = await options.state.recordSnapshot(principal, envelope, now().toISOString());
    if (written.outcome === "stale_device") {
      return relayError(context, 409, "stale_generation", "The device generation is stale.");
    }
    return context.json(
      QuotaSnapshotUploadResponseSchema.parse({
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
        device_id: principal.device_id,
        device_generation: principal.device_generation,
        accepted: written.accepted,
        ignored: written.ignored,
      }),
    );
  });

  app.put("/api/v6/device/usage", async (context) => {
    const principal = await deviceWriter(context, options, now());
    if (principal instanceof Response) {
      return principal;
    }
    const upload = await parseJSON(context, UsageUploadSchema);
    if (upload instanceof Response) {
      return upload;
    }
    const written = await options.usageState.recordUsage(principal, upload, now().toISOString());
    if (written.outcome === "stale_device") {
      return relayError(context, 409, "stale_generation", "The device generation is stale.");
    }
    return context.json(
      UsageUploadResponseSchema.parse({
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
        device_id: principal.device_id,
        device_generation: principal.device_generation,
        accepted: written.accepted,
        ignored: written.ignored,
      }),
    );
  });

  app.get("/api/v2/pricing/catalog", (context) => {
    if (!hasOnlyQueryKeys(context, [])) return invalidRequest(context);
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

  // A request naming an API version this deployment does not serve comes from a caller
  // speaking a contract that has been retired, and telling it only that a resource was missing
  // leaves it retrying a route that will never return. A path naming a version this deployment
  // *does* serve is a wrong path, and stays a wrong path, so a routing mistake of our own
  // cannot hide behind an upgrade prompt.
  app.notFound((context) =>
    speaksARetiredContract(new URL(context.req.url).pathname)
      ? relayError(
          context,
          404,
          "client_upgrade_required",
          "This client speaks a retired contract. Update it to continue.",
        )
      : notFound(context),
  );
  // An unhandled failure is invisible unless it is written down, and a 500 that says nothing
  // about which route produced it cannot be acted on. The error's own name is the most it may
  // carry: its message can quote a request body, a bound parameter, or a token.
  app.onError((error, context) => {
    console.error(
      JSON.stringify({
        event: "relay_request_failed",
        path: new URL(context.req.url).pathname,
        status: 500,
        error: error instanceof Error ? error.name : "Error",
      }),
    );
    return relayError(context, 500, "internal_error", "QuotaRelay could not complete the request.");
  });
  return app;
}

/**
 * Stamps an Account read with its validator and answers a matching conditional request.
 *
 * A client polls these routes on a timer and the answer is almost always the one it already
 * holds. Comparing a handful of aggregates is far cheaper than folding every retained day
 * again, so the validator is computed first and a match returns before any Usage query runs.
 * `no-cache` rather than `no-store`: a browser may keep the body as long as it asks before
 * showing it, which is what makes the conditional request possible at all.
 */
async function answerConditionally(
  context: Context,
  principal: SessionPrincipal,
  options: RelayAppOptions,
  input: {
    catalogRevision: string;
    modelCatalogRevision: string;
    checkedAt: Date;
    /** What makes this answer turn over with no write behind it, or null when nothing does. */
    rolloverKey: string | null;
  },
): Promise<Response | null> {
  const url = new URL(context.req.url);
  const stamp = await options.state.accountVersionStamp(
    principal.account_id,
    new Date(input.checkedAt.getTime() - activeDeviceMilliseconds).toISOString(),
  );
  const entity = await canonicalRequestDigest({
    // Two routes answer the same query string with different bodies, so the path is part of
    // the identity. The Account is in the digest because two empty Accounts have the same
    // stamp, and a client that switched between them must not be told its held body applies.
    account: principal.account_id,
    path: url.pathname,
    query: url.search,
    stamp,
    pricing_revision: input.catalogRevision,
    model_catalog_revision: input.modelCatalogRevision,
    rollover: input.rolloverKey,
  });
  const etag = `"${entity}"`;
  context.header("ETag", etag);
  context.header("Cache-Control", "private, no-cache");
  return context.req.header("If-None-Match") === etag ? context.body(null, 304) : null;
}

async function beginGitHubSignIn(
  context: Context,
  options: RelayAppOptions,
  returnTo: string,
  now: Date,
): Promise<Response> {
  const started = await options.webSessions.beginSignIn(returnTo, now);
  context.header("Set-Cookie", started.handoff, { append: true });
  return context.redirect(started.location, 302);
}

/**
 * The two things that turn a summary over with no write behind it.
 *
 * The caller's local date decides where the three trailing periods start and end. The clock
 * decides which reading speaks for a subscription: a reading stops describing current quota at
 * its own validity boundary, and when it does, a fresher one from another device takes its place
 * and the freshness a reader is shown flips. Bucketing that to the hour is what keeps the
 * boundary rule in one place — `packages/quota-model` derives it from the reading — while still
 * bounding how long a held answer can outlive a flip.
 */
function summaryRolloverKey(localDate: string, checkedAt: Date): string {
  return `${localDate}|${checkedAt.toISOString().slice(0, 13)}`;
}

/** The `tz` a read was asked for, `UTC` when it named none, or null when it named nonsense. */
function requestedTimezone(context: Context): string | null {
  const requested = context.req.query("tz");
  if (requested === undefined) return "UTC";
  const parsed = IanaTimezoneSchema.safeParse(requested);
  return parsed.success ? parsed.data : null;
}

/**
 * The subscriptions behind this Account's observations, resolved once here.
 *
 * Relay keeps one observation per reporting device. Collapsing them is one rule, and it used to
 * be restated by every client that read them, which is how one account collected on three Macs
 * reached the dashboard as three cards. See ADR 0003.
 */
function resolvedSubscriptions(stored: readonly StoredQuotaSnapshot[], checkedAt: Date) {
  return mergeQuotaObservations(stored, checkedAt).map((subscription) => ({
    key: quotaSubscriptionKey(subscription.identity),
    provider: subscription.snapshot.provider,
    snapshot: subscription.snapshot,
    sources: subscription.sources.map((source) => ({
      device_id: source.device_id,
      observed_at: source.observed_at,
    })),
  }));
}

/** When each device's newest stored reading was taken. */
function newestObservationPerDevice(stored: readonly StoredQuotaSnapshot[]): Map<string, string> {
  const newest = new Map<string, string>();
  for (const observation of stored) {
    const current = newest.get(observation.device_id);
    if (current === undefined || observation.snapshot.observed_at > current) {
      newest.set(observation.device_id, observation.snapshot.observed_at);
    }
  }
  return newest;
}

async function accountReader(
  context: Context,
  options: RelayAppOptions,
  checkedAt: Date,
): Promise<SessionPrincipal | Response> {
  return authorizeAccount(context, options, "account:read", checkedAt);
}

/**
 * The principal behind an upload, and the Device it is allowed to write.
 *
 * `device:write` is only ever granted to a session that names a Device, and that session is
 * refused the moment the Device moves past the generation it was opened at, so the scope, the
 * device id, and the generation are one check rather than three.
 */
async function deviceWriter(
  context: Context,
  options: RelayAppOptions,
  checkedAt: Date,
): Promise<DeviceWriterPrincipal | Response> {
  const principal = await authorizeAccount(context, options, "device:write", checkedAt);
  if (principal instanceof Response) {
    return principal;
  }
  if (principal.device_id === null || principal.device_generation === null) {
    return forbidden(context);
  }
  return principal as DeviceWriterPrincipal;
}

/**
 * Whoever is asking, from the one place a session is stored.
 *
 * A Bearer token names its own credential domain through the prefix it carries; a request with no
 * Bearer token is a browser, whose cookie is hashed under a domain of its own, so a cookie cannot
 * be presented as a Bearer token or the reverse ([ADR 0025](../../docs/decisions/0025-one-session-system.md)).
 */
async function authorizeAccount(
  context: Context,
  options: RelayAppOptions,
  scope: SessionScope,
  checkedAt: Date,
): Promise<SessionPrincipal | Response> {
  const token = bearerToken(context.req.header("Authorization"));
  if (token) {
    const domain = accessTokenDomain(token);
    if (!domain) return unauthorized(context);
    const principal = await options.state.authorizeSession(
      await options.hasher.hash(domain, token),
      checkedAt.toISOString(),
      scope === "device:write",
    );
    if (!principal) return unauthorized(context);
    return principal.scopes.includes(scope) ? principal : forbidden(context);
  }
  const principal = await options.webSessions.authorize(context.req.raw.headers, checkedAt);
  if (!principal) return unauthorized(context);
  return principal.scopes.includes(scope) ? principal : forbidden(context);
}

function requireRecentWebMutation(
  context: Context,
  principal: SessionPrincipal,
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

function requireWebOrigin(context: Context, principal: SessionPrincipal): Response | null {
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

/**
 * A device as an Account reads it.
 *
 * The two instants Relay witnessed — when the device last called, and when the newest reading it
 * sent was taken — are what a reader needs; how recently it spoke is derived from them rather
 * than reported as a status.
 */
function publicDevice(device: DeviceRecord, lastObserved: ReadonlyMap<string, string>) {
  return {
    id: device.id,
    display_name: device.display_name ?? "Quota client",
    platform: device.platform ?? "macos",
    last_seen_at: device.last_seen_at,
    last_observed_at: lastObserved.get(device.id) ?? null,
  };
}

function iosOAuthTokenResponse(
  issued: Awaited<ReturnType<AccountService["exchangeIosAuthorizationCode"]>>,
) {
  return {
    protocol_version: PROTOCOL_VERSION,
    token_type: issued.token_type,
    account_id: issued.account_id,
    display_label: issued.display_label,
    session: sessionToken(issued.session),
  };
}

function oauthTokenResponse(
  issued: Awaited<ReturnType<AccountService["exchangeAuthorizationCode"]>>,
) {
  return {
    protocol_version: PROTOCOL_VERSION,
    token_type: issued.token_type,
    account_id: issued.account_id,
    display_label: issued.display_label,
    device_id: issued.device_id,
    device_generation: issued.device_generation,
    usage_deleted_before: issued.usage_deleted_before,
    usage_sync_revision: issued.usage_sync_revision,
    session: sessionToken(issued.session),
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

const servedApiVersions: ReadonlySet<number> = new Set<number>([
  PROTOCOL_VERSION,
  MANAGED_DATA_PROTOCOL_VERSION,
]);

function speaksARetiredContract(pathname: string): boolean {
  const version = /^\/api\/v(\d{1,3})\//.exec(pathname)?.[1];
  return version !== undefined && !servedApiVersions.has(Number(version));
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
