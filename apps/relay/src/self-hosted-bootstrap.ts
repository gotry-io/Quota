import { CONTROLLER_AUTH_SCOPES, type RelayState } from "@gotry-io/relay-core";
import { sha256Hex } from "./security.ts";

export const SELF_HOSTED_CONTROLLER_ID = "self-hosted-controller";
export const SELF_HOSTED_CONTROLLER_SESSION_ID = "self-hosted-controller-bootstrap";
export const SELF_HOSTED_CONTROLLER_SESSION_EXPIRES_AT = "9999-12-31T23:59:59.999Z";

export function requireSelfHostedControllerToken(value: string | undefined): string {
  if (!value || [...value].length < 32 || value.trim() !== value) {
    throw new Error(
      "QUOTA_RELAY_CONTROLLER_TOKEN must be set to at least 32 characters without surrounding whitespace.",
    );
  }
  return value;
}

export async function bootstrapSelfHostedController(
  state: RelayState,
  controllerToken: string,
  startedAt: Date,
): Promise<void> {
  const tokenHash = await sha256Hex(controllerToken);
  const createdAt = startedAt.toISOString();
  await state.ensureController(SELF_HOSTED_CONTROLLER_ID, "permanent", createdAt);
  await state.replaceControllerSession({
    id: SELF_HOSTED_CONTROLLER_SESSION_ID,
    controller_id: SELF_HOSTED_CONTROLLER_ID,
    token_hash: tokenHash,
    scopes: [...CONTROLLER_AUTH_SCOPES],
    expires_at: SELF_HOSTED_CONTROLLER_SESSION_EXPIRES_AT,
    created_at: createdAt,
  });
}
