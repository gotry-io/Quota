#!/usr/bin/env node
/**
 * Local Node Relay: bundle once, then esbuild --watch + node --watch.
 * SQLite lives at apps/relay/data/relay.sqlite unless RELAY_SQLITE_PATH is set.
 */
import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const relayRoot = fileURLToPath(new URL("..", import.meta.url));
const sqlitePath = process.env.RELAY_SQLITE_PATH ?? join(relayRoot, "data", "relay.sqlite");
const staticDir =
  process.env.RELAY_STATIC_DIR ?? join(relayRoot, "../web/.svelte-kit/output/client");

await mkdir(dirname(sqlitePath), { recursive: true });

process.env.RELAY_SQLITE_PATH = sqlitePath;
process.env.RELAY_STATIC_DIR = staticDir;

console.log(
  JSON.stringify({
    event: "relay_dev",
    sqlite: sqlitePath,
    static_dir: staticDir,
  }),
);

const children = [];
let shuttingDown = false;

function run(command, args) {
  const child = spawn(command, args, {
    cwd: relayRoot,
    env: process.env,
    stdio: ["ignore", "inherit", "inherit"],
  });
  children.push(child);
  return child;
}

function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const child of children) {
    if (!child.killed) child.kill("SIGTERM");
  }
  process.exit(code);
}

process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

const build = spawn("pnpm", ["run", "build:node"], {
  cwd: relayRoot,
  env: process.env,
  stdio: ["ignore", "inherit", "inherit"],
});
const buildCode = await new Promise((resolve) => {
  build.on("exit", (code) => resolve(code ?? 1));
});
if (buildCode !== 0) process.exit(buildCode);

// Same flags as `build:node`. `--watch=forever` keeps watching with no stdin.
run("pnpm", [
  "exec",
  "esbuild",
  "src/node.ts",
  "--bundle",
  "--platform=node",
  "--format=esm",
  "--target=node24",
  "--external:better-sqlite3",
  "--alias:quota-sveltekit-server=../web/.svelte-kit/output/server/quota-sveltekit-server.js",
  "--outfile=dist/node/server.mjs",
  "--watch=forever",
]);
const server = run(process.execPath, [
  "--watch",
  "--watch-path=dist/node/server.mjs",
  "--env-file-if-exists=.env",
  "dist/node/server.mjs",
]);
server.on("exit", (code, signal) => {
  if (signal) shutdown(0);
  shutdown(code ?? 1);
});
