import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const webRoot = dirname(fileURLToPath(new URL(".", import.meta.url)));
const staticRoot = join(webRoot, "static");
const wranglerPath = join(webRoot, "../relay/wrangler.jsonc");

test("wrangler run_worker_first negates every top-level static file and screenshots/", () => {
  const source = readFileSync(wranglerPath, "utf8").replace(/^\s*\/\/.*$/gm, "");
  const wrangler = JSON.parse(source) as {
    assets: { run_worker_first: string[] };
  };
  const rules = new Set(wrangler.assets.run_worker_first);
  const entries = readdirSync(staticRoot, { withFileTypes: true }).filter(
    (entry) => entry.name !== "schema",
  );
  for (const entry of entries) {
    if (entry.isDirectory()) {
      assert.equal(
        rules.has(`!/${entry.name}/*`),
        true,
        `missing !/${entry.name}/* for static directory ${entry.name}`,
      );
      continue;
    }
    assert.equal(
      rules.has(`!/${entry.name}`),
      true,
      `missing !/${entry.name} for static file ${entry.name}`,
    );
  }
});

test("hooks.server.ts still stamps private, no-store", () => {
  const hooks = readFileSync(join(webRoot, "src/hooks.server.ts"), "utf8");
  assert.match(hooks, /private, no-store/);
});
