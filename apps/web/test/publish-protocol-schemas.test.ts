import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const webRoot = dirname(fileURLToPath(new URL(".", import.meta.url)));
const schemaOutput = join(webRoot, "static/schema");
const protocolSchema = join(webRoot, "../../packages/protocol/schema");

test("schema publish replaces the generated directory and drops stale files", async () => {
  await mkdir(schemaOutput, { recursive: true });
  const stale = join(schemaOutput, "stale-removed-schema.json");
  await writeFile(stale, '{"stale":true}\n');
  const result = spawnSync(
    process.execPath,
    [join(webRoot, "scripts/publish-protocol-schemas.mjs")],
    {
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const published = new Set(await readdir(schemaOutput));
  assert.equal(published.has("stale-removed-schema.json"), false);
  const source = new Set((await readdir(protocolSchema)).filter((file) => file.endsWith(".json")));
  assert.deepEqual([...published].sort(), [...source].sort());
  const sample = [...source][0];
  if (!sample) throw new Error("protocol schema directory is empty");
  assert.equal(
    await readFile(join(schemaOutput, sample), "utf8"),
    await readFile(join(protocolSchema, sample), "utf8"),
  );
});
