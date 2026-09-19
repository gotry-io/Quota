import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/generate-design-tokens.mjs");
const generatedTs = join(root, "apps/web/src/lib/tokens.generated.ts");

function run(args = []) {
  return spawnSync(process.execPath, ["--experimental-strip-types", script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

test("rejects extra arguments", () => {
  const result = run(["--check", "--oops"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr + result.stdout, /Usage: generate-design-tokens\.mjs \[--check\]/);
});

test("--check passes on the generated outputs", () => {
  const result = run(["--check"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /is current/);
});

test("--check detects drift", () => {
  const original = readFileSync(generatedTs, "utf8");
  try {
    writeFileSync(generatedTs, `${original}// drifted\n`);
    const result = run(["--check"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /out of date/);
  } finally {
    writeFileSync(generatedTs, original);
  }
});

test("generate is deterministic", () => {
  const first = run();
  assert.equal(first.status, 0, first.stderr + first.stdout);
  const snapshot = readFileSync(generatedTs, "utf8");
  const second = run();
  assert.equal(second.status, 0, second.stderr + second.stdout);
  assert.equal(readFileSync(generatedTs, "utf8"), snapshot);
  const check = run(["--check"]);
  assert.equal(check.status, 0, check.stderr + check.stdout);
});
