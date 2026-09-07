import { describe, expect, it } from "vitest";
import { safeReturnPath } from "../src/account/web-session.ts";

const origin = "https://quota.gotry.io";

/**
 * `return_to` is echoed into a link a signed-in browser follows, so every way a path can name
 * another origin has to come back null: the sign-in page must never send a person elsewhere.
 */
describe("safeReturnPath", () => {
  it("keeps a same-origin path with its query", () => {
    expect(safeReturnPath("/my/settings?tab=pro#sync-title", origin)).toBe("/my/settings?tab=pro");
    expect(safeReturnPath("/", origin)).toBe("/");
  });

  it.each([
    ["absolute URL", "https://attacker.invalid/"],
    ["protocol-relative", "//attacker.invalid/"],
    ["backslash host", "/\\attacker.invalid/"],
    ["backslash after slash", "/\\/attacker.invalid/"],
    ["dot-dot to protocol-relative", "/..//attacker.invalid/"],
    ["encoded slashes", "/%2F%2Fattacker.invalid/"],
    ["scheme in path", "/javascript:alert(1)"],
    ["whitespace", "/my /settings"],
    ["tab", "/my\tsettings"],
    ["newline", "/my\nsettings"],
    ["at-sign host", "/@attacker.invalid/"],
    ["empty", ""],
    ["no leading slash", "my/settings"],
  ])("never lets %s leave the origin", (_name, value) => {
    const result = safeReturnPath(value, origin);
    if (result === null) return;
    expect(result.startsWith("/")).toBe(true);
    expect(result.startsWith("//")).toBe(false);
    expect(new URL(result, origin).origin).toBe(origin);
  });

  it.each([
    "https://attacker.invalid/",
    "//attacker.invalid/",
    "/\\attacker.invalid/",
    "/my /settings",
    "",
    "my/settings",
  ])("refuses %s outright", (value) => {
    expect(safeReturnPath(value, origin)).toBeNull();
  });

  it("refuses a path longer than the limit", () => {
    expect(safeReturnPath(`/${"a".repeat(5000)}`, origin)).toBeNull();
  });
});
