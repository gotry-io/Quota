import { ProviderCollectionError } from "../contracts.ts";
import { httpStatusCategory, sanitizeMessage } from "./errors.ts";
import { HTTP_BODY_LIMIT_BYTES, HTTP_TIMEOUT_MS } from "./limits.ts";

export interface HttpRequest {
  url: string;
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface HttpResponse {
  status: number;
  headers: Headers;
  bodyText: string;
}

export type HttpTransport = (request: HttpRequest) => Promise<HttpResponse>;

export class HttpRequestError extends ProviderCollectionError {
  readonly status?: number;

  constructor(message: string, status?: number, category = httpStatusCategory(status ?? 0)) {
    super(category, message);
    this.name = "HttpRequestError";
    if (status !== undefined) {
      this.status = status;
    }
  }
}

export function createFetchTransport(fetchImpl: typeof fetch = fetch): HttpTransport {
  return async (request) => {
    const timeoutMs = request.timeoutMs ?? HTTP_TIMEOUT_MS;
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    if (request.signal) {
      if (request.signal.aborted) {
        controller.abort();
      } else {
        request.signal.addEventListener("abort", onAbort, { once: true });
      }
    }
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const init: RequestInit = {
        method: request.method ?? "GET",
        signal: controller.signal,
        // Provider bearer tokens must never follow a redirect to another origin.
        // The supported endpoints are fixed and are expected to answer directly.
        redirect: "error",
      };
      if (request.headers) {
        init.headers = request.headers;
      }
      if (request.body !== undefined) {
        init.body = request.body;
      }
      const response = await fetchImpl(request.url, init);

      const reader = response.body?.getReader();
      if (!reader) {
        const bodyText = await response.text();
        if (byteLength(bodyText) > HTTP_BODY_LIMIT_BYTES) {
          throw new HttpRequestError("HTTP response exceeded size limit.", response.status);
        }
        return {
          status: response.status,
          headers: response.headers,
          bodyText,
        };
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
        if (total > HTTP_BODY_LIMIT_BYTES) {
          await reader.cancel();
          throw new HttpRequestError("HTTP response exceeded size limit.", response.status);
        }
        chunks.push(value);
      }

      const bodyText = new TextDecoder().decode(concatBytes(chunks));
      return {
        status: response.status,
        headers: response.headers,
        bodyText,
      };
    } catch (error) {
      if (error instanceof HttpRequestError) {
        throw error;
      }
      if (error instanceof Error && error.name === "AbortError") {
        throw new HttpRequestError(
          "HTTP request timed out or was cancelled.",
          undefined,
          "unavailable",
        );
      }
      throw new HttpRequestError(
        sanitizeMessage(error instanceof Error ? error.message : "HTTP request failed."),
        undefined,
        "unavailable",
      );
    } finally {
      clearTimeout(timer);
      request.signal?.removeEventListener("abort", onAbort);
    }
  };
}

export async function readJsonObject(
  transport: HttpTransport,
  request: HttpRequest,
): Promise<{ status: number; json: unknown; bodyText: string }> {
  const response = await transport(request);
  let json: unknown;
  try {
    json = response.bodyText.length > 0 ? JSON.parse(response.bodyText) : null;
  } catch {
    // Preserve the HTTP status so callers can classify an HTML/plain-text
    // 401, 403, or 429 without ever surfacing the response body.
    if (response.status < 200 || response.status >= 300) {
      return { status: response.status, json: null, bodyText: response.bodyText };
    }
    throw new HttpRequestError("HTTP response was not valid JSON.", response.status, "error");
  }
  return { status: response.status, json, bodyText: response.bodyText };
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function concatBytes(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}
