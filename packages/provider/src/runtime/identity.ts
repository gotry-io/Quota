import { createHash } from "node:crypto";
import type { ProviderId } from "@gotry-io/quota-protocol";

export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

/**
 * Stable non-secret account fingerprint. Prefer durable identifiers
 * (account id, user id, email). Never hash an access token as the preferred
 * identity because refresh would change account identity.
 */
export function accountFingerprint(
  provider: ProviderId,
  stableId: string | undefined,
  fallbackSeed?: string,
): string {
  const primary = normalizeIdentity(stableId);
  if (primary) {
    return sha256Hex(`${provider}:id:${primary}`);
  }
  const fallback = normalizeIdentity(fallbackSeed);
  if (fallback) {
    return sha256Hex(`${provider}:seed:${fallback}`);
  }
  return sha256Hex(`${provider}:anonymous`);
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
