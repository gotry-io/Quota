import assert from "node:assert/strict";
import test from "node:test";
import { isRedirect } from "@sveltejs/kit";
import { load as loadMy } from "../src/routes/my/+layout.server.ts";

function myEvent(viewer: { displayLabel: string } | null) {
  return { locals: { viewer } } as Parameters<typeof loadMy>[0];
}

test("unsigned /my redirects home and signed-in /my loads a shell", () => {
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

  // The document carries no Account data: the read it would have to make is bounded by a
  // calendar the request cannot know, so the client makes it once with its own.
  assert.equal(loadMy(myEvent({ displayLabel: "octocat" })), undefined);
});
