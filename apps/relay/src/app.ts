import type { RelayInfo } from "@gotry-io/quota-protocol";
import type { RelayState } from "@gotry-io/relay-core";
import { Hono } from "hono";

export interface RelayAppOptions {
  state: RelayState;
  relayInfo: RelayInfo;
}

export function createRelayApp(options: RelayAppOptions): Hono {
  const app = new Hono();

  app.get("/healthz", (context) =>
    context.json({
      status: "ok",
      service: "QuotaRelay",
      version: options.relayInfo.version,
    }),
  );

  app.get("/readyz", async (context) => {
    try {
      await options.state.ping();
      return context.json({ status: "ready" });
    } catch {
      return context.json({ status: "unavailable" }, 503);
    }
  });

  app.get("/.well-known/quotabar-relay", (context) => context.json(options.relayInfo));

  app.notFound((context) =>
    context.json(
      {
        error: {
          code: "not_found",
          message: "The requested QuotaRelay endpoint does not exist.",
        },
      },
      404,
    ),
  );

  return app;
}
