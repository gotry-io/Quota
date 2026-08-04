import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRelayApp, performRelayMaintenance } from "./app.ts";
import { selfHostedRelayInfo } from "./config.ts";
import { SQLiteRelayState } from "./state/sqlite-state.ts";

const databasePath = resolve(process.env.QUOTA_RELAY_DATABASE_PATH ?? "./data/quota-relay.db");
mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });

const state = new SQLiteRelayState(databasePath);
await state.initialize();
await performRelayMaintenance(state, new Date());

const relayInfo = selfHostedRelayInfo(process.env.QUOTA_RELAY_INSTANCE_ID ?? "self-hosted-primary");
const app = createRelayApp({ state, relayInfo });
const port = Number.parseInt(process.env.PORT ?? "8080", 10);
const hostname = process.env.HOST ?? "0.0.0.0";

const server = Bun.serve({
  hostname,
  port,
  fetch: app.fetch,
});

setInterval(
  () => {
    void performRelayMaintenance(state, new Date()).catch(() => {
      console.error("QuotaRelay maintenance failed");
    });
  },
  60 * 60 * 1000,
);

console.log(`QuotaRelay ${relayInfo.version} listening on ${server.hostname}:${server.port}`);
