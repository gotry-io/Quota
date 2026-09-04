/**
 * The stable, irreversible id every Quota client uses to name a subscription in a URL.
 *
 * The preimage is `provider|fingerprint|fingerprint_scope|source_id`, with an empty source id
 * when the subscription is global. The selector is the first 12 lowercase hex characters of
 * SHA-256 of that UTF-8 string. Fingerprints stay out of paths and logs.
 *
 * Same definition as `packages/apple-shared` `SubscriptionSelector.make`.
 */

export type SubscriptionSelectorInput = {
  provider: string;
  fingerprint: string;
  fingerprint_scope: string;
  source_id?: string | null;
};

export function subscriptionSelectorPreimage(input: SubscriptionSelectorInput): string {
  return `${input.provider}|${input.fingerprint}|${input.fingerprint_scope}|${input.source_id ?? ""}`;
}

export async function subscriptionSelector(input: SubscriptionSelectorInput): Promise<string> {
  return hashSelectorPreimage(subscriptionSelectorPreimage(input));
}

/** A summary `key` is already the preimage; hash it the same way. */
export async function hashSelectorPreimage(preimage: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(preimage));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 12);
}
