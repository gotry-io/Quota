import { describe, expect, it } from "vitest";
import { sanitizeMessage } from "../src/runtime/errors.ts";
import { accountFingerprint, maskDisplayName, maskEmail } from "../src/runtime/identity.ts";

describe("identity helpers", () => {
  it("keeps fingerprints stable for the same provider identity", () => {
    const first = accountFingerprint("codex", "acct_stable_01");
    const second = accountFingerprint("codex", "acct_stable_01");
    expect(first).toBe(second);
    expect(first).toHaveLength(64);
  });

  it("does not prefer empty identifiers", () => {
    const withEmpty = accountFingerprint("claude", "   ", "fallback-seed");
    const withFallback = accountFingerprint("claude", undefined, "fallback-seed");
    expect(withEmpty).toBe(withFallback);
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
