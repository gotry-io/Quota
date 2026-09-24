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
