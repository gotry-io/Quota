import {
  OwnerCreateResponseSchema,
  OwnerSnapshotListResponseSchema,
  DeviceListResponseSchema,
  PairingApprovalRequestSchema,
  PairingCreateRequestSchema,
  type PairingCreateResponse,
  PairingDenialRequestSchema,
  type PairingTokenIssuedResponse,
  type PairingTokenPendingResponse,
  PairingTokenRequestSchema,
  QuotaSnapshotEnvelopeSchema,
  type RelayErrorCode,
  type RelayErrorEnvelope,
  type RelayInfo,
} from "@gotry-io/quota-protocol";
import type {
  OwnerAuthScope,
  OwnerSessionRecord,
  DeviceRecord,
  RelayState,
} from "@gotry-io/relay-core";
import { type Context, Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { bearerToken, randomOpaqueSecret, randomUserCode, sha256Hex } from "./security.ts";

const pairingLifetimeSeconds = 10 * 60;
const pairingSessionRetentionSeconds = 24 * 60 * 60;
const pairingPollIntervalSeconds = 5;
const maximumJSONBodyBytes = 64 * 1024;
const ownerSessionExpiresAt = "9999-12-31T23:59:59.999Z";
export const deviceInactivitySeconds = 30 * 24 * 60 * 60;

const rateLimits = {
  ownerCreate: { limit: 10, windowSeconds: 60 * 60 },
  pairingCreate: { limit: 300, windowSeconds: 10 * 60 },
  pairingPollClient: { limit: 10_000, windowSeconds: 10 * 60 },
  pairingPollPerCode: { limit: 130, windowSeconds: 10 * 60 },
  pairingDecision: { limit: 30, windowSeconds: 10 * 60 },
} as const;

interface StrictSchema<Output> {
  safeParse(value: unknown): { success: true; data: Output } | { success: false };
}

interface DevicePrincipal {
  device: DeviceRecord;
  tokenHash: string;
}

export interface RelayAppOptions {
  state: RelayState;
  relayInfo: RelayInfo;
  now?: () => Date;
}

export function createRelayApp(options: RelayAppOptions): Hono {
  const app = new Hono();
  const now = options.now ?? (() => new Date());

  app.get("/healthz", (context) =>
    context.json({
      status: "ok",
      service: "QuotaRelay",
      version: options.relayInfo.version,
    }),
  );

  app.get("/readyz", async (context) => {
    try {
      await options.state.ping();
      return context.json({ status: "ready" });
    } catch {
      return context.json({ status: "unavailable" }, 503);
    }
  });

  app.get("/.well-known/quotabar-relay", (context) => context.json(options.relayInfo));

  app.use("/api/v1/*", async (context, next) => {
    await next();
    context.header("Cache-Control", "no-store");
  });
  app.use(
    "/api/v1/*",
    bodyLimit({
      maxSize: maximumJSONBodyBytes,
      onError: requestBodyTooLarge,
    }),
  );

  // Anonymous owner registration is available on managed and self-hosted Relays.
  // Each registration creates an isolated ephemeral group; the bearer is returned once.
  app.post("/api/v1/owners", async (context) => {
    const limited = await enforceRateLimit(
      context,
      options.state,
      "owner_create",
      anonymousClientSubject(context, options.relayInfo),
      rateLimits.ownerCreate,
      now(),
    );
    if (limited) {
      return limited;
    }

    const createdAt = now().toISOString();
    const ownerToken = randomOpaqueSecret();
    await options.state.createOwner({
      id: `owner_${crypto.randomUUID()}`,
      session_id: `owner_session_${crypto.randomUUID()}`,
      token_hash: await sha256Hex(ownerToken),
      scopes: ["quota:read", "device:manage"],
      expires_at: ownerSessionExpiresAt,
      created_at: createdAt,
    });

    return context.json(OwnerCreateResponseSchema.parse({ owner_token: ownerToken }), 201);
  });

  app.delete("/api/v1/owners/self", async (context) => {
    const principal = await authorizeOwner(context, options.state, "device:manage", now());
    if (principal instanceof Response) {
      return principal;
    }
    await options.state.deleteOwner(principal.owner_id);
    return context.body(null, 204);
  });

  app.post("/api/v1/pairings", async (context) => {
    const limited = await enforceRateLimit(
      context,
      options.state,
      "pairing_create",
      anonymousClientSubject(context, options.relayInfo),
      rateLimits.pairingCreate,
      now(),
    );
    if (limited) {
      return limited;
    }

    const body = await parseBody(context, PairingCreateRequestSchema);
    if (body instanceof Response) {
      return body;
    }

    const createdAt = now();
    const expiresAt = new Date(createdAt.getTime() + pairingLifetimeSeconds * 1000);
    const deviceCode = randomOpaqueSecret();
    const userCode = randomUserCode();
    await options.state.createPairingSession({
      id: `pairing_${crypto.randomUUID()}`,
      device_code_hash: await sha256Hex(deviceCode),
      user_code_hash: await sha256Hex(normalizeUserCode(userCode)),
      device_display_name: body.device_display_name,
      expires_at: expiresAt.toISOString(),
      created_at: createdAt.toISOString(),
    });

    const response: PairingCreateResponse = {
      device_code: deviceCode,
      user_code: userCode,
      expires_at: expiresAt.toISOString(),
      poll_interval_seconds: pairingPollIntervalSeconds,
    };
    return context.json(response, 201);
  });

  app.post("/api/v1/pairings/token", async (context) => {
    const body = await parseBody(context, PairingTokenRequestSchema);
    if (body instanceof Response) {
      return body;
    }
    const deviceCodeHash = await sha256Hex(body.device_code);
    const clientLimited = await enforceRateLimit(
      context,
      options.state,
      "pairing_poll_client",
      anonymousClientSubject(context, options.relayInfo),
      rateLimits.pairingPollClient,
      now(),
    );
    if (clientLimited) {
      return clientLimited;
    }
    const codeLimited = await enforceRateLimit(
      context,
      options.state,
      "pairing_poll",
      deviceCodeHash,
      rateLimits.pairingPollPerCode,
      now(),
    );
    if (codeLimited) {
      return codeLimited;
    }

    const issuedAt = now();
    const deviceID = `device_${crypto.randomUUID()}`;
    const deviceToken = randomOpaqueSecret();
    const outcome = await options.state.consumePairingSession({
      device_code_hash: deviceCodeHash,
      device_id: deviceID,
      token_hash: await sha256Hex(deviceToken),
      consumed_at: issuedAt.toISOString(),
    });

    switch (outcome) {
      case "issued": {
        const response: PairingTokenIssuedResponse = {
          device_id: deviceID,
          device_token: deviceToken,
        };
        return context.json(response);
      }
      case "pending": {
        const response: PairingTokenPendingResponse = {
          status: "pending",
          poll_interval_seconds: pairingPollIntervalSeconds,
        };
        return context.json(response, 202);
      }
      case "denied":
        return relayError(context, 409, "pairing_denied", "The pairing request was denied.");
      case "expired":
        return relayError(context, 410, "pairing_expired", "The pairing request expired.");
      case "consumed":
        return relayError(
          context,
          409,
          "pairing_consumed",
          "The pairing request was already consumed.",
        );
      case "not_found":
        return relayError(context, 404, "not_found", "The pairing request was not found.");
    }
  });

  app.post("/api/v1/pairings/approve", async (context) => {
    return decidePairing(context, options.state, "approve", now);
  });

  app.post("/api/v1/pairings/deny", async (context) => {
    return decidePairing(context, options.state, "deny", now);
  });

  app.post("/api/v1/snapshots", async (context) => {
    const principal = await authorizeDevice(context, options.state, now());
    if (principal instanceof Response) {
      return principal;
    }
    const envelope = await parseBody(context, QuotaSnapshotEnvelopeSchema);
    if (envelope instanceof Response) {
      return envelope;
    }
    if (principal.device.id !== envelope.device_id) {
      return relayError(
        context,
        403,
        "forbidden",
        "A device token can write snapshots only for its own device.",
      );
    }

    try {
      await options.state.recordSnapshot(envelope, now().toISOString());
    } catch {
      const stillActive = await options.state.getDeviceByTokenHash(principal.tokenHash);
      if (!stillActive || stillActive.revoked_at) {
        return unauthorized(context);
      }
      throw new Error("Snapshot persistence failed");
    }
    return context.body(null, 204);
  });

  app.get("/api/v1/snapshots", async (context) => {
    const checkedAt = now();
    const principal = await authorizeOwner(context, options.state, "quota:read", checkedAt);
    if (principal instanceof Response) {
      return principal;
    }
    await revokeInactiveDevicesForOwner(options.state, principal.owner_id, checkedAt);
    const response = OwnerSnapshotListResponseSchema.parse({
      observations: await options.state.listLatestSnapshots(principal.owner_id),
    });
    return context.json(response);
  });

  app.get("/api/v1/devices", async (context) => {
    const checkedAt = now();
    const principal = await authorizeOwner(context, options.state, "device:manage", checkedAt);
    if (principal instanceof Response) {
      return principal;
    }
    await revokeInactiveDevicesForOwner(options.state, principal.owner_id, checkedAt);
    const devices = await options.state.listDevices(principal.owner_id);
    const response = DeviceListResponseSchema.parse({
      devices: devices.map((device) => ({
        device_id: device.id,
        display_name: device.display_name,
        created_at: device.created_at,
        last_seen_at: device.last_seen_at,
        last_sequence: device.last_sequence,
        revoked_at: device.revoked_at,
      })),
    });
    return context.json(response);
  });

  app.delete("/api/v1/devices/self", async (context) => {
    const revokedAt = now();
    const token = bearerToken(context.req.header("Authorization"));
    if (!token) {
      return unauthorized(context);
    }
    const device = await options.state.getDeviceByTokenHash(await sha256Hex(token));
    if (!device) {
      return unauthorized(context);
    }
    if (!device.revoked_at) {
      await options.state.revokeDevice(device.owner_id, device.id, revokedAt.toISOString());
    }
    return context.body(null, 204);
  });

  app.delete("/api/v1/devices/:device_id", async (context) => {
    const checkedAt = now();
    const principal = await authorizeOwner(context, options.state, "device:manage", checkedAt);
    if (principal instanceof Response) {
      return principal;
    }
    await revokeInactiveDevicesForOwner(options.state, principal.owner_id, checkedAt);
    const revoked = await options.state.revokeDevice(
      principal.owner_id,
      context.req.param("device_id"),
      checkedAt.toISOString(),
    );
    if (!revoked) {
      return relayError(context, 404, "not_found", "The device was not found.");
    }
    return context.body(null, 204);
  });

  app.notFound((context) =>
    relayError(context, 404, "not_found", "The requested QuotaRelay endpoint does not exist."),
  );

  app.onError((_error, context) =>
    relayError(context, 500, "internal_error", "QuotaRelay could not complete the request."),
  );

  return app;
}

async function decidePairing(
  context: Context,
  state: RelayState,
  decision: "approve" | "deny",
  now: () => Date,
): Promise<Response> {
  const principal = await authorizeOwner(context, state, "device:manage", now());
  if (principal instanceof Response) {
    return principal;
  }
  const limited = await enforceRateLimit(
    context,
    state,
    "pairing_decision",
    principal.owner_id,
    rateLimits.pairingDecision,
    now(),
  );
  if (limited) {
    return limited;
  }
  const schema = decision === "approve" ? PairingApprovalRequestSchema : PairingDenialRequestSchema;
  const body = await parseBody(context, schema);
  if (body instanceof Response) {
    return body;
  }
  const outcome = await state.decidePairingSession({
    user_code_hash: await sha256Hex(normalizeUserCode(body.user_code)),
    owner_id: principal.owner_id,
    decision,
    decided_at: now().toISOString(),
  });

  if (
    (decision === "approve" && outcome === "approved") ||
    (decision === "deny" && outcome === "denied")
  ) {
    return context.body(null, 204);
  }
  switch (outcome) {
    case "expired":
      return relayError(context, 410, "pairing_expired", "The pairing request expired.");
    case "consumed":
      return relayError(
        context,
        409,
        "pairing_consumed",
        "The pairing request was already consumed.",
      );
    case "not_found":
      return relayError(context, 404, "not_found", "The pairing request was not found.");
    case "already_decided":
    case "approved":
    case "denied":
      return relayError(context, 409, "conflict", "The pairing request was already decided.");
  }
}

async function authorizeOwner(
  context: Context,
  state: RelayState,
  requiredScope: OwnerAuthScope,
  checkedAt: Date,
): Promise<OwnerSessionRecord | Response> {
  const token = bearerToken(context.req.header("Authorization"));
  if (!token) {
    return unauthorized(context);
  }
  const session = await state.getActiveOwnerSessionByTokenHash(
    await sha256Hex(token),
    checkedAt.toISOString(),
  );
  if (!session) {
    return unauthorized(context);
  }
  if (!session.scopes.includes(requiredScope)) {
    return relayError(context, 403, "forbidden", "The bearer token lacks the required scope.");
  }
  return session;
}

async function authorizeDevice(
  context: Context,
  state: RelayState,
  checkedAt: Date,
): Promise<DevicePrincipal | Response> {
  const token = bearerToken(context.req.header("Authorization"));
  if (!token) {
    return unauthorized(context);
  }
  const tokenHash = await sha256Hex(token);
  const device = await state.getDeviceByTokenHash(tokenHash);
  if (!device || device.revoked_at) {
    return unauthorized(context);
  }
  if (deviceIsInactive(device, checkedAt)) {
    const revoked = await state.revokeDeviceIfInactive(
      tokenHash,
      inactivityCutoff(checkedAt),
      checkedAt.toISOString(),
    );
    if (revoked) {
      return unauthorized(context);
    }
    const refreshed = await state.getDeviceByTokenHash(tokenHash);
    if (!refreshed || refreshed.revoked_at || deviceIsInactive(refreshed, checkedAt)) {
      return unauthorized(context);
    }
    return { device: refreshed, tokenHash };
  }
  return { device, tokenHash };
}

export async function performRelayMaintenance(state: RelayState, checkedAt: Date): Promise<void> {
  await state.performMaintenance({
    inactive_before: inactivityCutoff(checkedAt),
    pairing_expired_before: new Date(
      checkedAt.getTime() - pairingSessionRetentionSeconds * 1000,
    ).toISOString(),
    maintained_at: checkedAt.toISOString(),
  });
}

async function revokeInactiveDevicesForOwner(
  state: RelayState,
  ownerId: string,
  checkedAt: Date,
): Promise<number> {
  return state.revokeInactiveDevicesForOwner(
    ownerId,
    inactivityCutoff(checkedAt),
    checkedAt.toISOString(),
  );
}

function deviceIsInactive(device: DeviceRecord, checkedAt: Date): boolean {
  return (
    Date.parse(device.last_seen_at ?? device.created_at) <= Date.parse(inactivityCutoff(checkedAt))
  );
}

function inactivityCutoff(checkedAt: Date): string {
  return new Date(checkedAt.getTime() - deviceInactivitySeconds * 1000).toISOString();
}

function anonymousClientSubject(context: Context, relayInfo: RelayInfo): string {
  if (relayInfo.mode === "managed") {
    return context.req.header("CF-Connecting-IP") ?? "relay_global";
  }
  return "relay_global";
}

async function enforceRateLimit(
  context: Context,
  state: RelayState,
  action: string,
  subject: string,
  policy: { limit: number; windowSeconds: number },
  checkedAt: Date,
): Promise<Response | null> {
  const windowMilliseconds = policy.windowSeconds * 1000;
  const windowStartedAt = new Date(
    Math.floor(checkedAt.getTime() / windowMilliseconds) * windowMilliseconds,
  );
  const windowExpiresAt = new Date(windowStartedAt.getTime() + windowMilliseconds);
  const result = await state.consumeRateLimit({
    key_hash: await sha256Hex(`rate-limit:${action}:${subject}`),
    window_started_at: windowStartedAt.toISOString(),
    window_expires_at: windowExpiresAt.toISOString(),
    checked_at: checkedAt.toISOString(),
    limit: policy.limit,
  });
  if (result.allowed) {
    return null;
  }
  context.header("Retry-After", String(result.retry_after));
  return relayError(context, 429, "rate_limited", "Too many requests. Retry later.");
}

async function parseBody<Output>(
  context: Context,
  schema: StrictSchema<Output>,
): Promise<Output | Response> {
  let value: unknown;
  try {
    const text = await context.req.text();
    value = JSON.parse(text);
  } catch {
    return relayError(context, 400, "invalid_request", "The request body must be valid JSON.");
  }
  const parsed = schema.safeParse(value);
  if (!parsed.success) {
    return relayError(context, 400, "invalid_request", "The request body is invalid.");
  }
  return parsed.data;
}

function requestBodyTooLarge(context: Context): Response {
  return relayError(context, 413, "invalid_request", "The request body exceeds the 64 KiB limit.");
}

function unauthorized(context: Context): Response {
  context.header("WWW-Authenticate", 'Bearer realm="QuotaRelay"');
  return relayError(context, 401, "unauthorized", "A valid bearer token is required.");
}

function relayError(
  context: Context,
  status: 400 | 401 | 403 | 404 | 409 | 410 | 413 | 429 | 500,
  code: RelayErrorCode,
  message: string,
): Response {
  const body: RelayErrorEnvelope = { error: { code, message } };
  return context.json(body, status);
}

function normalizeUserCode(value: string): string {
  return value.trim().toUpperCase();
}
