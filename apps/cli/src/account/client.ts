import type {
  AccountSummary,
  DeviceAuthorizationRequest,
  DeviceAuthorizationResponse,
  DeviceSyncResponse,
  OAuthTokenRequest,
  OAuthTokenResponse,
  PricingCatalog,
  QuotaSnapshotEnvelope,
  QuotaSnapshotUploadResponse,
  SessionRefreshRequest,
  SessionRefreshResponse,
  UsageSubmissionV2,
  UsageUploadResponse,
} from "@gotry-io/quota-protocol";
import {
  AccountSummarySchema,
  DeviceAuthorizationRequestSchema,
  DeviceAuthorizationResponseSchema,
  DeviceSyncResponseSchema,
  OAuthTokenRequestSchema,
  OAuthTokenResponseSchema,
  PricingCatalogSchema,
  QuotaSnapshotEnvelopeSchema,
  QuotaSnapshotUploadResponseSchema,
  SessionRefreshRequestSchema,
  SessionRefreshResponseSchema,
  UsageSubmissionSchema,
  UsageUploadResponseSchema,
} from "@gotry-io/quota-protocol";

export const QUOTA_ACCOUNT_ORIGIN = "https://quota.gotry.io";

const REQUEST_TIMEOUT_MILLISECONDS = 20_000;
const RESPONSE_LIMIT_BYTES = 1024 * 1024;

export type AccountFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export class AccountClientError extends Error {
  readonly code: string;
  readonly status?: number;
  readonly retryAfterMilliseconds?: number;

  constructor(
    code: string,
    message: string,
    options: { status?: number; retryAfterMilliseconds?: number } = {},
  ) {
    super(message);
    this.name = "AccountClientError";
    this.code = code;
    if (options.status !== undefined) this.status = options.status;
    if (options.retryAfterMilliseconds !== undefined) {
      this.retryAfterMilliseconds = options.retryAfterMilliseconds;
    }
  }
}

export interface AccountClientOptions {
  origin?: string;
  fetch?: AccountFetch;
  timeoutMilliseconds?: number;
}

export class AccountClient {
  readonly origin: string;
  readonly #fetch: AccountFetch;
  readonly #timeoutMilliseconds: number;

  constructor(options: AccountClientOptions = {}) {
    this.origin = canonicalManagedOrigin(options.origin ?? QUOTA_ACCOUNT_ORIGIN);
    this.#fetch = options.fetch ?? fetch;
    this.#timeoutMilliseconds = options.timeoutMilliseconds ?? REQUEST_TIMEOUT_MILLISECONDS;
  }

  async beginDeviceAuthorization(
    input: DeviceAuthorizationRequest,
  ): Promise<DeviceAuthorizationResponse> {
    const request = DeviceAuthorizationRequestSchema.parse(input);
    const response = await this.#request("/oauth/v2/device/code", "POST", request);
    return parseResponse(DeviceAuthorizationResponseSchema, response, 201);
  }

  async exchangeToken(input: OAuthTokenRequest): Promise<OAuthTokenResponse> {
    const request = OAuthTokenRequestSchema.parse(input);
    const response = await this.#request("/oauth/v2/token", "POST", request);
    return parseResponse(OAuthTokenResponseSchema, response, 200);
  }

  async refreshSession(input: SessionRefreshRequest): Promise<SessionRefreshResponse> {
    const request = SessionRefreshRequestSchema.parse(input);
    const response = await this.#request("/oauth/v2/token", "POST", request);
    return parseResponse(SessionRefreshResponseSchema, response, 200);
  }

  async revoke(token: string): Promise<void> {
    requireToken(token);
    const response = await this.#request("/oauth/v2/revoke", "POST", undefined, token);
    if (response.status !== 204 && response.status !== 200) throw responseError(response);
  }

