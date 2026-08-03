import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRelayApp } from "./app.ts";
import { selfHostedRelayInfo } from "./config.ts";
import { bootstrapSelfHostedOwner, requireSelfHostedOwnerToken } from "./self-hosted-bootstrap.ts";
import { SQLiteRelayState } from "./state/sqlite-state.ts";

const ownerToken = requireSelfHostedOwnerToken(process.env.QUOTA_RELAY_OWNER_TOKEN);
const databasePath = resolve(process.env.QUOTA_RELAY_DATABASE_PATH ?? "./data/quota-relay.db");
mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });

const state = new SQLiteRelayState(databasePath);
await state.initialize();
await bootstrapSelfHostedOwner(state, ownerToken, new Date());

const relayInfo = selfHostedRelayInfo(process.env.QUOTA_RELAY_INSTANCE_ID ?? "self-hosted-primary");
const app = createRelayApp({ state, relayInfo });
const port = Number.parseInt(process.env.PORT ?? "8080", 10);
const hostname = process.env.HOST ?? "0.0.0.0";

const server = Bun.serve({
  hostname,
  port,
  fetch: app.fetch,
});

console.log(`QuotaRelay ${relayInfo.version} listening on ${server.hostname}:${server.port}`);
