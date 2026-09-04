import { describe, expect, it } from "vitest";
import {
  acceptsHtml,
  browserSignInErrorPage,
  htmlOrJsonSignInError,
  type BrowserSignInFailureReason,
} from "../src/account/browser-error-page.ts";

describe("browser sign-in error page", () => {
  it("accepts an Accept header that names HTML", () => {
    expect(acceptsHtml("text/html,application/xhtml+xml")).toBe(true);
    expect(acceptsHtml("application/json")).toBe(false);
    expect(acceptsHtml("*/*")).toBe(false);
    expect(acceptsHtml(undefined)).toBe(false);
  });

  it.each([
    "no_session",
    "expired",
    "rate_limited",
    "invalid_request",
  ] satisfies BrowserSignInFailureReason[])(
    "renders %s as 200 HTML with the reason code and no token",
    async (reason) => {
      const response = browserSignInErrorPage(reason);
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toMatch(/text\/html/);
      const body = await response.text();
      expect(body).toContain("Sign-in didn't finish");
      expect(body).toContain("Return to Quota and try again.");
      expect(body).toContain(`data-reason="${reason}"`);
      expect(body).toContain(reason);
      expect(body).not.toContain("qia_");
      expect(body).not.toContain("login_token");
    },
  );

  it("keeps JSON when Accept does not name HTML", async () => {
    const json = new Response(JSON.stringify({ error: { code: "unauthorized" } }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
    const response = htmlOrJsonSignInError("application/json", json, "no_session");
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: { code: "unauthorized" } });
  });

  it("copies Retry-After onto the HTML page", () => {
    const json = new Response("{}", {
      status: 429,
      headers: { "Retry-After": "12" },
    });
    const response = htmlOrJsonSignInError("text/html", json, "rate_limited");
    expect(response.status).toBe(200);
    expect(response.headers.get("Retry-After")).toBe("12");
  });
});
