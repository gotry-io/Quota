import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/ci-changed-paths.sh");
const iosPaths = "^(apps/ios(/|$)|packages/apple-client(/|$))";

const plist = (version) =>
  `<plist>\n<dict>\n\t<key>CFBundleShortVersionString</key>\n\t<string>${version}</string>\n\t<key>LSMinimumSystemVersion</key>\n\t<string>14.0</string>\n</dict>\n</plist>\n`;
const projectYml = (version) =>
  `settings:\n  base:\n    MARKETING_VERSION: ${version}\n    CURRENT_PROJECT_VERSION: 1\n`;
const pbxproj = (version) =>
  `\t\t\t\tMARKETING_VERSION = ${version};\n\t\t\t\tPRODUCT_NAME = Quota;\n\t\t\t\tMARKETING_VERSION = ${version};\n`;

/** A repository with one base commit; `change` edits it, and the script is asked about the result. */
function ask(mode, pattern, change, event = "pull_request") {
  const dir = mkdtempSync(join(tmpdir(), "ci-changed-paths-"));
  const git = (...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  const write = (path, contents) => {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), contents);
  };
  try {
    git("init", "-q");
    git("config", "user.email", "test@example.com");
    git("config", "user.name", "test");
    write("apps/menubar/Support/Info.plist", plist("0.2.4"));
    write("apps/ios/project.yml", projectYml("0.0.4"));
    write("apps/ios/Quota.xcodeproj/project.pbxproj", pbxproj("0.0.4"));
    write("apps/ios/Sources/App.swift", "let a = 1\n");
    write("README.md", "# readme\n");
    git("add", "-A");
    git("commit", "-q", "-m", "base");
    const base = git("rev-parse", "HEAD").trim();
    change(write);
    git("add", "-A");
    git("commit", "-q", "-m", "change");
    const output = join(dir, "github-output");
    writeFileSync(output, "");
    const env = { ...process.env, EVENT_NAME: event, GITHUB_OUTPUT: output };
    if (event === "pull_request") env.BASE_SHA = base;
    if (event === "merge_group") env.MERGE_GROUP_BASE_SHA = base;
    if (event === "push") env.BEFORE_SHA = base;
    const result = spawnSync(script, [mode, pattern], { cwd: dir, encoding: "utf8", env });
    assert.equal(result.status, 0, result.stderr);
    return readFileSync(output, "utf8").trim();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a QuotaBar version bump runs nothing", () => {
  const answer = ask("all", "^docs/", (write) =>
    write("apps/menubar/Support/Info.plist", plist("0.2.5")),
  );
  assert.equal(answer, "run=false");
});

test("a Quota iOS version bump runs nothing, though its files are under apps/ios", () => {
  const answer = ask("any", iosPaths, (write) => {
    write("apps/ios/project.yml", projectYml("0.0.5"));
    write("apps/ios/Quota.xcodeproj/project.pbxproj", pbxproj("0.0.5"));
  });
  assert.equal(answer, "run=false");
});

test("a version bump that carries any other line is verified", () => {
  const answer = ask("any", iosPaths, (write) => {
    write("apps/ios/project.yml", `${projectYml("0.0.5")}    SWIFT_VERSION: 6\n`);
  });
  assert.equal(answer, "run=true");
});

test("a version bump beside a source change is verified", () => {
  const answer = ask("any", iosPaths, (write) => {
    write("apps/ios/project.yml", projectYml("0.0.5"));
    write("apps/ios/Sources/App.swift", "let a = 2\n");
  });
  assert.equal(answer, "run=true");
});

test("another three-part number in Info.plist is not the product's version", () => {
  const answer = ask("all", "^docs/", (write) =>
    write("apps/menubar/Support/Info.plist", plist("0.2.4").replace("14.0", "14.0.1")),
  );
  assert.equal(answer, "run=true");
});

test("the path rule still answers when no version moved", () => {
  assert.equal(
    ask("any", iosPaths, (write) => write("README.md", "# changed\n")),
    "run=false",
  );
  assert.equal(
    ask("any", iosPaths, (write) => write("apps/ios/Sources/App.swift", "let a = 3\n")),
    "run=true",
  );
});

test("a merge group and a push diff against their own base", () => {
  const bump = (write) => write("apps/menubar/Support/Info.plist", plist("0.2.5"));
  assert.equal(ask("all", "^docs/", bump, "merge_group"), "run=false");
  assert.equal(ask("all", "^docs/", bump, "push"), "run=false");
  const source = (write) => write("apps/ios/Sources/App.swift", "let a = 4\n");
  assert.equal(ask("any", iosPaths, source, "merge_group"), "run=true");
});
