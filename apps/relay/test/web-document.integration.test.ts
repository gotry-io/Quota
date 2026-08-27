import {
  applyD1Migrations,
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import type { WebDocumentPort } from "../../web/src/lib/server/document-port.ts";
import worker, { type CloudflareBindings } from "../src/cloudflare.ts";
import { respondWithWebDocument } from "../src/web-document.ts";

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
});

async function fetchDocument(path: string): Promise<Response> {
  const context = createExecutionContext();
  const response = await worker.fetch(new Request(`https://quota.gotry.io${path}`), env, context);
  await waitOnExecutionContext(context);
  return response;
}

describe("composed Worker documents", () => {
  it("supplies Worker secrets without a local .env file", () => {
    const bindings = env as CloudflareBindings;
    expect(bindings.QUOTA_SESSION_HASH_KEY.length).toBeGreaterThanOrEqual(32);
    expect(bindings.GITHUB_SUBJECT_KEY.length).toBeGreaterThanOrEqual(32);
  });

  it("renders the signed-out landing header and keeps the response uncacheable", async () => {
    const response = await fetchDocument("/");
    const html = await response.text();
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(html).toContain("Know what you have left");
    expect(html).toContain("Continue with GitHub");
    expect(html).toContain('id="header-login"');
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
    const response = await renderDocument(
      "/my/__data.json",
      fakePort({ displayLabel: "octocat", summary: true }),
    );
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

  it("streams the signed-in Account summary into /my", async () => {
    const response = await renderDocument(
      "/my",
      fakePort({ displayLabel: "octocat", summary: true }),
    );
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("octocat");
    expect(html).toContain('id="dashboard-title"');
    expect(html).toMatch(/input_tokens|output_tokens|amount_microusd/);
  });

  it("keeps the streamed signed-in summary private and uncacheable", async () => {
    const response = await renderDocument(
      "/my/__data.json",
      fakePort({ displayLabel: "octocat", summary: true }),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("ETag")).toBeNull();
    const payload = await response.text();
    expect(payload).toContain("octocat");
    expect(payload).not.toContain("accountId");
    expect(payload).toContain("account_id");
    expect(payload).not.toMatch(/session_token|credential|access_token/);
  });
});

function fakePort(input: { displayLabel: string | null; summary?: boolean }): WebDocumentPort {
  return {
    async getViewer() {
      return input.displayLabel === null ? null : { displayLabel: input.displayLabel };
    },
    ...(input.summary
      ? {
          async getAccountSummary() {
            return { status: "ok" as const, summary: accountSummary() };
          },
        }
      : {}),
  };
}

function accountSummary() {
  const totals = {
    input_tokens: 10,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 4,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: null,
    source_cost_covered_requests: 0,
  };
  return {
    protocol_version: 3 as const,
    generated_at: "2026-08-14T00:00:00Z",
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-08-01T00:00:00Z",
    },
    devices: [],
    quota: [],
    usage: {
      range: { from: "2026-08-14", to: "2026-08-14" },
      totals,
      cost: {
        mode: "calculate" as const,
        basis: "none" as const,
        status: "complete" as const,
        amount_microusd: null,
        catalog_revision: null,
        calculated_rows: 0,
        reported_rows: 0,
        unpriced_rows: 0,
        assumptions: [],
        unpriced: [],
      },
      coverage: [],
      breakdowns: [],
    },
  };
}

async function renderDocument(path: string, document: WebDocumentPort): Promise<Response> {
  const context = createExecutionContext();
  const response = await respondWithWebDocument(
    new Request(`https://quota.gotry.io${path}`),
    env,
    context,
    { document },
  );
  await waitOnExecutionContext(context);
  return response;
}
