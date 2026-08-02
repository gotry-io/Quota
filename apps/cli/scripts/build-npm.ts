import { chmod, copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const packageRoot = resolve(import.meta.dir, "..");
const outputPath = resolve(packageRoot, "dist/npm/quotacli.js");
await mkdir(dirname(outputPath), { recursive: true });

const result = await Bun.build({
  entrypoints: [resolve(packageRoot, "src/main.ts")],
  format: "esm",
  minify: true,
  naming: "quotacli.js",
  outdir: dirname(outputPath),
  target: "node",
});

if (!result.success) {
  for (const log of result.logs) {
    console.error(log);
  }
  throw new Error("Failed to build the npm QuotaCLI bundle");
}

await chmod(outputPath, 0o755);
await copyFile(resolve(packageRoot, "../../LICENSE"), resolve(packageRoot, "dist/npm/LICENSE"));
