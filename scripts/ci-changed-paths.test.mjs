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

/**
 * The selections CI actually uses, read out of the workflow rather than copied here: a rule that
 * stops matching a dependency is a CI defect, and the table below is what it costs.
 */
function workflowPatterns() {
  const yaml = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
  const found = [...yaml.matchAll(/ci-changed-paths\.sh (all|any)\n\s+'([^']+)'/g)];
  assert.equal(found.length, 2, "ci.yml should ask for exactly two selections");
  const [swift, ios] = found;
  return { swift: { mode: swift[1], pattern: swift[2] }, ios: { mode: ios[1], pattern: ios[2] } };
}

test("the workflow's own selections answer for each kind of change", () => {
  const { swift, ios } = workflowPatterns();
  const cases = [
    { name: "docs only", path: "docs/architecture.md", swift: false, ios: false },
    { name: "an iOS view", path: "apps/ios/Sources/UsageView.swift", swift: true, ios: true },
    {
      name: "the Mac app",
      path: "apps/menubar/Sources/QuotaBar/App.swift",
      swift: true,
      ios: false,
    },
    {
      name: "a shared Apple package",
      path: "packages/apple-shared/Sources/X.swift",
      swift: true,
      ios: true,
    },
    {
      name: "a protocol fixture",
      path: "packages/protocol/fixtures/x.json",
      swift: true,
      ios: true,
    },
    { name: "design tokens", path: "packages/design-tokens/tokens.json", swift: true, ios: true },
    {
      name: "a token generator",
      path: "scripts/generate-design-tokens.mjs",
      swift: true,
      ios: true,
    },
    { name: "the Rust service", path: "packages/service/src/lib.rs", swift: true, ios: false },
    { name: "the website", path: "apps/web/src/app.css", swift: false, ios: false },
    { name: "Relay", path: "apps/relay/src/app.ts", swift: false, ios: false },
    { name: "this workflow", path: ".github/workflows/ci.yml", swift: true, ios: true },
  ];
  for (const one of cases) {
    const change = (write) => write(one.path, "changed\n");
    assert.equal(
      ask(swift.mode, swift.pattern, change),
      `run=${one.swift}`,
      `${one.name} → Rust/Swift`,
    );
    assert.equal(ask(ios.mode, ios.pattern, change), `run=${one.ios}`, `${one.name} → iOS`);
  }
});

/** The advisory census keeps its own copy of the iOS selection; it must select the same paths. */
function censusPattern() {
  const yaml = readFileSync(join(root, ".github/workflows/ios-screens.yml"), "utf8");
  const found = [...yaml.matchAll(/ci-changed-paths\.sh (all|any) \\\n\s+'([^']+)'/g)];
  assert.equal(found.length, 1, "ios-screens.yml should ask for exactly one selection");
  return { mode: found[0][1], pattern: found[0][2] };
}

test("the census selection agrees with the required iOS selection", () => {
  const { ios } = workflowPatterns();
  const census = censusPattern();
  // Each workflow names its own file, so those two entries are expected to differ; every other
  // input must answer the same in both, or a rendering change would be captured by neither.
  for (const path of [
    "apps/ios/Sources/UsageView.swift",
    "packages/apple-shared/Sources/X.swift",
    "packages/design-tokens/tokens.json",
    "scripts/generate-design-tokens.mjs",
    "scripts/ios-ui-screenshots.sh",
    "scripts/ci-changed-paths.sh",
    "apps/menubar/Sources/QuotaBar/App.swift",
    "apps/web/src/app.css",
    "docs/architecture.md",
  ]) {
    const change = (write) => write(path, "changed\n");
    assert.equal(
      ask(census.mode, census.pattern, change),
      ask(ios.mode, ios.pattern, change),
      `${path} answers the same in both workflows`,
    );
  }
});

test("an unknown base runs everything", () => {
  const { swift, ios } = workflowPatterns();
  const change = (write) => write("docs/architecture.md", "changed\n");
  assert.equal(ask(swift.mode, swift.pattern, change, "workflow_dispatch"), "run=true");
  assert.equal(ask(ios.mode, ios.pattern, change, "workflow_dispatch"), "run=true");
});

/** Like `ask`, but keeps the script's exit status: some answers are supposed to be errors. */
function askRaw(mode, pattern) {
  const dir = mkdtempSync(join(tmpdir(), "ci-changed-paths-"));
  const git = (...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  try {
    git("init", "-q");
    git("config", "user.email", "test@example.com");
    git("config", "user.name", "test");
    writeFileSync(join(dir, "a.txt"), "one\n");
    git("add", "-A");
    git("commit", "-q", "-m", "base");
    const base = git("rev-parse", "HEAD").trim();
    writeFileSync(join(dir, "a.txt"), "two\n");
    git("add", "-A");
    git("commit", "-q", "-m", "change");
    const output = join(dir, "github-output");
    writeFileSync(output, "");
    return spawnSync(script, [mode, pattern], {
      cwd: dir,
      encoding: "utf8",
      env: { ...process.env, EVENT_NAME: "pull_request", BASE_SHA: base, GITHUB_OUTPUT: output },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a pattern grep cannot judge stops the selection rather than skipping the work", () => {
  // grep exits 2 on a broken pattern. Read as "no match", that would answer run=false and turn
  // three required checks green without running any of them.
  for (const mode of ["any", "all"]) {
    const result = askRaw(mode, "a[b");
    assert.equal(result.status, 2, `${mode}: an unjudgeable selection is an error`);
    assert.match(result.stderr, /could not judge the selection/);
  }
});
