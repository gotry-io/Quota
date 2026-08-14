import { cp, mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cloudflareRoot = resolve(webRoot, ".svelte-kit/cloudflare");
const serverDir = resolve(webRoot, ".svelte-kit/output/server");
const distRoot = resolve(webRoot, "dist");

const skip = new Set(["_worker.js", "_worker.js.map", "_routes.json"]);

await rm(distRoot, { recursive: true, force: true });
await mkdir(distRoot, { recursive: true });

async function copyAssets(from, to) {
  const entries = await readdir(from, { withFileTypes: true });
  for (const entry of entries) {
    if (skip.has(entry.name)) continue;
    const source = join(from, entry.name);
    const target = join(to, entry.name);
    if (entry.isDirectory()) {
      await mkdir(target, { recursive: true });
      await copyAssets(source, target);
      continue;
    }
    await cp(source, target);
  }
}

await stat(cloudflareRoot);
await copyAssets(cloudflareRoot, distRoot);

const reexport = join(serverDir, "quota-sveltekit-server.js");
await writeFile(
  reexport,
  `export { Server } from "./index.js";\nexport { manifest } from "./manifest.js";\n`,
);
console.log(`quota-sveltekit-server re-export written: ${reexport}`);
