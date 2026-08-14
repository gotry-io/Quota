import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { memoizeWebAccountAuthSession } from "../src/account/better-auth.ts";
import { createWebDocumentPort, hasWebSessionCookie } from "../src/account/web-document-port.ts";
import { isRelayApiPath } from "../src/relay-paths.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import {
  documentSsrFailureResponse,
  memoizeWebDocumentPort,
  runDocumentSsr,
  withPrivateNoStore,
} from "../src/web-document-ssr.ts";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const now = new Date("2026-08-10T00:00:00.000Z");

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

describe("document routing helpers", () => {
  it("sends API and health prefixes to Hono", () => {
    expect(isRelayApiPath("/api")).toBe(true);
    expect(isRelayApiPath("/api/v2/account")).toBe(true);
    expect(isRelayApiPath("/oauth")).toBe(true);
    expect(isRelayApiPath("/oauth/v2/authorize")).toBe(true);
    expect(isRelayApiPath("/healthz")).toBe(true);
    expect(isRelayApiPath("/readyz")).toBe(true);
    expect(isRelayApiPath("/")).toBe(false);
    expect(isRelayApiPath("/my")).toBe(false);
    expect(isRelayApiPath("/u/octocat")).toBe(false);
  });

  it("clones cache headers onto a new response", () => {
    const source = new Response("ok", {
      headers: { ETag: '"abc"', "Content-Type": "text/html" },
    });
    const rewritten = withPrivateNoStore(source);
    expect(rewritten.headers.get("Cache-Control")).toBe("private, no-store");
    expect(rewritten.headers.get("ETag")).toBeNull();
    expect(rewritten).not.toBe(source);
  });
});

describe("web document port", () => {
  it("detects the Better Auth session cookie without reading its value", () => {
    expect(hasWebSessionCookie(null)).toBe(false);
    expect(hasWebSessionCookie("theme=dark")).toBe(false);
    expect(hasWebSessionCookie("quota.session_token=secret")).toBe(true);
    expect(hasWebSessionCookie("__Secure-quota.session_token=secret")).toBe(true);
    expect(hasWebSessionCookie("quota.session_token_backup=secret")).toBe(false);
  });

  it("returns a viewer only when the session and domain account both exist", async () => {
    const state = new D1AccountState(env.DB);
    await env.DB.prepare(
      "INSERT INTO accounts (id, identity_subject, display_label, created_at, updated_at) VALUES (?1, ?1, ?2, ?3, ?3)",
    )
      .bind("account_1", "octocat", now.toISOString())
      .run();
    const port = createWebDocumentPort({
      state,
      hasher: new SecretHasher(secret),
      webAuth: {
        handler: async () => new Response(null, { status: 404 }),
        beginGitHubSignIn: async () => new Response(null, { status: 404 }),
        getSession: async () => ({
          user: { id: "account_1", name: "octocat" },
          session: { id: "session_1", createdAt: now, expiresAt: now },
        }),
      },
      now: () => now,
    });
    expect(await port.getViewer(new Headers())).toBeNull();
    const viewer = await port.getViewer(
      new Headers({ Cookie: "__Secure-quota.session_token=secret" }),
    );
    expect(viewer).toEqual({ displayLabel: "octocat" });
  });

  it("does not consume the public-profile limiter for slugs normalizePublicSlug rejects", async () => {
    const state = new D1AccountState(env.DB);
    const port = createWebDocumentPort({
      state,
      hasher: new SecretHasher(secret),
      webAuth: {
        handler: async () => new Response(null, { status: 404 }),
        beginGitHubSignIn: async () => new Response(null, { status: 404 }),
        getSession: async () => null,
      },
      now: () => now,
    });
    expect(await port.lookupPublicProfile("***")).toEqual({ status: "missing" });
    expect(await port.lookupPublicProfile("---")).toEqual({ status: "missing" });
  });

  it("shares the public-profile bucket across document lookups", async () => {
    const state = new D1AccountState(env.DB);
    const port = createWebDocumentPort({
      state,
      hasher: new SecretHasher(secret),
      webAuth: {
        handler: async () => new Response(null, { status: 404 }),
        beginGitHubSignIn: async () => new Response(null, { status: 404 }),
        getSession: async () => null,
      },
      now: () => now,
    });
    for (let index = 0; index < 120; index += 1) {
      const result = await port.lookupPublicProfile("not a slug");
      expect(result.status).toBe("missing");
    }
    const limited = await port.lookupPublicProfile("not a slug");
    expect(limited.status).toBe("rate_limited");
  });
});

