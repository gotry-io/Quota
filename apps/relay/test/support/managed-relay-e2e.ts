import { mkdirSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";
import { createRelayApp } from "../../src/app.ts";
import { managedRelayInfo } from "../../src/config.ts";
import { SQLiteRelayState } from "../../src/state/sqlite-state.ts";

const databasePath = process.env.QUOTA_RELAY_DATABASE_PATH;
if (!databasePath || !isAbsolute(databasePath)) {
  throw new Error("QUOTA_RELAY_DATABASE_PATH must be an absolute path");
}

mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });
const state = new SQLiteRelayState(databasePath);
await state.initialize();

const relayInfo = managedRelayInfo(process.env.QUOTA_RELAY_INSTANCE_ID ?? "managed-controller-e2e");
const app = createRelayApp({ state, relayInfo });
const server = Bun.serve({
  hostname: process.env.HOST ?? "127.0.0.1",
  port: Number.parseInt(process.env.PORT ?? "0", 10),
  fetch: app.fetch,
});

console.log(`QuotaRelay ${relayInfo.version} listening on ${server.hostname}:${server.port}`);
