import { OWNER_AUTH_SCOPES, type RelayState } from "@gotry-io/relay-core";
import { sha256Hex } from "./security.ts";

export const SELF_HOSTED_OWNER_ID = "self-hosted-owner";
export const SELF_HOSTED_OWNER_SESSION_ID = "self-hosted-owner-bootstrap";
export const SELF_HOSTED_OWNER_SESSION_EXPIRES_AT = "9999-12-31T23:59:59.999Z";

export function requireSelfHostedOwnerToken(value: string | undefined): string {
  if (!value || [...value].length < 32 || value.trim() !== value) {
    throw new Error(
      "QUOTA_RELAY_OWNER_TOKEN must be set to at least 32 characters without surrounding whitespace.",
    );
  }
  return value;
}

export async function bootstrapSelfHostedOwner(
  state: RelayState,
  ownerToken: string,
  startedAt: Date,
): Promise<void> {
  const tokenHash = await sha256Hex(ownerToken);
  const createdAt = startedAt.toISOString();
  await state.ensureOwner(SELF_HOSTED_OWNER_ID, createdAt);
  await state.replaceAuthSession({
    id: SELF_HOSTED_OWNER_SESSION_ID,
    owner_id: SELF_HOSTED_OWNER_ID,
    token_hash: tokenHash,
    scopes: [...OWNER_AUTH_SCOPES],
    expires_at: SELF_HOSTED_OWNER_SESSION_EXPIRES_AT,
    created_at: createdAt,
  });
}
