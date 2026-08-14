import { copyFile, mkdir, readdir, rm } from "node:fs/promises";
import { dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const schemaRoot = resolve(webRoot, "../../packages/protocol/schema");
const outputRoot = resolve(webRoot, "static/schema");
const expectedSuffix = ["apps", "web", "static", "schema"].join(sep);
if (!outputRoot.endsWith(expectedSuffix) || outputRoot === schemaRoot) {
  throw new Error(`Refusing to clean unexpected schema output path: ${outputRoot}`);
}

const schemaFiles = (await readdir(schemaRoot)).filter((file) => file.endsWith(".json")).sort();
await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });
await Promise.all(
  schemaFiles.map((file) => copyFile(resolve(schemaRoot, file), resolve(outputRoot, file))),
);
