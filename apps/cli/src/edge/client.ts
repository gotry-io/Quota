import {
  PairingCreateRequestSchema,
  type PairingCreateResponse,
  PairingCreateResponseSchema,
  type PairingTokenIssuedResponse,
  PairingTokenIssuedResponseSchema,
  PairingTokenPendingResponseSchema,
  PairingTokenRequestSchema,
  PROTOCOL_VERSION,
  type QuotaSnapshotEnvelope,
  QuotaSnapshotEnvelopeSchema,
  type RelayErrorCode,
  RelayErrorEnvelopeSchema,
  type RelayInfo,
  RelayInfoSchema,
} from "@gotry-io/quota-protocol";
import { canonicalRelayUrl, DEFAULT_RELAY_URL } from "./url.ts";

const HTTP_TIMEOUT_MILLISECONDS = 20_000;
const HTTP_BODY_LIMIT_BYTES = 1024 * 1024;

export type RelayFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export type RelayClientErrorCode =
  | RelayErrorCode
  | "invalid_response"
  | "unsupported_relay"
  | "timeout"
  | "unavailable";

export class RelayClientError extends Error {
  readonly code: RelayClientErrorCode;
  readonly status?: number;
  readonly retryAfterMilliseconds?: number;

  constructor(
    code: RelayClientErrorCode,
    message: string,
    options: { status?: number; retryAfterMilliseconds?: number } = {},
  ) {
    super(message);
    this.name = "RelayClientError";
    this.code = code;
    if (options.status !== undefined) {
      this.status = options.status;
    }
    if (options.retryAfterMilliseconds !== undefined) {
      this.retryAfterMilliseconds = options.retryAfterMilliseconds;
    }
  }
}

export interface RelayClientOptions {
  fetch?: RelayFetch;
  now?: () => Date;
  sleep?: (milliseconds: number) => Promise<void>;
}

export class RelayClient {
  readonly relayUrl: string;

  readonly #fetch: RelayFetch;
  readonly #now: () => Date;
  readonly #sleep: (milliseconds: number) => Promise<void>;

  constructor(relayUrl = DEFAULT_RELAY_URL, options: RelayClientOptions = {}) {
    this.relayUrl = canonicalRelayUrl(relayUrl);
    this.#fetch = options.fetch ?? fetch;
    this.#now = options.now ?? (() => new Date());
    this.#sleep = options.sleep ?? sleep;
  }

  async discover(): Promise<RelayInfo> {
    const response = await this.#request("/.well-known/quotabar-relay", "GET");
    if (response.status !== 200) {
      throw this.#responseError(response);
    }

    const parsed = RelayInfoSchema.safeParse(response.json);
    if (!parsed.success) {
      throw invalidResponse(response.status);
    }
    const info = parsed.data;
    if (
      !info.api_versions.includes(PROTOCOL_VERSION) ||
      !info.auth_methods.includes("bearer") ||
      !info.capabilities.persistent_snapshots ||
      !info.capabilities.instant_device_revocation
    ) {
      throw new RelayClientError(
        "unsupported_relay",
        "The Relay does not support the required Quota edge capabilities.",
      );
    }
    return info;
  }

  async createPairing(deviceDisplayName: string): Promise<PairingCreateResponse> {
    const request = PairingCreateRequestSchema.safeParse({
      device_display_name: deviceDisplayName,
    });
    if (!request.success) {
      throw new RelayClientError("invalid_request", "The device display name is invalid.");
    }

    const response = await this.#request("/api/v1/pairings", "POST", request.data);
    if (response.status !== 201) {
      throw this.#responseError(response);
    }
    const parsed = PairingCreateResponseSchema.safeParse(response.json);
    if (!parsed.success) {
      throw invalidResponse(response.status);
    }
    return parsed.data;
  }

  async pollPairing(pairing: PairingCreateResponse): Promise<PairingTokenIssuedResponse> {
    const validatedPairing = PairingCreateResponseSchema.safeParse(pairing);
    if (!validatedPairing.success) {
      throw new RelayClientError("invalid_request", "The pairing session is invalid.");
    }
    const expiresAt = Date.parse(validatedPairing.data.expires_at);
    const request = PairingTokenRequestSchema.parse({
      device_code: validatedPairing.data.device_code,
    });

    await this.#waitWithinPairingDeadline(
      validatedPairing.data.poll_interval_seconds * 1000,
      expiresAt,
    );
    while (this.#now().getTime() < expiresAt) {
      const response = await this.#request("/api/v1/pairings/token", "POST", request);
      if (response.status === 200) {
        const issued = PairingTokenIssuedResponseSchema.safeParse(response.json);
        if (!issued.success) {
          throw invalidResponse(response.status);
        }
        return issued.data;
      }
      if (response.status === 202) {
        const pending = PairingTokenPendingResponseSchema.safeParse(response.json);
        if (!pending.success) {
          throw invalidResponse(response.status);
        }
        await this.#waitWithinPairingDeadline(pending.data.poll_interval_seconds * 1000, expiresAt);
        continue;
      }
      if (response.status === 429) {
        const error = this.#responseError(response);
        if (error.retryAfterMilliseconds === undefined) {
          throw error;
        }
        await this.#waitWithinPairingDeadline(Math.max(1, error.retryAfterMilliseconds), expiresAt);
        continue;
      }
      throw this.#responseError(response);
    }

