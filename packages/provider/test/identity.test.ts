import { describe, expect, it } from "vitest";
import { sanitizeMessage } from "../src/runtime/errors.ts";
import { accountIdentity, maskDisplayName, maskEmail } from "../src/runtime/identity.ts";

describe("identity helpers", () => {
  it("keeps fingerprints stable for the same provider identity", () => {
    const first = accountIdentity("codex", "account_id", "acct_stable_01");
    const second = accountIdentity("codex", "account_id", "acct_stable_01");
    expect(first).toEqual(second);
    expect(first.fingerprint).toHaveLength(64);
    expect(first.scope).toBe("global");
  });

  it("uses a source-scoped identity when the quota owner is missing", () => {
    const withEmpty = accountIdentity("claude", "organization_id", "   ");
    const withMissing = accountIdentity("claude", "organization_id", undefined);
    expect(withEmpty).toEqual(withMissing);
    expect(withMissing.scope).toBe("source");
  });

  it("namespaces stable identifiers before hashing", () => {
    const account = accountIdentity("grok", "user_id", "owner_01");
    const team = accountIdentity("grok", "team_id", "owner_01");
    expect(account.fingerprint).not.toBe(team.fingerprint);
  });

  it("masks emails without emitting the local part", () => {
    expect(maskEmail("ada@example.com")).toBe("ad***@example.com");
    expect(maskEmail("a@example.com")).toBe("a***@example.com");
    expect(maskEmail(undefined)).toBeUndefined();
  });

  it("masks display names", () => {
    expect(maskDisplayName("Ada Lovelace")).toBe("Ad***");
    expect(maskDisplayName("ab")).toBe("a*");
  });

  it("redacts authorization material and account identifiers in structured errors", () => {
    const sanitized = sanitizeMessage(
      '{"accessToken":"opaque-secret","account_id":"acct-secret","email":"ada@example.com"}',
    );
    expect(sanitized).not.toContain("opaque-secret");
    expect(sanitized).not.toContain("acct-secret");
    expect(sanitized).not.toContain("ada@example.com");
  });
});
