#!/usr/bin/env node
/**
 * Bump one product version and commit it.
 *
 *   pnpm version:bump:cli patch|minor|major|<semver>
 *   pnpm version:bump:menubar patch|minor|major|<semver>
 *   … --no-commit
 *
 * CLI: Cargo package version.
 * Menubar: plutil CFBundleShortVersionString.
 * Publish tags: cli-vX.Y.Z | menubar-vX.Y.Z
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$/;
const BUMP_KINDS = new Set(["major", "minor", "patch"]);

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const noCommit = args.includes("--no-commit");
const help = args.includes("-h") || args.includes("--help");
const positional = args.filter((a) => !a.startsWith("-"));
const target = positional[0];
const bumpArg = positional[1];

if (help || !target || !bumpArg) {
  console.log(`Usage: pnpm version:bump:<cli|menubar> <patch|minor|major|semver> [--no-commit]

Examples:
  pnpm version:bump:cli patch
  pnpm version:bump:menubar minor
  pnpm version:bump:menubar 0.1.0 --no-commit`);
  process.exit(help ? 0 : 2);
}

if (target !== "cli" && target !== "menubar") {
  console.error(`unknown target: ${target}`);
  process.exit(1);
}

if (!BUMP_KINDS.has(bumpArg) && !VERSION_RE.test(bumpArg)) {
  console.error(`invalid bump: ${bumpArg} (use patch|minor|major or a semver)`);
  process.exit(1);
}

const before = readVersion(target);
const touched = target === "cli" ? bumpCli(before, bumpArg) : bumpMenubar(before, bumpArg);
const version = readVersion(target);

if (version === before) {
  console.log(
    `Already at ${target === "cli" ? "QuotaCLI" : "QuotaBar"} ${version}; nothing to do.`,
  );
  process.exit(0);
}
console.log(`updated ${target === "cli" ? "QuotaCLI" : "QuotaBar"}: ${before} → ${version}`);

const tag = `${target === "cli" ? "cli" : "menubar"}-v${version}`;
const label = target === "cli" ? "QuotaCLI" : "QuotaBar";
const message = `chore(${target}): bump version to ${version}`;

if (noCommit) {
  console.log("Skipped commit (--no-commit).");
  console.log(`Publish: git tag -a ${tag} -m "${label} ${version}" && git push origin ${tag}`);
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
console.log(`Publish: git tag -a ${tag} -m "${label} ${version}" && git push origin ${tag}`);

function readVersion(product) {
  if (product === "cli") {
    const manifest = readFileSync(join(root, "apps/cli/Cargo.toml"), "utf8");
    const version = manifest.match(/^version = "([^"]+)"$/m)?.[1];
    if (!version) {
      console.error("cannot read QuotaCLI version from apps/cli/Cargo.toml");
      process.exit(1);
    }
    return version;
  }
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

function bumpCli(current, spec) {
  const next = BUMP_KINDS.has(spec) ? nextSemver(current, spec) : spec;
  const manifestPath = join(root, "apps/cli/Cargo.toml");
  const manifest = readFileSync(manifestPath, "utf8");
  const currentLine = `version = "${current}"`;
  if (!manifest.includes(currentLine)) {
    console.error(`cannot find QuotaCLI version ${current} in apps/cli/Cargo.toml`);
    process.exit(1);
  }
  writeFileSync(manifestPath, manifest.replace(currentLine, `version = "${next}"`));
  const lockfile = run("cargo", ["generate-lockfile", "--offline"]);
  if (lockfile.status !== 0) {
    console.error(lockfile.stderr || "cargo generate-lockfile failed");
    process.exit(lockfile.status ?? 1);
  }
  return ["apps/cli/Cargo.toml", "Cargo.lock"];
}

function bumpMenubar(current, spec) {
  const next = BUMP_KINDS.has(spec) ? nextSemver(current, spec) : spec;
  const path = join(root, "apps/menubar/Support/Info.plist");
  const result = run("plutil", ["-replace", "CFBundleShortVersionString", "-string", next, path]);
  if (result.status !== 0) {
    console.error(result.stderr || "plutil replace failed");
    process.exit(result.status ?? 1);
  }
  return ["apps/menubar/Support/Info.plist"];
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
