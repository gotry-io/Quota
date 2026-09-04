#!/usr/bin/env node
/**
 * Bump a product version and commit it.
 *
 *   pnpm version:bump:menubar patch|minor|major|<semver>
 *   pnpm version:bump:ios patch|minor|major|<semver>
 *   … --no-commit
 *
 * Menubar: plutil CFBundleShortVersionString. Publish tag: menubar-vX.Y.Z
 * iOS: project.yml MARKETING_VERSION, then ./scripts/generate-ios.sh.
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$/;
const BUMP_KINDS = new Set(["major", "minor", "patch"]);
const TARGETS = new Set(["menubar", "ios"]);

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const iosProjectYml = join(root, "apps/ios/project.yml");
const args = process.argv.slice(2);
const noCommit = args.includes("--no-commit");
const help = args.includes("-h") || args.includes("--help");
const positional = args.filter((a) => !a.startsWith("-"));
const target = positional[0];
const bumpArg = positional[1];

if (help || !target || !bumpArg) {
  console.log(`Usage: pnpm version:bump:menubar <patch|minor|major|semver> [--no-commit]
       pnpm version:bump:ios <patch|minor|major|semver> [--no-commit]

Examples:
  pnpm version:bump:menubar minor
  pnpm version:bump:menubar 0.1.0 --no-commit
  pnpm version:bump:ios patch
  pnpm version:bump:ios 0.0.2 --no-commit`);
  process.exit(help ? 0 : 2);
}

if (!TARGETS.has(target)) {
  console.error(`unknown target: ${target}`);
  process.exit(1);
}

if (!BUMP_KINDS.has(bumpArg) && !VERSION_RE.test(bumpArg)) {
  console.error(`invalid bump: ${bumpArg} (use patch|minor|major or a semver)`);
  process.exit(1);
}

const product = target === "menubar" ? menubarProduct() : iosProduct();
const before = product.read();
const next = BUMP_KINDS.has(bumpArg) ? nextSemver(before, bumpArg) : bumpArg;
if (next === before) {
  console.log(`Already at ${product.label} ${before}; nothing to do.`);
  process.exit(0);
}

const touched = product.bump(next);
const version = product.read();

if (version === before) {
  console.log(`Already at ${product.label} ${version}; nothing to do.`);
  process.exit(0);
}
console.log(`updated ${product.label}: ${before} → ${version}`);

const message = `chore(${product.scope}): bump version to ${version}`;

if (noCommit) {
  console.log("Skipped commit (--no-commit).");
  if (product.publishHint) {
    console.log(product.publishHint(version));
  }
  process.exit(0);
}

if (runGit(["rev-parse", "--is-inside-work-tree"]).stdout.trim() !== "true") {
  console.error("not a git work tree; files updated, not committed");
  process.exit(1);
}
if (runGit(["add", "--", ...touched]).status !== 0) {
  process.exit(1);
}
if (!runGit(["diff", "--cached", "--name-only", "--", ...touched]).stdout.trim()) {
  console.log("Nothing staged.");
  process.exit(0);
}
const commit = runGit(["commit", "-m", message]);
if (commit.status !== 0) {
  console.error(commit.stderr || commit.stdout || "git commit failed");
  process.exit(commit.status ?? 1);
}
console.log(`committed: ${message}`);
if (product.publishHint) {
  console.log(product.publishHint(version));
}

function menubarProduct() {
  return {
    label: "QuotaBar",
    scope: "menubar",
    read: readMenubarVersion,
    bump: bumpMenubar,
    publishHint: (version) => {
      const tag = `menubar-v${version}`;
      return `Publish: git tag -a ${tag} -m "QuotaBar ${version}" && git push origin ${tag}`;
    },
  };
}

function iosProduct() {
  return {
    label: "Quota iOS",
    scope: "ios",
    read: readIosVersion,
    bump: bumpIos,
    publishHint: null,
  };
}

function readMenubarVersion() {
  const out = run("plutil", [
    "-extract",
    "CFBundleShortVersionString",
    "raw",
    join(root, "apps/menubar/Support/Info.plist"),
  ]);
  if (out.status !== 0) {
    console.error(out.stderr || "plutil extract failed");
    process.exit(1);
  }
  return out.stdout.trim();
}

function bumpMenubar(next) {
  const path = join(root, "apps/menubar/Support/Info.plist");
  const result = run("plutil", ["-replace", "CFBundleShortVersionString", "-string", next, path]);
  if (result.status !== 0) {
    console.error(result.stderr || "plutil replace failed");
    process.exit(result.status ?? 1);
  }
  return ["apps/menubar/Support/Info.plist"];
}

function readIosVersion() {
  const text = readFileSync(iosProjectYml, "utf8");
  const match = text.match(/^\s*MARKETING_VERSION:\s*(\S+)\s*$/m);
  if (!match) {
    console.error("MARKETING_VERSION not found in apps/ios/project.yml");
    process.exit(1);
  }
  return match[1];
}

function bumpIos(next) {
  const text = readFileSync(iosProjectYml, "utf8");
  let count = 0;
  const updated = text.replace(/^\s*MARKETING_VERSION:\s*\S+\s*$/m, (line) => {
    count += 1;
    return line.replace(/MARKETING_VERSION:\s*\S+/, `MARKETING_VERSION: ${next}`);
  });
  if (count !== 1) {
    console.error(`expected 1 MARKETING_VERSION in apps/ios/project.yml, found ${count}`);
    process.exit(1);
  }
  writeFileSync(iosProjectYml, updated);
  const generated = run(join(root, "scripts/generate-ios.sh"), []);
  if (generated.status !== 0) {
    if (generated.stdout) {
      process.stdout.write(generated.stdout);
    }
    console.error(generated.stderr || "generate-ios.sh failed");
    process.exit(generated.status ?? 1);
  }
  if (generated.stdout) {
    process.stdout.write(generated.stdout);
  }
  return ["apps/ios/project.yml", "apps/ios/Quota.xcodeproj"];
}

/** patch|minor|major — patch removes a prerelease suffix before incrementing. */
function nextSemver(current, kind) {
  const m = current.match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/);
  if (!m) {
    console.error(`cannot parse version: ${current}`);
    process.exit(1);
  }
  const major = Number(m[1]);
  const minor = Number(m[2]);
  const patch = Number(m[3]);
  const pre = m[4];
  if (kind === "major") {
    return `${major + 1}.0.0`;
  }
  if (kind === "minor") {
    return `${major}.${minor + 1}.0`;
  }
  if (pre) {
    return `${major}.${minor}.${patch}`;
  }
  return `${major}.${minor}.${patch + 1}`;
}

function run(cmd, cmdArgs) {
  return spawnSync(cmd, cmdArgs, { encoding: "utf8", cwd: root });
}

function runGit(gitArgs) {
  return run("git", gitArgs);
}
