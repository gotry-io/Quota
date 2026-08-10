import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  BrowserAuthorizationError,
  runBrowserAuthorization,
} from "../src/account/browser-login.ts";

describe("browser account login", () => {
  it("uses a loopback callback, exact state, and PKCE S256", async () => {
    let authorizeUrl: URL | undefined;
    const result = await runBrowserAuthorization({
      origin: "https://quota.gotry.io",
      open: async (value) => {
        authorizeUrl = new URL(value);
        const callback = new URL(authorizeUrl.searchParams.get("redirect_uri") ?? "invalid:");
        callback.searchParams.set("state", "wrong-local-state");
        callback.searchParams.set("code", "ignored-code");
        expect((await fetch(callback)).status).toBe(400);

        callback.search = "";
        callback.searchParams.set("state", authorizeUrl.searchParams.get("state") ?? "");
        callback.searchParams.set("code", "single-use-synthetic-code");
        const response = await fetch(callback);
        expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
        const body = await response.text();
        expect(body).toContain("window.close()");
        expect(body).toContain("close it manually");
      },
    });

    expect(authorizeUrl?.origin).toBe("https://quota.gotry.io");
    expect(authorizeUrl?.pathname).toBe("/oauth/v2/authorize");
    expect(authorizeUrl?.searchParams.get("code_challenge_method")).toBe("S256");
    expect(authorizeUrl?.searchParams.get("code_challenge")).toBe(
      createHash("sha256").update(result.code_verifier).digest("base64url"),
    );
    expect(result.redirect_uri).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/callback$/);
    expect(result.code).toBe("single-use-synthetic-code");
  });

  it("ignores a state mismatch without exposing the authorization code", async () => {
    const error = await captureError(
      runBrowserAuthorization({
        origin: "https://quota.gotry.io",
        open: async (value) => {
          const authorize = new URL(value);
          const callback = new URL(authorize.searchParams.get("redirect_uri") ?? "invalid:");
          callback.searchParams.set("state", "wrong-state");
          callback.searchParams.set("code", "secret-authorization-code");
          expect((await fetch(callback)).status).toBe(400);
        },
        timeoutMilliseconds: 5,
      }),
    );

    expect(error).toMatchObject({ code: "expired" });
    expect(error.message).not.toContain("secret-authorization-code");
  });

  it("ignores callback query additions", async () => {
    const error = await captureError(
      runBrowserAuthorization({
        origin: "https://quota.gotry.io",
        open: async (value) => {
          const authorize = new URL(value);
          const callback = new URL(authorize.searchParams.get("redirect_uri") ?? "invalid:");
          callback.searchParams.set("state", authorize.searchParams.get("state") ?? "");
          callback.searchParams.set("code", "secret-authorization-code");
          callback.searchParams.set("next", "unexpected");
          expect((await fetch(callback)).status).toBe(400);
        },
        timeoutMilliseconds: 5,
      }),
    );

    expect(error).toMatchObject({ code: "expired" });
  });

  it("expires and supports cancellation", async () => {
    await expect(
      runBrowserAuthorization({
        origin: "https://quota.gotry.io",
        open: async () => undefined,
        timeoutMilliseconds: 5,
      }),
    ).rejects.toMatchObject({ code: "expired" });

    const controller = new AbortController();
    controller.abort();
    await expect(
      runBrowserAuthorization({
        origin: "https://quota.gotry.io",
        open: async () => undefined,
        signal: controller.signal,
      }),
    ).rejects.toMatchObject({ code: "cancelled" });
  });
});

async function captureError(promise: Promise<unknown>): Promise<BrowserAuthorizationError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(BrowserAuthorizationError);
    return error as BrowserAuthorizationError;
  }
  throw new Error("Expected browser authorization to fail.");
}
