import { ProviderCollectionError, type ProviderErrorCategory } from "../contracts.ts";

const AUTH_HINTS = [
  "authentication required",
  "not authenticated",
  "unauthorized",
  "login required",
  "run `grok login`",
  "run `claude auth login`",
  "run `codex`",
  "re-authenticate",
  "missing 'user:profile'",
  "user:profile",
];

const UNSUPPORTED_HINTS = ["method not found", "-32601", "not supported", "unsupported"];

export function classifyProviderError(
  error: unknown,
  fallback: ProviderErrorCategory = "error",
): ProviderCollectionError {
  if (error instanceof ProviderCollectionError) {
    return new ProviderCollectionError(
      error.category,
      fixedProviderMessage(error.category),
      error.source,
    );
  }

  if (error instanceof Error && error.name === "AbortError") {
    return new ProviderCollectionError("unavailable", fixedProviderMessage("unavailable"));
  }

  const message = error instanceof Error ? error.message : String(error ?? "unknown error");
  const lower = message.toLowerCase();

  if (AUTH_HINTS.some((hint) => lower.includes(hint))) {
    return new ProviderCollectionError("auth_required", fixedProviderMessage("auth_required"));
  }
  if (UNSUPPORTED_HINTS.some((hint) => lower.includes(hint))) {
    return new ProviderCollectionError("unsupported", fixedProviderMessage("unsupported"));
  }
  if (
    lower.includes("timed out") ||
    lower.includes("timeout") ||
    lower.includes("not found") ||
    lower.includes("enoent") ||
    lower.includes("econn") ||
    lower.includes("network")
  ) {
    return new ProviderCollectionError("unavailable", fixedProviderMessage("unavailable"));
  }

  return new ProviderCollectionError(fallback, fixedProviderMessage(fallback));
}

/** Provider-owned diagnostics are classified, never copied into reports or UI. */
export function fixedProviderMessage(category: ProviderErrorCategory): string {
  switch (category) {
    case "auth_required":
      return "Provider authentication is required.";
    case "unavailable":
      return "Provider is temporarily unavailable.";
    case "unsupported":
      return "Provider operation is not supported.";
    case "error":
      return "Provider returned invalid quota data.";
  }
}

export function sanitizeMessage(message: string): string {
  let cleaned = message
    .replace(/Bearer\s+[A-Za-z0-9._\-+=/]+/gi, "Bearer [redacted]")
    .replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted-jwt]")
    .replace(
      /((?:access[_-]?token|refresh[_-]?token|authorization|cookie)["']?\s*[=:]\s*["']?)[^\s"',}]+/gi,
      "$1[redacted]",
    )
    .replace(
      /((?:account[_-]?id|organization[_-]?(?:id|uuid)|user[_-]?id|team[_-]?id)["']?\s*[=:]\s*["']?)[^\s"',}]+/gi,
      "$1[redacted]",
    )
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/\/Users\/[^/\s]+/g, "/Users/[redacted]")
    .replace(/\/home\/[^/\s]+/g, "/home/[redacted]")
    .replace(/\s+/g, " ")
    .trim();

  if (cleaned.length > 240) {
    cleaned = `${cleaned.slice(0, 237)}...`;
  }
  return cleaned.length > 0 ? cleaned : "Provider collection failed.";
}

export function httpStatusCategory(status: number): ProviderErrorCategory {
  if (status === 401 || status === 403) {
    return "auth_required";
  }
  if (status === 404 || status === 501) {
    return "unsupported";
  }
  if (status === 408 || status === 429 || status >= 500) {
    return "unavailable";
  }
  return "error";
}
