import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it } from "vitest";
import type { WebDocumentPort } from "../../web/src/lib/server/document-port.ts";
import worker, { type CloudflareBindings } from "../src/cloudflare.ts";
import { respondAsRelay, type RelaySecrets } from "../src/deployment.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { MemoryReadingCache } from "../src/platform/reading-cache.ts";
import { NodeStaticFiles, WorkersStaticFiles } from "../src/platform/static-files.ts";
import { respondWithWebDocument } from "../src/web-document.ts";
import { testDatabase } from "./support/database.ts";

const sqliteDriver = import.meta.env.RELAY_TEST_DRIVER === "sqlite";
const testSecret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const clientDirectory = fileURLToPath(
  new URL("../../web/.svelte-kit/output/client", import.meta.url),
);
const secrets: RelaySecrets = {
  GITHUB_CLIENT_ID: "test-github-client-id",
  GITHUB_CLIENT_SECRET: testSecret,
  APPLE_SIGNIN_TEAM_ID: "",
  APPLE_SIGNIN_SERVICES_ID: "",
  APPLE_SIGNIN_KEY_ID: "",
  APPLE_SIGNIN_PRIVATE_KEY: "",
  IDENTITY_SUBJECT_KEY: testSecret,
  QUOTA_INSTALLATION_KEY: testSecret,
  QUOTA_SESSION_HASH_KEY: testSecret,
  RESEND_API_KEY: testSecret,
};

let db: RelayDatabase;

beforeEach(async () => {
  db = await testDatabase();
});

async function fetchDocument(path: string): Promise<Response> {
  const request = new Request(`https://quota.gotry.io${path}`);
  if (sqliteDriver) {
    return respondAsRelay(
      request,
      {
        database: db,
        assets: new NodeStaticFiles(clientDirectory),
        statusCache: new MemoryReadingCache(),
        secrets,
      },
      undefined,
    );
  }
  const { createExecutionContext, env, waitOnExecutionContext } = await import("cloudflare:test");
  const context = createExecutionContext();
  const response = await worker.fetch(request, env, context);
  await waitOnExecutionContext(context);
  return response;
}

