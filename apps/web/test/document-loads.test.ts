import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
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

test("the /my document load does not start account/summary; the client asks once with tz", () => {
  const root = dirname(fileURLToPath(import.meta.url));
  const server = readFileSync(join(root, "../src/routes/my/+layout.server.ts"), "utf8");
  const store = readFileSync(join(root, "../src/lib/account-store.svelte.ts"), "utf8");
  const layout = readFileSync(join(root, "../src/routes/my/+layout.svelte"), "utf8");
  const client = readFileSync(join(root, "../src/lib/account-client.ts"), "utf8");
  const reads = readFileSync(join(root, "../src/lib/account-reads.ts"), "utf8");

  assert.doesNotMatch(server, /account\/summary/);
  assert.doesNotMatch(server, /from\s+["']@gotry-io\/quota-relay["']/);
  assert.doesNotMatch(server, /from\s+["'][^"']*apps\/relay/);
  assert.doesNotMatch(server, /platform\.env/);
  assert.doesNotMatch(server, /D1Database/);
  assert.doesNotMatch(server, /createRelayApp/);
  assert.doesNotMatch(server, /GitHubWebSessions/);
  assert.doesNotMatch(server, /usage-summary/);
  const specifiers = [...server.matchAll(/from\s+["']([^"']+)["']/g)].map((match) => match[1]);
  for (const specifier of specifiers) {
    assert.ok(
      specifier === "@sveltejs/kit" || specifier === "./$types",
      `unexpected import ${specifier}`,
    );
  }

  assert.match(server, /LayoutServerLoad = \(\{ locals \}\)/);
  assert.match(store, /fetchAccountSummary\(\)/);
  assert.match(store, /from "\.\/account-client\.ts"/);
  assert.match(store, /Promise\.all/);
  assert.match(layout, /ensureSummary\(\)/);
  assert.match(layout, /ensureActivity\(/);
  assert.match(client, /accountSummaryPath\(browserTimezone\(\)\)/);
  assert.match(reads, /\/api\/v6\/account\/summary\?\$\{new URLSearchParams\(\{ tz: timezone \}\)/);
});
