import type { AccountState } from "@gotry-io/relay-core";
import { CANONICAL_ORIGIN } from "../config.ts";
import {
  constantTimeEqual,
  decodeBase64UrlJSON,
  encodeBase64UrlJSON,
  randomOpaqueSecret,
  type SecretHasher,
} from "../security.ts";
import { type EmailSender, isEmailSendFailure } from "./email-sender.ts";
import { type IdentityProof, readSignInIntent, type SignInIntent } from "./identity.ts";

/** How long a mailed link can be opened. */
export const EMAIL_CHALLENGE_SECONDS = 15 * 60;
const maximumEmailLength = 254;
const maximumTokenLength = 512;
/**
 * A normalized address: local-part characters RFC 5321 allows, one `@`, and a domain with at
 * least one dot. This is the simple check, not a parser of every mailbox RFC 5322 can name.
 */
const emailPattern =
  /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;

export interface EmailStartBody {
  email: string;
  return_to?: string;
  intent?: "sign_in" | "link";
}

export type EmailVerifyFailure = { outcome: "expired" } | { outcome: "invalid" };

export interface EmailVerifySuccess {
  outcome: "proved";
  proof: IdentityProof;
  intent: SignInIntent;
  return_to: string;
}

export interface EmailMagicLinkEnvironment {
  state: Pick<AccountState, "createEmailChallenge" | "consumeEmailChallenge">;
  hasher: SecretHasher;
  sender: EmailSender;
  origin?: string;
}

/**
 * Email as a channel an Account can be reached through.
 *
 * This is not the OAuth `IdentityProvider` port: there is no authorize URL and no handoff
 * cookie. The mailed token is the credential, so the browser that opens it — which may not be
 * the one that asked — is the one that finishes the sign-in
 * ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 *
 * The address is not stored as itself. The token carries a signed copy so verify can name
 * `subject_raw` as the normalized address, and D1 keeps only the hashes it needs to spend the
 * token once and to log a failed send without the mailbox.
 */
export class EmailMagicLink {
  readonly #origin: string;

  constructor(private readonly environment: EmailMagicLinkEnvironment) {
    this.#origin = environment.origin ?? CANONICAL_ORIGIN;
  }

  async issue(
    email: string,
    intent: SignInIntent,
    returnTo: string,
    now: Date,
  ): Promise<{ email_hash: string }> {
    const token = await sealEmailToken(this.environment.hasher, email);
    const emailHash = await hashEmailAddress(this.environment.hasher, email);
    await this.environment.state.createEmailChallenge({
      id: `email_${crypto.randomUUID()}`,
      email_hash: emailHash,
      token_hash: await this.environment.hasher.hash("email-challenge", token),
      intent_json: JSON.stringify(intent),
      return_to: returnTo,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + EMAIL_CHALLENGE_SECONDS * 1000).toISOString(),
    });
    const link = `${this.#origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`;
    const sent = await this.environment.sender.send(signInMail(email, link));
    if (isEmailSendFailure(sent)) {
      console.error("email_send_failed", { email_hash: emailHash.slice(0, 8) });
    }
    return { email_hash: emailHash };
  }

  async consume(token: string, now: Date): Promise<EmailVerifySuccess | EmailVerifyFailure> {
    const email = await openEmailToken(this.environment.hasher, token);
    if (!email) return { outcome: "invalid" };
    const result = await this.environment.state.consumeEmailChallenge(
      await this.environment.hasher.hash("email-challenge", token),
      now.toISOString(),
    );
    if (result.outcome === "expired") return { outcome: "expired" };
    if (result.outcome === "invalid") return { outcome: "invalid" };
    const emailHash = await hashEmailAddress(this.environment.hasher, email);
    if (!constantTimeEqual(emailHash, result.challenge.email_hash)) {
      return { outcome: "invalid" };
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(result.challenge.intent_json);
    } catch {
      return { outcome: "invalid" };
    }
    const intent = readSignInIntent(parsed);
    if (!intent) return { outcome: "invalid" };
    return {
      outcome: "proved",
      proof: { subject_raw: email, label: email },
      intent,
      return_to: result.challenge.return_to,
    };
  }
}

/**
 * Trim, lowercase, and the simple RFC 5322 mailbox check. Null when the value is not an address
 * Quota will send to.
 */
export function normalizeEmailAddress(value: string): string | null {
  const email = value.trim().toLowerCase();
  if (!email || email.length > maximumEmailLength || !emailPattern.test(email)) return null;
  return email;
}

export function readEmailStartBody(value: unknown): EmailStartBody | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  const keys = Object.keys(candidate);
  if (keys.some((key) => key !== "email" && key !== "return_to" && key !== "intent")) {
    return null;
  }
  if (typeof candidate.email !== "string") return null;
  if (candidate.return_to !== undefined && typeof candidate.return_to !== "string") return null;
  if (
    candidate.intent !== undefined &&
    candidate.intent !== "sign_in" &&
    candidate.intent !== "link"
  ) {
    return null;
  }
  return {
    email: candidate.email,
    ...(candidate.return_to === undefined ? {} : { return_to: candidate.return_to }),
    ...(candidate.intent === undefined ? {} : { intent: candidate.intent }),
  };
}

export function hashEmailAddress(hasher: SecretHasher, email: string): Promise<string> {
  return hasher.hash("email-address", email);
}

async function sealEmailToken(hasher: SecretHasher, email: string): Promise<string> {
  const encoded = encodeBase64UrlJSON({ email, nonce: randomOpaqueSecret() });
  return `${encoded}.${await hasher.hash("email-token", encoded)}`;
}

async function openEmailToken(hasher: SecretHasher, token: string): Promise<string | null> {
  if (!token || token.length > maximumTokenLength) return null;
  const separator = token.lastIndexOf(".");
  if (separator < 1) return null;
  const encoded = token.slice(0, separator);
  const expected = await hasher.hash("email-token", encoded);
  if (!constantTimeEqual(token.slice(separator + 1), expected)) return null;
  let payload: unknown;
  try {
    payload = decodeBase64UrlJSON(encoded);
  } catch {
    return null;
  }
  if (payload === null || typeof payload !== "object") return null;
  const candidate = payload as Record<string, unknown>;
  return typeof candidate.email === "string" ? normalizeEmailAddress(candidate.email) : null;
}

function signInMail(
  email: string,
  link: string,
): {
  to: string;
  subject: string;
  text: string;
  html: string;
} {
  return {
    to: email,
    subject: "Sign in to Quota",
    text: [
      "Sign in to Quota with this link:",
      "",
      link,
      "",
      "This link expires in 15 minutes. If you didn't ask for it, you can ignore this email.",
    ].join("\n"),
    html: `<!doctype html>
<html lang="en">
  <body>
    <p>Sign in to Quota with this link:</p>
    <p><a href="${link}">Sign in to Quota</a></p>
    <p>This link expires in 15 minutes. If you didn't ask for it, you can ignore this email.</p>
  </body>
</html>
`,
  };
}
