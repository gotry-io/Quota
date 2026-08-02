import { copyFile, mkdir, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const schemaRoot = resolve(webRoot, "../../packages/protocol/schema");
const outputRoot = resolve(webRoot, "dist/schema");
const schemaFiles = (await readdir(schemaRoot)).filter((file) => file.endsWith(".json"));

await mkdir(outputRoot, { recursive: true });
await Promise.all(
  schemaFiles.map((file) => copyFile(resolve(schemaRoot, file), resolve(outputRoot, file))),
);