describe("web document session", () => {
  it("reuses one Better Auth session read across document and streamed data", async () => {
    let calls = 0;
    const auth = memoizeWebAccountAuthSession({
      handler: async () => new Response(null, { status: 404 }),
      beginGitHubSignIn: async () => new Response(null, { status: 404 }),
      getSession: async () => {
        calls += 1;
        return {
          user: { id: "account_1", name: "octocat" },
          session: { id: "session_1", createdAt: now, expiresAt: now },
        };
      },
    });

    const first = auth.getSession(new Headers({ Cookie: "quota.session_token=one" }));
    const second = auth.getSession(new Headers({ Cookie: "quota.session_token=one" }));
    expect(await first).toEqual(await second);
    expect(calls).toBe(1);
  });
});

describe("document SSR observability", () => {
  it("memoizes getViewer so the session is read once", async () => {
    let calls = 0;
    const memoized = memoizeWebDocumentPort({
      async getViewer() {
        calls += 1;
        return { displayLabel: "octocat" };
      },
      async lookupPublicProfile() {
        return { status: "missing" };
      },
    });
    expect(await memoized.hasViewer()).toBe(false);
    expect(await memoized.port.getViewer(new Headers())).toEqual({ displayLabel: "octocat" });
    expect(
      await memoized.port.getViewer(new Headers({ Cookie: "quota.session_token=secret" })),
    ).toEqual({
      displayLabel: "octocat",
    });
    expect(calls).toBe(1);
    expect(await memoized.hasViewer()).toBe(true);
  });

  it("treats a rejected getViewer as has_viewer false without a second call", async () => {
    let calls = 0;
    const memoized = memoizeWebDocumentPort({
      async getViewer() {
        calls += 1;
        throw new Error("session store unavailable");
      },
      async lookupPublicProfile() {
        return { status: "missing" };
      },
    });
    await expect(memoized.port.getViewer(new Headers())).rejects.toThrow(
      "session store unavailable",
    );
    expect(await memoized.hasViewer()).toBe(false);
    expect(await memoized.hasViewer()).toBe(false);
    expect(calls).toBe(1);
  });

  it("returns a generic private 500 when getViewer rejects without rethrowing has_viewer", async () => {
    const errors: string[] = [];
    let calls = 0;
    const original = console.error;
    console.error = (value: unknown) => {
      if (typeof value === "string") errors.push(value);
    };
    try {
      const response = await runDocumentSsr(
        new Request("https://quota.gotry.io/my"),
        {
          async getViewer() {
            calls += 1;
            throw new Error("session store unavailable");
          },
          async lookupPublicProfile() {
            return { status: "missing" };
          },
        },
        async (document) => {
          await document.getViewer(new Headers());
          return new Response("unreachable");
        },
      );
      expect(response.status).toBe(500);
      expect(response.headers.get("Cache-Control")).toBe("private, no-store");
      expect(response.headers.get("ETag")).toBeNull();
      const html = await response.text();
      expect(html).toContain("Quota could not load this page.");
      expect(html).not.toContain("session store unavailable");
      expect(calls).toBe(1);
      expect(errors).toHaveLength(1);
      expect(JSON.parse(errors[0] ?? "{}")).toEqual({
        event: "document_ssr_failed",
        path: "/my",
        status: 500,
        has_viewer: false,
      });
    } finally {
      console.error = original;
    }
  });

  it("returns a generic private 500 when document render throws", async () => {
    const errors: string[] = [];
    const original = console.error;
    console.error = (value: unknown) => {
      if (typeof value === "string") errors.push(value);
    };
    try {
      const response = await runDocumentSsr(
        new Request("https://quota.gotry.io/my?cookie=secret"),
        {
          async getViewer() {
            return { displayLabel: "octocat" };
          },
          async lookupPublicProfile() {
            return { status: "missing" };
          },
        },
        async (document) => {
          await document.getViewer(new Headers());
          throw new Error("render exploded");
        },
      );
      expect(response.status).toBe(500);
      expect(response.headers.get("Cache-Control")).toBe("private, no-store");
      expect(response.headers.get("ETag")).toBeNull();
      const html = await response.text();
      expect(html).toContain("Quota could not load this page.");
      expect(html).not.toContain("render exploded");
      expect(html).not.toContain("octocat");
      expect(errors).toHaveLength(1);
      const payload = JSON.parse(errors[0] ?? "{}") as Record<string, unknown>;
      expect(payload).toEqual({
        event: "document_ssr_failed",
        path: "/my",
        status: 500,
        has_viewer: true,
      });
      expect(Object.keys(payload).sort()).toEqual(["event", "has_viewer", "path", "status"]);
    } finally {
      console.error = original;
    }
  });

  it("builds a failure response without an ETag", () => {
    const response = documentSsrFailureResponse();
    expect(response.status).toBe(500);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("ETag")).toBeNull();
  });
});
