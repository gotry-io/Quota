import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/generate-reference.mjs");
const generated = join(root, "docs/reference.md");
const catalog = JSON.parse(readFileSync(join(root, "packages/provider/catalog.json"), "utf8"));
const protocolSource = readFileSync(join(root, "packages/protocol/src/index.ts"), "utf8");

function run(args = []) {
  return spawnSync(process.execPath, ["--experimental-strip-types", script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

function exportedNumberConst(name) {
  const match = protocolSource.match(new RegExp(`^export const ${name} = (\\d+) as const;`, "m"));
  assert.ok(match, `missing ${name}`);
  return match[1];
}

test("rejects extra arguments", () => {
  const result = run(["--check", "--oops"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr + result.stdout, /Usage: generate-reference\.mjs \[--check\]/);
});

test("--check passes on the generated reference", () => {
  const result = run(["--check"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /is current/);
});

test("--check detects drift", () => {
  const original = readFileSync(generated, "utf8");
  try {
    writeFileSync(generated, `${original}<!-- drifted -->\n`);
    const result = run(["--check"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /out of date/);
  } finally {
    writeFileSync(generated, original);
  }
});

test("generate is deterministic", () => {
  const first = run();
  assert.equal(first.status, 0, first.stderr + first.stdout);
  const snapshot = readFileSync(generated, "utf8");
  const second = run();
  assert.equal(second.status, 0, second.stderr + second.stdout);
  assert.equal(readFileSync(generated, "utf8"), snapshot);
  const check = run(["--check"]);
  assert.equal(check.status, 0, check.stderr + check.stdout);
});

test("inventory includes every catalog provider and protocol versions", () => {
  const result = run();
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const text = readFileSync(generated, "utf8");
  for (const entry of catalog.providers) {
    assert.match(text, new RegExp(`\\[\`${entry.id}\`\\]\\(providers/${entry.id}\\.md\\)`));
  }
  assert.match(
    text,
    new RegExp(`\`PROTOCOL_VERSION\` \\| ${exportedNumberConst("PROTOCOL_VERSION")}`),
  );
  assert.match(
    text,
    new RegExp(
      `\`MANAGED_DATA_PROTOCOL_VERSION\` \\| ${exportedNumberConst("MANAGED_DATA_PROTOCOL_VERSION")}`,
    ),
  );
  assert.match(text, /does not describe production deployment status/);
  assert.doesNotMatch(text, /dmit/);
});
