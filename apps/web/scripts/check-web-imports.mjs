import { readdir, readFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const srcRoot = resolve(fileURLToPath(new URL("../src", import.meta.url)));
const forbidden = [
  /from\s+["']@gotry-io\/quota-relay["']/,
  /from\s+["'][^"']*apps\/relay/,
  /platform\.env/,
  /D1Database/,
  /createRelayApp/,
  /GitHubWebSessions/,
  /usage-summary/,
];

const files = [];

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      await walk(path);
      continue;
    }
    if ([".ts", ".js", ".svelte"].includes(extname(entry.name))) files.push(path);
  }
}

await walk(srcRoot);
const violations = [];
for (const file of files) {
  const source = await readFile(file, "utf8");
  for (const pattern of forbidden) {
    if (pattern.test(source)) violations.push(`${file} matches ${pattern}`);
  }
}

if (violations.length > 0) {
  console.error(violations.join("\n"));
  process.exit(1);
}
