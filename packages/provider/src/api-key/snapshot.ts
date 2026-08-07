import type { ProviderId, QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import { accountIdentity, sha256Hex } from "../runtime/identity.ts";
import { toIsoOffset } from "../runtime/time.ts";
import type { ApiKeyCredentials } from "./resolve.ts";

export function buildApiKeySnapshot(input: {
  provider: ProviderId;
  source: string;
  credentials: ApiKeyCredentials;
  windows: QuotaWindow[];
  plan?: string;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const keyFingerprint = sha256Hex(input.credentials.apiKey);
  const identity = accountIdentity(input.provider, "api_key", keyFingerprint);
  const account: QuotaSnapshot["account"] = {
    fingerprint: identity.fingerprint,
    fingerprint_scope: identity.scope,
    label: input.credentials.label,
  };
  if (input.plan) {
    account.plan = input.plan;
  }
  return {
    provider: input.provider,
    account,
    windows: input.windows,
    source: input.source,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}