    throw pairingExpired();
  }

  async uploadSnapshot(deviceToken: string, envelope: QuotaSnapshotEnvelope): Promise<void> {
    if (deviceToken.length === 0 || deviceToken.trim() !== deviceToken) {
      throw new RelayClientError("invalid_request", "The device credential is invalid.");
    }
    const validated = QuotaSnapshotEnvelopeSchema.safeParse(envelope);
    if (!validated.success) {
      throw new RelayClientError("invalid_request", "The snapshot envelope is invalid.");
    }

    const response = await this.#request("/api/v1/snapshots", "POST", validated.data, deviceToken);
    if (response.status !== 204) {
      throw this.#responseError(response);
    }
  }

  async revokeSelf(deviceToken: string): Promise<void> {
    if (deviceToken.length === 0 || deviceToken.trim() !== deviceToken) {
      throw new RelayClientError("invalid_request", "The device credential is invalid.");
    }
    const response = await this.#request("/api/v1/devices/self", "DELETE", undefined, deviceToken);
    if (response.status !== 204) {
      throw this.#responseError(response);
    }
  }

  async #waitWithinPairingDeadline(delayMilliseconds: number, expiresAt: number): Promise<void> {
    const remaining = expiresAt - this.#now().getTime();
    if (remaining <= 0) {
      throw pairingExpired();
    }
    await this.#sleep(Math.min(delayMilliseconds, remaining));
  }

  async #request(
    path: string,
    method: "GET" | "POST" | "DELETE",
    body?: unknown,
    deviceToken?: string,
  ): Promise<RelayResponse> {
    const controller = new AbortController();
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, HTTP_TIMEOUT_MILLISECONDS);

    try {
      const headers = new Headers({ Accept: "application/json" });
      const init: RequestInit = {
        method,
        headers,
        redirect: "error",
        signal: controller.signal,
      };
      if (body !== undefined) {
        headers.set("Content-Type", "application/json");
        init.body = JSON.stringify(body);
      }
      if (deviceToken !== undefined) {
        headers.set("Authorization", `Bearer ${deviceToken}`);
      }

      const response = await this.#fetch(`${this.relayUrl}${path}`, init);
      const bodyText = await readBody(response, HTTP_BODY_LIMIT_BYTES);
      let json: unknown = null;
      if (bodyText.length > 0) {
        try {
          json = JSON.parse(bodyText);
        } catch {
          if (response.ok) {
            throw invalidResponse(response.status);
          }
        }
      }
      return {
        status: response.status,
        headers: response.headers,
        json,
      };
    } catch (error) {
      if (error instanceof RelayClientError) {
        throw error;
      }
      if (timedOut) {
        throw new RelayClientError("timeout", "The Relay request timed out.");
      }
      throw new RelayClientError("unavailable", "The Relay request failed.");
    } finally {
      clearTimeout(timeout);
    }
  }

  #responseError(response: RelayResponse): RelayClientError {
    const relayError = RelayErrorEnvelopeSchema.safeParse(response.json);
    const code = relayError.success
      ? relayError.data.error.code
      : errorCodeForStatus(response.status);
    const retryAfterMilliseconds =
      response.status === 429
        ? parseRetryAfter(response.headers.get("Retry-After"), this.#now())
        : undefined;
    return new RelayClientError(code, errorMessage(code), {
      status: response.status,
      ...(retryAfterMilliseconds === undefined ? {} : { retryAfterMilliseconds }),
    });
  }
}

interface RelayResponse {
  status: number;
  headers: Headers;
  json: unknown;
}

async function readBody(response: Response, limit: number): Promise<string> {
  const contentLength = response.headers.get("Content-Length");
  if (contentLength !== null && /^\d+$/.test(contentLength) && Number(contentLength) > limit) {
    await response.body?.cancel();
    throw invalidResponse(response.status, "The Relay response exceeded the 1 MiB limit.");
  }

  const reader = response.body?.getReader();
  if (!reader) {
    return "";
  }
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    if (!value) {
      continue;
    }
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw invalidResponse(response.status, "The Relay response exceeded the 1 MiB limit.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function parseRetryAfter(value: string | null, now: Date): number | undefined {
  if (value === null) {
    return undefined;
  }
  if (/^\d+$/.test(value)) {
    const seconds = Number(value);
    return Number.isSafeInteger(seconds) ? seconds * 1000 : undefined;
  }
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - now.getTime()) : undefined;
}

function errorCodeForStatus(status: number): RelayErrorCode {
  switch (status) {
    case 400:
      return "invalid_request";
    case 401:
      return "unauthorized";
    case 403:
      return "forbidden";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 410:
      return "pairing_expired";
    case 429:
      return "rate_limited";
    default:
      return "internal_error";
  }
}

function errorMessage(code: RelayErrorCode): string {
  switch (code) {
    case "pairing_denied":
      return "The pairing request was denied.";
    case "pairing_expired":
      return "The pairing request expired.";
    case "pairing_consumed":
      return "The pairing request was already consumed.";
    case "rate_limited":
      return "The Relay rate limit was reached.";
    case "not_found":
      return "The Relay resource was not found.";
    case "unauthorized":
    case "forbidden":
    case "invalid_request":
    case "conflict":
    case "internal_error":
      return "The Relay rejected the request.";
  }
}

function invalidResponse(
  status?: number,
  message = "The Relay returned an invalid response.",
): RelayClientError {
  return new RelayClientError("invalid_response", message, {
    ...(status === undefined ? {} : { status }),
  });
}

function pairingExpired(): RelayClientError {
  return new RelayClientError("pairing_expired", "The pairing request expired.");
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