  async syncControl(deviceAccessToken: string): Promise<DeviceSyncResponse> {
    requireToken(deviceAccessToken);
    const response = await this.#request(
      "/api/v2/device/sync",
      "GET",
      undefined,
      deviceAccessToken,
    );
    return parseResponse(DeviceSyncResponseSchema, response, 200);
  }

  async uploadSnapshot(
    deviceAccessToken: string,
    input: QuotaSnapshotEnvelope,
  ): Promise<QuotaSnapshotUploadResponse> {
    requireToken(deviceAccessToken);
    const request = QuotaSnapshotEnvelopeSchema.parse(input);
    const response = await this.#request(
      "/api/v2/device/snapshots",
      "PUT",
      request,
      deviceAccessToken,
    );
    return parseResponse(QuotaSnapshotUploadResponseSchema, response, 200);
  }

  async uploadUsage(
    deviceAccessToken: string,
    input: UsageSubmissionV2,
  ): Promise<UsageUploadResponse> {
    requireToken(deviceAccessToken);
    const request = UsageSubmissionSchema.parse(input);
    const response = await this.#request("/api/v2/device/usage", "PUT", request, deviceAccessToken);
    return parseResponse(UsageUploadResponseSchema, response, [200, 409]);
  }

  async accountSummary(accountAccessToken: string, query = ""): Promise<AccountSummary> {
    requireToken(accountAccessToken);
    const suffix = query ? `?${query}` : "";
    const response = await this.#request(
      `/api/v2/account/summary${suffix}`,
      "GET",
      undefined,
      accountAccessToken,
    );
    return parseResponse(AccountSummarySchema, response, 200);
  }

  async pricingCatalog(
    etag?: string,
  ): Promise<
    | { status: "not_modified"; etag: string | null }
    | { status: "updated"; etag: string | null; catalog: PricingCatalog }
  > {
    const response = await this.#request(
      "/api/v2/pricing/catalog",
      "GET",
      undefined,
      undefined,
      etag ? { "If-None-Match": etag } : undefined,
    );
    if (response.status === 304) {
      return { status: "not_modified", etag: response.headers.get("etag") };
    }
    return {
      status: "updated",
      etag: response.headers.get("etag"),
      catalog: parseResponse(PricingCatalogSchema, response, 200),
    };
  }

  async #request(
    path: string,
    method: "GET" | "POST" | "PUT",
    body?: unknown,
    token?: string,
    extraHeaders?: Readonly<Record<string, string>>,
  ): Promise<AccountResponse> {
    const signal = AbortSignal.timeout(this.#timeoutMilliseconds);
    try {
      const headers = new Headers({ Accept: "application/json", ...extraHeaders });
      if (body !== undefined) headers.set("Content-Type", "application/json");
      if (token !== undefined) headers.set("Authorization", `Bearer ${token}`);
      const init: RequestInit = {
        method,
        headers,
        redirect: "error",
        signal,
      };
      if (body !== undefined) init.body = JSON.stringify(body);
      const response = await this.#fetch(`${this.origin}${path}`, init);
      const text = response.status === 304 ? "" : await readBoundedBody(response);
      let json: unknown = null;
      if (text.length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          if (response.ok) throw invalidResponse(response.status);
        }
      }
      return { status: response.status, headers: response.headers, json };
    } catch (error) {
      if (error instanceof AccountClientError) throw error;
      if (signal.aborted) throw new AccountClientError("timeout", "The Quota request timed out.");
      throw new AccountClientError("unavailable", "The Quota service is unavailable.");
    }
  }
}

interface AccountResponse {
  status: number;
  headers: Headers;
  json: unknown;
}

interface RuntimeSchema<T> {
  safeParse(value: unknown): { success: true; data: T } | { success: false };
}

function parseResponse<T>(
  schema: RuntimeSchema<T>,
  response: AccountResponse,
  status: number | readonly number[],
): T {
  if (!(Array.isArray(status) ? status.includes(response.status) : response.status === status)) {
    throw responseError(response);
  }
  const parsed = schema.safeParse(response.json);
  if (!parsed.success) throw invalidResponse(response.status);
  return parsed.data;
}

function responseError(response: AccountResponse): AccountClientError {
  const error = readErrorCode(response.json);
  const retryAfter = response.headers.get("retry-after");
  const seconds = retryAfter === null ? Number.NaN : Number(retryAfter);
  return new AccountClientError(
    error ?? statusCode(response.status),
    safeErrorMessage(response.status),
    {
      status: response.status,
      ...(Number.isFinite(seconds) && seconds >= 0
        ? { retryAfterMilliseconds: Math.ceil(seconds * 1000) }
        : {}),
    },
  );
}

function readErrorCode(value: unknown): string | undefined {
  if (!isRecord(value) || !isRecord(value.error)) return undefined;
  const code = value.error.code;
  return typeof code === "string" && /^[a-z0-9_]{1,64}$/.test(code) ? code : undefined;
}

function safeErrorMessage(status: number): string {
  if (status === 401) return "Quota authentication is required.";
  if (status === 403) return "The Quota session is not allowed to perform this action.";
  if (status === 404) return "The requested Quota resource was not found.";
  if (status === 409) return "The Quota device state changed; sign in again.";
  if (status === 429) return "Quota requests are temporarily rate limited.";
  return "The Quota request failed.";
}

function statusCode(status: number): string {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 404) return "not_found";
  if (status === 409) return "conflict";
  if (status === 429) return "rate_limited";
  return status >= 500 ? "unavailable" : "invalid_request";
}

function invalidResponse(status?: number): AccountClientError {
  return new AccountClientError("invalid_response", "The Quota response was invalid.", {
    ...(status === undefined ? {} : { status }),
  });
}

function requireToken(token: string): void {
  if (token.length < 16 || token.length > 4096 || token.trim() !== token) {
    throw new AccountClientError("invalid_request", "The Quota session is invalid.");
  }
}

async function readBoundedBody(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > RESPONSE_LIMIT_BYTES) throw invalidResponse(response.status);
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(output);
}

function canonicalManagedOrigin(value: string): string {
  const url = new URL(value);
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new AccountClientError("invalid_request", "The Quota service origin is invalid.");
  }
  const loopback =
    url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
  if (url.origin !== QUOTA_ACCOUNT_ORIGIN && !(loopback && url.protocol === "http:")) {
    throw new AccountClientError(
      "invalid_request",
      "QuotaCLI only connects to the managed service.",
    );
  }
  return url.origin;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
