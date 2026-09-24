import { describe, expect, it } from "vitest";
import { acceptsHtml, htmlOrJsonSignInError } from "../src/account/browser-error-page.ts";

describe("browser sign-in error page", () => {
  it("answers HTML only when Accept names text/html with a nonzero q, in any case", () => {
    expect(acceptsHtml("text/html,application/xhtml+xml")).toBe(true);
    expect(acceptsHtml("application/json")).toBe(false);
    expect(acceptsHtml("*/*")).toBe(false);
    expect(acceptsHtml(undefined)).toBe(false);
    expect(acceptsHtml("text/html;q=0")).toBe(false);
    expect(acceptsHtml("text/html;q=0.0,application/json")).toBe(false);
    expect(acceptsHtml("text/html;q=0.1")).toBe(true);
    expect(acceptsHtml("TEXT/HTML,application/json")).toBe(true);
    expect(acceptsHtml("Text/Html;Q=0")).toBe(false);
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
