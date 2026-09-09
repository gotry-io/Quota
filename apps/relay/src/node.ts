import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import { runHourlyMaintenance } from "./app.ts";
import { type RelayPlatform, type RelaySecrets, respondAsRelay } from "./deployment.ts";
import { recordConnectionAddress } from "./platform/client-address.ts";
import { applyMigrations } from "./platform/migrations.ts";
import { MemoryReadingCache } from "./platform/reading-cache.ts";
import { SqliteDatabase } from "./platform/sqlite-database.ts";
import { NodeStaticFiles } from "./platform/static-files.ts";
import { isRelayApiPath } from "./relay-paths.ts";
import { SecretHasher } from "./security.ts";
import { D1AccountState } from "./state/d1-account-state.ts";

const SECRET_NAMES = [
  "GITHUB_CLIENT_ID",
  "GITHUB_CLIENT_SECRET",
  "APPLE_SIGNIN_TEAM_ID",
  "APPLE_SIGNIN_SERVICES_ID",
  "APPLE_SIGNIN_KEY_ID",
  "APPLE_SIGNIN_PRIVATE_KEY",
  "IDENTITY_SUBJECT_KEY",
  "QUOTA_INSTALLATION_KEY",
  "QUOTA_SESSION_HASH_KEY",
  "RESEND_API_KEY",
] as const satisfies ReadonlyArray<keyof RelaySecrets>;

const HOUR_MILLISECONDS = 60 * 60 * 1000;

/**
 * A missing secret is a deployment that would answer sign-in with a 500 for as long as it ran,
 * so it is refused at startup, naming every value it still needs rather than the first one.
 */
function readSecrets(environment: NodeJS.ProcessEnv): RelaySecrets {
  const missing = SECRET_NAMES.filter((name) => !environment[name]);
  if (missing.length > 0) {
    throw new Error(`QuotaRelay is missing required configuration: ${missing.join(", ")}`);
  }
  const secrets = Object.fromEntries(
    SECRET_NAMES.map((name) => [name, environment[name] as string]),
  ) as unknown as RelaySecrets;
  // A Docker env file holds one line per value, so the PEM arrives with the two characters
  // `\n` where Apple put line breaks; Workers secrets keep the breaks themselves.
  return {
    ...secrets,
    APPLE_SIGNIN_PRIVATE_KEY: secrets.APPLE_SIGNIN_PRIVATE_KEY.replace(/\\n/g, "\n"),
  };
}

const database = new SqliteDatabase(process.env.RELAY_SQLITE_PATH ?? "/data/relay.sqlite");
const applied = await applyMigrations(
  database,
  fileURLToPath(new URL("../../migrations", import.meta.url)),
);
console.log(JSON.stringify({ event: "relay_migrations_applied", applied }));

const assets = new NodeStaticFiles(
  process.env.RELAY_STATIC_DIR ?? "apps/web/.svelte-kit/output/client",
);
const secrets = readSecrets(process.env);
// Constructed only to apply its own key rule before the port opens: a session hashing key too
// short to use would otherwise make every request a 500 that says nothing about why.
new SecretHasher(secrets.QUOTA_SESSION_HASH_KEY);

const platform: RelayPlatform = {
  database,
  assets,
  statusCache: new MemoryReadingCache(),
  secrets,
};

const server = serve({
  port: Number(process.env.PORT ?? 8787),
  async fetch(request, environment) {
    recordConnectionAddress(request, environment.incoming.socket.remoteAddress);
    const url = new URL(request.url);
    // Cloudflare serves the built files ahead of the Worker; here nothing is in front, so the
    // one file the build produced for this path is the answer before a document is rendered.
    try {
      if (!isRelayApiPath(url.pathname)) {
        const asset = await assets.fetch(url);
        if (asset.ok) return asset;
      }
      return await respondAsRelay(request, platform, undefined);
    } catch (error) {
      // Cloudflare records an unhandled exception itself; nothing here does, and a 500 nobody
      // wrote down is a deployment that cannot be diagnosed. The error's own name is the most it
      // may carry, for the reason `createRelayApp` states: a message can quote a bound parameter.
      console.error(
        JSON.stringify({
          event: "relay_request_failed",
          path: url.pathname,
          status: 500,
          error: error instanceof Error ? error.name : "Error",
        }),
      );
      return new Response("QuotaRelay could not complete the request.", {
        status: 500,
        headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
      });
    }
  },
});

const maintenance = setInterval(() => {
  runHourlyMaintenance(new D1AccountState(database), new Date()).catch((error: unknown) => {
    console.error(
      JSON.stringify({
        event: "relay_maintenance_failed",
        error: error instanceof Error ? error.name : "Error",
      }),
    );
  });
}, HOUR_MILLISECONDS);

process.on("SIGTERM", () => {
  clearInterval(maintenance);
  server.close(() => {
    database.close();
    process.exit(0);
  });
});
