import assert from "node:assert/strict";
import test from "node:test";
import { isHttpError, isRedirect } from "@sveltejs/kit";
import type { WebDocumentPort } from "../src/lib/server/document-port.ts";
import { load as loadMy } from "../src/routes/my/+page.server.ts";
import { load as loadPublic } from "../src/routes/u/[username]/+page.server.ts";

function myEvent(viewer: { displayLabel: string } | null) {
  return { locals: { viewer } } as Parameters<typeof loadMy>[0];
}

function publicEvent(username: string, port: WebDocumentPort) {
  return {
    params: { username },
    platform: { document: port },
    locals: {} as { retryAfterSeconds?: number },
  } as Parameters<typeof loadPublic>[0];
}

test("unsigned /my redirects home and signed-in /my loads a shell", async () => {
  try {
    loadMy(myEvent(null));
    assert.fail("expected redirect");
  } catch (error) {
    assert.equal(isRedirect(error), true);
    if (isRedirect(error)) {
      assert.equal(error.status, 302);
      assert.equal(error.location, "/");
    }
  }
  assert.deepEqual(loadMy(myEvent({ displayLabel: "octocat" })), {});
});

test("public profile load maps port results without inventing Usage", async () => {
  const lookups: string[] = [];
  const exists = await loadPublic(
    publicEvent("octocat", {
      async getViewer() {
        return null;
      },
      async lookupPublicProfile(username) {
        lookups.push(username);
        return { status: "exists" };
      },
    }),
  );
  assert.deepEqual(exists, { username: "octocat" });
  assert.deepEqual(lookups, ["octocat"]);

  try {
    await loadPublic(
      publicEvent("missing-user", {
        async getViewer() {
          return null;
        },
        async lookupPublicProfile() {
          return { status: "missing" };
        },
      }),
    );
    assert.fail("expected 404");
  } catch (error) {
    assert.equal(isHttpError(error), true);
    if (isHttpError(error)) assert.equal(error.status, 404);
  }
});

test("public profile 429 records Retry-After on locals before failing", async () => {
  const event = publicEvent("octocat", {
    async getViewer() {
      return null;
    },
    async lookupPublicProfile() {
      return { status: "rate_limited", retryAfterSeconds: 17 };
    },
  });
  try {
    await loadPublic(event);
    assert.fail("expected 429");
  } catch (error) {
    assert.equal(isHttpError(error), true);
    if (isHttpError(error)) assert.equal(error.status, 429);
    assert.equal(event.locals.retryAfterSeconds, 17);
  }
});
