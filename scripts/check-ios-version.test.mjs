import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/check-ios-version.sh");

function run(args, env = {}) {
  return spawnSync(script, args, {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function withProjectYml(contents, fn) {
  const dir = mkdtempSync(join(tmpdir(), "check-ios-version-"));
  try {
    const yml = join(dir, "project.yml");
    writeFileSync(yml, contents);
    return fn(yml);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("matches MARKETING_VERSION from a temporary project.yml", () => {
  withProjectYml("settings:\n  base:\n    MARKETING_VERSION: 1.2.3\n", (yml) => {
    const ok = run(["1.2.3"], { QUOTA_IOS_PROJECT_YML: yml });
    assert.equal(ok.status, 0, ok.stderr);
    const tagged = run(["ios-v1.2.3"], { QUOTA_IOS_PROJECT_YML: yml });
    assert.equal(tagged.status, 0, tagged.stderr);
  });
});

test("rejects a tag that does not match the temporary project.yml", () => {
  withProjectYml("settings:\n  base:\n    MARKETING_VERSION: 1.2.3\n", (yml) => {
    const bad = run(["9.9.9"], { QUOTA_IOS_PROJECT_YML: yml });
    assert.notEqual(bad.status, 0);
    assert.match(bad.stderr, /does not match Quota iOS MARKETING_VERSION \(1\.2\.3\)/);
  });
});

test("reads a quoted MARKETING_VERSION and ignores comments", () => {
  withProjectYml(
    '# MARKETING_VERSION: 9.9.9\nsettings:\n  base:\n    MARKETING_VERSION: "2.0.0" # pin\n',
    (yml) => {
      const ok = run(["2.0.0"], { QUOTA_IOS_PROJECT_YML: yml });
      assert.equal(ok.status, 0, ok.stderr);
    },
  );
});

test("rejects a missing or invalid tag", () => {
  const missing = run([]);
  assert.equal(missing.status, 2);
  const invalid = run(["not-a-version"]);
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /invalid version/);
});
