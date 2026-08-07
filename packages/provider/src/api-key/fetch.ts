import { ProviderCollectionError } from "../contracts.ts";
import { HttpRequestError, type HttpTransport, readJsonObject } from "../runtime/http.ts";

export interface FetchBearerJsonOptions {
  transport: HttpTransport;
  url: string;
  apiKey: string;
  source: string;
  providerLabel: string;
  clientVersion: string;
  signal?: AbortSignal;
  /** When false, non-2xx / transport errors return undefined instead of throwing. */
  required?: boolean;
  extraHeaders?: Record<string, string>;
}

/**
 * GET JSON with Bearer auth. Maps 401/403 → auth_required, 429 → unavailable.
 */
export async function fetchBearerJson(
  options: FetchBearerJsonOptions,
): Promise<unknown | undefined> {
  const required = options.required !== false;
  try {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${options.apiKey}`,
      Accept: "application/json",
      "User-Agent": options.clientVersion,
      ...options.extraHeaders,
    };
    const request: Parameters<typeof readJsonObject>[1] = {
      url: options.url,
      method: "GET",
      headers,
    };
    if (options.signal) {
      request.signal = options.signal;
    }
    const { status, json } = await readJsonObject(options.transport, request);
    if (status === 401 || status === 403) {
      throw new ProviderCollectionError(
        "auth_required",
        `${options.providerLabel} rejected the API key.`,
        options.source,
      );
    }
    if (status === 429) {
      throw new ProviderCollectionError(
        "unavailable",
        `${options.providerLabel} rate limited the request.`,
        options.source,
      );
    }
    if (status < 200 || status >= 300) {
      if (!required) {
        return undefined;
      }
      throw new ProviderCollectionError(
        "unavailable",
        `${options.providerLabel} request failed (HTTP ${status}).`,
        options.source,
      );
    }
    return json;
  } catch (error) {
    if (error instanceof ProviderCollectionError) {
      throw error;
    }
    if (error instanceof HttpRequestError) {
      if (error.status === 401 || error.status === 403) {
        throw new ProviderCollectionError(
          "auth_required",
          `${options.providerLabel} rejected the API key.`,
          options.source,
        );
      }
      if (!required) {
        return undefined;
      }
      throw new ProviderCollectionError(
        "unavailable",
        `${options.providerLabel} is unreachable.`,
        options.source,
      );
    }
    if (!required) {
      return undefined;
    }
    throw error;
  }
}
