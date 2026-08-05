import { createHash } from "node:crypto";
import type { FingerprintScope, ProviderId } from "@gotry-io/quota-protocol";

export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export interface AccountIdentity {
  fingerprint: string;
  scope: FingerprintScope;
}

export type QuotaOwnerNamespace =
  | "account_id"
  | "organization_id"
  | "team_id"
  | "user_id"
  /** Stable hash of an API key (OpenRouter). Never the raw key material. */
  | "api_key";

/**
 * Builds a redacted identity together with the scope in which it is safe to deduplicate.
 * Only an explicit quota-owner identifier can produce a global fingerprint. Missing identity
 * deliberately falls back to a source-scoped value that consumers must combine with source ID.
 */
export function accountIdentity(
  provider: ProviderId,
  namespace: QuotaOwnerNamespace,
  quotaOwnerId: string | undefined,
): AccountIdentity {
  const globalValue = normalizeIdentity(quotaOwnerId);
  if (globalValue) {
    return {
      fingerprint: sha256Hex(`${provider}:global:${namespace}:${globalValue}`),
      scope: "global",
    };
  }

  return {
    fingerprint: sha256Hex(`${provider}:source`),
    scope: "source",
  };
}

export function maskEmail(email: string | undefined): string | undefined {
  const normalized = normalizeIdentity(email);
  if (!normalized || !normalized.includes("@")) {
    return undefined;
  }
  const at = normalized.indexOf("@");
  const local = normalized.slice(0, at);
  const domain = normalized.slice(at + 1);
  if (!local || !domain) {
    return undefined;
  }
  const visible = local.slice(0, Math.min(2, local.length));
  return `${visible}***@${domain}`;
}

export function maskDisplayName(name: string | undefined): string | undefined {
  const normalized = normalizeIdentity(name);
  if (!normalized) {
    return undefined;
  }
  if (normalized.includes("@")) {
    return maskEmail(normalized);
  }
  if (normalized.length <= 2) {
    return `${normalized[0] ?? "*"}*`;
  }
  return `${normalized.slice(0, 2)}***`;
}

function normalizeIdentity(value: string | undefined): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}
