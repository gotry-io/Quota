import type { AccountState } from "@gotry-io/relay-core";
import type { SecretHasher } from "../security.ts";

export type NamedRateLimitOutcome =
  | { allowed: true }
  | { allowed: false; retryAfterSeconds: number };

export async function consumeNamedRateLimit(
  state: Pick<AccountState, "consumeRateLimit">,
  hasher: SecretHasher,
  action: string,
  subject: string,
  policy: { limit: number; windowSeconds: number },
  checkedAt: Date,
): Promise<NamedRateLimitOutcome> {
  const windowMilliseconds = policy.windowSeconds * 1000;
  const windowStartedAt = new Date(
    Math.floor(checkedAt.getTime() / windowMilliseconds) * windowMilliseconds,
  );
  const result = await state.consumeRateLimit({
    key_hash: await hasher.hash("rate-limit", `${action}:${subject}`),
    window_started_at: windowStartedAt.toISOString(),
    window_expires_at: new Date(windowStartedAt.getTime() + windowMilliseconds).toISOString(),
    checked_at: checkedAt.toISOString(),
    limit: policy.limit,
  });
  return result.allowed
    ? { allowed: true }
    : { allowed: false, retryAfterSeconds: result.retry_after };
}