describe("composed Worker documents", () => {
  it("supplies Worker secrets without a local .env file", async () => {
    if (sqliteDriver) {
      // Node reads the same names from the process; the Miniflare bindings are a Workers fact.
      expect(secrets.QUOTA_SESSION_HASH_KEY.length).toBeGreaterThanOrEqual(32);
      expect(secrets.IDENTITY_SUBJECT_KEY.length).toBeGreaterThanOrEqual(32);
      return;
    }
    const { env } = await import("cloudflare:test");
    const bindings = env as CloudflareBindings;
    expect(bindings.QUOTA_SESSION_HASH_KEY.length).toBeGreaterThanOrEqual(32);
    expect(bindings.IDENTITY_SUBJECT_KEY.length).toBeGreaterThanOrEqual(32);
  });

  it("renders the signed-out landing header and keeps the response uncacheable", async () => {
    const response = await fetchDocument("/");
    const html = await response.text();
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(html).toContain("See what's left across your coding-agent plans");
    expect(html).toContain(">Sign in<");
    expect(html).toContain('id="header-login"');
    expect(html).toContain('href="/sign-in"');
  });

  it("locks every document down and still lets the inline theme script run", async () => {
    for (const path of ["/", "/my"]) {
      const response = await renderDocument(
        path,
        fakePort({ displayLabel: path === "/my" ? "octocat" : null }),
      );
      expect(response.status).toBe(200);
      expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
      expect(response.headers.get("Referrer-Policy")).toBe("same-origin");
      expect(response.headers.get("X-Frame-Options")).toBe("DENY");
      const policy = response.headers.get("Content-Security-Policy") ?? "";
      for (const directive of [
        "default-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
        "object-src 'none'",
        "form-action 'self'",
      ]) {
        expect(policy).toContain(directive);
      }
      // Nothing is hashed ahead of time: the page states one nonce and every inline script it
      // carries — SvelteKit's bootstrap and the theme script from `app.html` — claims it.
      const nonce = /script-src 'self' 'nonce-([^']+)'/.exec(policy)?.[1];
      expect(nonce).toBeTruthy();
      const html = await response.text();
      const inline = [...html.matchAll(/<script(?![^>]*\ssrc=)([^>]*)>/g)].map(
        (match) => match[1] ?? "",
      );
      expect(inline.length).toBeGreaterThanOrEqual(2);
      for (const attributes of inline) expect(attributes).toContain(`nonce="${nonce}"`);
      expect(html).toContain('localStorage.getItem("quota-theme")');
    }
  });

  it("stamps a policy on a document response SvelteKit does not render", async () => {
    const response = await renderDocument("/my/__data.json", fakePort({ displayLabel: "octocat" }));
    expect(response.headers.get("Content-Security-Policy")).toContain("script-src 'self';");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("X-Frame-Options")).toBe("DENY");
  });

  it("redirects unsigned /my and shipped /app bookmarks", async () => {
    const my = await fetchDocument("/my");
    expect(my.status).toBe(302);
    expect(my.headers.get("Location")).toBe("/");
    const app = await fetchDocument("/app");
    expect(app.status).toBe(302);
    expect(app.headers.get("Location")).toBe("/my");
    const nested = await fetchDocument("/app/anything");
    expect(nested.status).toBe(302);
    expect(nested.headers.get("Location")).toBe("/my");
  });

  it("returns a document 404 for an unknown path without leaking Usage totals", async () => {
    const response = await fetchDocument("/nobody-here");
    const html = await response.text();
    expect(response.status).toBe(404);
    expect(html).toMatch(/unavailable|does not exist/i);
    expect(html).not.toContain("input_tokens");
  });

  it("keeps Hono API routes on the same Worker", async () => {
    const response = await fetchDocument("/api/v2/info");
    expect(response.status).toBe(200);
    const body = (await response.json()) as { service: string };
    expect(body.service).toBe("QuotaRelay");
  });

  it("paints the signed-in GitHub username in the header", async () => {
    const response = await renderDocument("/", fakePort({ displayLabel: "octocat" }));
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('id="header-account-name"');
    expect(body).toContain("octocat");
    expect(body).not.toMatch(/id="header-login"(?![^>]*hidden)/);
  });

  it("escapes a malicious display label as text", async () => {
    const response = await renderDocument(
      "/",
      fakePort({ displayLabel: '<img src=x onerror="alert(1)">' }),
    );
    const body = await response.text();
    expect(body).toContain("&lt;img");
    expect(body).not.toContain("<img src=x");
  });

  it("renders /my as a signed-in shell that carries no Account data", async () => {
    const response = await renderDocument("/my", fakePort({ displayLabel: "octocat" }));
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("octocat");
    expect(html).toContain('id="dashboard-title"');
    // The read that fills this page is bounded by the caller's calendar, which a document
    // request cannot know. Rendering one here would answer in UTC and be thrown away.
    expect(html).not.toMatch(/input_tokens|output_tokens|amount_microusd/);
  });

  it("keeps the signed-in document payload private and uncacheable", async () => {
    const response = await renderDocument("/my/__data.json", fakePort({ displayLabel: "octocat" }));
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("ETag")).toBeNull();
    const payload = await response.text();
    expect(payload).toContain("octocat");
    expect(payload).not.toMatch(/session_token|credential|access_token/);
  });
});

function fakePort(input: { displayLabel: string | null }): WebDocumentPort {
  return {
    async getViewer() {
      return input.displayLabel === null ? null : { displayLabel: input.displayLabel };
    },
  };
}

async function renderDocument(path: string, document: WebDocumentPort): Promise<Response> {
  const request = new Request(`https://quota.gotry.io${path}`);
  if (sqliteDriver) {
    return respondWithWebDocument(request, new NodeStaticFiles(clientDirectory), undefined, {
      document,
    });
  }
  const { createExecutionContext, env, waitOnExecutionContext } = await import("cloudflare:test");
  const context = createExecutionContext();
  const response = await respondWithWebDocument(
    request,
    new WorkersStaticFiles(env.ASSETS),
    context,
    { document },
  );
  await waitOnExecutionContext(context);
  return response;
}
