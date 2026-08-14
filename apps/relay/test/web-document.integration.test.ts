import {
  applyD1Migrations,
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import type { WebDocumentPort } from "../../web/src/lib/server/document-port.ts";
import worker from "../src/cloudflare.ts";
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
  it("renders the signed-out landing header and keeps the response uncacheable", async () => {
    const response = await fetchDocument("/");
    const html = await response.text();
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(html).toContain("Know what you have left");
    expect(html).toContain("Continue with GitHub");
    expect(html).toContain('id="header-login"');
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

  it("returns a document 404 for unknown public slugs without leaking Usage totals", async () => {
    const response = await fetchDocument("/u/nobody-here");
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

  it("renders signed-in /my without Usage totals", async () => {
    const response = await renderDocument("/my", fakePort({ displayLabel: "octocat" }));
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("octocat");
    expect(html).toContain('id="dashboard-title"');
    expect(html).not.toMatch(/input_tokens|output_tokens|amount_microusd/);
  });

  it("keeps signed-in load data private and limited to the display label", async () => {
    const response = await renderDocument("/my/__data.json", fakePort({ displayLabel: "octocat" }));
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("ETag")).toBeNull();
    const payload = await response.text();
    expect(payload).toContain("octocat");
    expect(payload).not.toContain("accountId");
    expect(payload).not.toContain("account_id");
  });

  it("serves an existing public profile document", async () => {
    const response = await renderDocument(
      "/u/octocat",
      fakePort({ displayLabel: null, profile: "exists" }),
    );
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("Public profile");
  });

  it("returns Retry-After on a rate-limited public profile document", async () => {
    const response = await renderDocument(
      "/u/octocat",
      fakePort({ displayLabel: null, profile: "rate_limited" }),
    );
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("12");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});

function fakePort(input: {
  displayLabel: string | null;
  profile?: "exists" | "missing" | "rate_limited";
}): WebDocumentPort {
  return {
    async getViewer() {
      return input.displayLabel === null ? null : { displayLabel: input.displayLabel };
    },
    async lookupPublicProfile() {
      if (input.profile === "rate_limited") {
        return { status: "rate_limited", retryAfterSeconds: 12 };
      }
      return { status: input.profile === "exists" ? "exists" : "missing" };
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
