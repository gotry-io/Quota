import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { createWebDocumentPort } from "../src/account/web-document-port.ts";
import { memoizeWebSessionAuthorization } from "../src/account/web-session.ts";
import { isRelayApiPath } from "../src/relay-paths.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import {
  documentSsrFailureResponse,
  memoizeWebDocumentPort,
  runDocumentSsr,
  withPrivateNoStore,
} from "../src/web-document-ssr.ts";
import { SignedInWebSessionStub, signedOutWebSessions } from "./web-session-stub.ts";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

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

  it("stamps the document headers and keeps a rendered page's own policy", () => {
    const plain = withPrivateNoStore(new Response("ok"));
    expect(plain.headers.get("Content-Security-Policy")).toBe(
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
        "img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; " +
        "base-uri 'none'; object-src 'none'; form-action 'self'",
    );
    expect(plain.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(plain.headers.get("Referrer-Policy")).toBe("same-origin");
    expect(plain.headers.get("X-Frame-Options")).toBe("DENY");

    // A rendered page carries the nonce that lets its own inline scripts run; overwriting it
    // with the static policy would leave a page whose scripts the browser refuses.
    const rendered = withPrivateNoStore(
      new Response("<html></html>", {
        headers: { "Content-Security-Policy": "script-src 'self' 'nonce-abc'" },
      }),
    );
    expect(rendered.headers.get("Content-Security-Policy")).toBe("script-src 'self' 'nonce-abc'");
  });
});

describe("web document port", () => {
  it("returns a viewer only when the session and domain account both exist", async () => {
    const state = new D1AccountState(env.DB);
    await env.DB.prepare(
      "INSERT INTO accounts (id, display_label, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
    )
      .bind("account_1", "octocat", now.toISOString())
      .run();
    expect(
      await createWebDocumentPort({ state, webSessions: signedOutWebSessions }).getViewer(
        new Headers(),
      ),
    ).toBeNull();

    const port = createWebDocumentPort({
      state,
      webSessions: new SignedInWebSessionStub("account_1", now),
      now: () => now,
    });
    expect(await port.getViewer(new Headers({ Cookie: "__Host-quota_session=secret" }))).toEqual({
      displayLabel: "octocat",
    });

    const orphaned = createWebDocumentPort({
      state,
      webSessions: new SignedInWebSessionStub("account_gone", now),
      now: () => now,
    });
    expect(
      await orphaned.getViewer(new Headers({ Cookie: "__Host-quota_session=secret" })),
    ).toBeNull();
  });
});

describe("web document session", () => {
  it("reuses one session read across document and streamed data", async () => {
    let calls = 0;
    const sessions = memoizeWebSessionAuthorization({
      ...signedOutWebSessions,
      async authorize() {
        calls += 1;
        return null;
      },
    });

    const first = sessions.authorize(new Headers({ Cookie: "__Host-quota_session=one" }), now);
    const second = sessions.authorize(new Headers({ Cookie: "__Host-quota_session=one" }), now);
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
    });
    expect(await memoized.hasViewer()).toBe(false);
    expect(await memoized.port.getViewer(new Headers())).toEqual({ displayLabel: "octocat" });
    expect(
      await memoized.port.getViewer(new Headers({ Cookie: "__Host-quota_session=secret" })),
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
