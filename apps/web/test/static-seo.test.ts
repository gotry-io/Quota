import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const webRoot = dirname(fileURLToPath(new URL(".", import.meta.url)));
const staticDir = join(webRoot, "static");
const wranglerPath = join(webRoot, "../relay/wrangler.jsonc");
const hooks = readFileSync(join(webRoot, "src/hooks.server.ts"), "utf8");
const landing = readFileSync(join(webRoot, "src/routes/+page.svelte"), "utf8");
const dashboard = readFileSync(join(webRoot, "src/routes/my/+page.svelte"), "utf8");

function parseJsonc(source: string): unknown {
  return JSON.parse(source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, ""));
}

test("every static file and directory has a Wrangler asset-first negation", () => {
  const wrangler = parseJsonc(readFileSync(wranglerPath, "utf8")) as {
    assets: { run_worker_first: string[] };
  };
  const rules = new Set(wrangler.assets.run_worker_first);
  const entries = readdirSync(staticDir).filter((name) => !name.startsWith("."));
  assert.ok(entries.length > 0, "static/ has no entries");
  for (const name of entries) {
    if (statSync(join(staticDir, name)).isDirectory()) {
      assert.ok(rules.has(`!/${name}/*`), `missing run_worker_first negation for ${name}/*`);
    } else {
      assert.ok(rules.has(`!/${name}`), `missing run_worker_first negation for ${name}`);
    }
  }
});

test("document responses stay private, no-store", () => {
  assert.match(hooks, /private, no-store/);
});

test("the public page publishes a canonical URL and /my is noindex", () => {
  assert.match(landing, /canonical/);
  assert.match(dashboard, /noindex/);
});
