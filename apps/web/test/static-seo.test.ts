import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const webRoot = dirname(fileURLToPath(new URL(".", import.meta.url)));
const staticDir = join(webRoot, "static");
const nodeEntry = readFileSync(join(webRoot, "../relay/src/node.ts"), "utf8");
const hooks = readFileSync(join(webRoot, "src/hooks.server.ts"), "utf8");
const landing = readFileSync(join(webRoot, "src/routes/+page.svelte"), "utf8");
const dashboard = readFileSync(join(webRoot, "src/routes/my/+page.svelte"), "utf8");

test("Node serves a built static file ahead of a document", () => {
  const entries = readdirSync(staticDir).filter((name) => !name.startsWith("."));
  assert.ok(entries.length > 0, "static/ has no entries");
  assert.match(nodeEntry, /NodeStaticFiles/);
  assert.match(nodeEntry, /if \(asset\.ok\) return asset/);
  assert.match(nodeEntry, /isRelayApiPath/);
});

test("document responses stay private, no-store", () => {
  assert.match(hooks, /private, no-store/);
});

test("the public page publishes a canonical URL and /my is noindex", () => {
  assert.match(landing, /canonical/);
  assert.match(dashboard, /noindex/);
});
