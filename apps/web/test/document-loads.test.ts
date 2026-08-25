import assert from "node:assert/strict";
import test from "node:test";
import { isRedirect } from "@sveltejs/kit";
import type { WebDocumentPort } from "../src/lib/server/document-port.ts";
import { load as loadMy } from "../src/routes/my/+page.server.ts";

function myEvent(viewer: { displayLabel: string } | null, port?: WebDocumentPort) {
  return {
    locals: { viewer },
    request: new Request("https://quota.gotry.io/my"),
    ...(port ? { platform: { document: port } } : {}),
  } as Parameters<typeof loadMy>[0];
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
  assert.deepEqual(loadMy(myEvent({ displayLabel: "octocat" })), {
    streamed: { summary: null },
  });

  const streamed = await loadMy(
    myEvent(
      { displayLabel: "octocat" },
      {
        async getViewer() {
          return { displayLabel: "octocat" };
        },
        async getAccountSummary() {
          return { status: "error" };
        },
      },
    ),
  );
  assert.deepEqual(await streamed?.streamed.summary, { status: "error" });
});
