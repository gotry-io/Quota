import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/generate-adr-index.mjs");
const generated = join(root, "docs/decisions/README.md");
const acceptedAdr = join(root, "docs/decisions/0009-versioned-model-catalog.md");
const supersededAdr = join(root, "docs/decisions/0002-relay-device-code-pairing.md");

function run(args = []) {
  return spawnSync(process.execPath, ["--experimental-strip-types", script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

test("rejects extra arguments", () => {
  const result = run(["--check", "--oops"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr + result.stdout, /Usage: generate-adr-index\.mjs \[--check\]/);
});

test("--check passes on the generated index", () => {
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

test("refuses a Status that is not the enum", () => {
  const original = readFileSync(acceptedAdr, "utf8");
  try {
    writeFileSync(acceptedAdr, original.replace("- Status: Accepted", "- Status: accepted"));
    const result = run(["--check"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /Status must be Accepted/);
  } finally {
    writeFileSync(acceptedAdr, original);
  }
});

test("refuses Superseded without Superseded by", () => {
  const original = readFileSync(supersededAdr, "utf8");
  try {
    writeFileSync(supersededAdr, original.replace(/- Superseded by: 0006\n/, ""));
    const result = run(["--check"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /requires Superseded by/);
  } finally {
    writeFileSync(supersededAdr, original);
  }
});
