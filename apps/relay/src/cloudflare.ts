import { createRelayApp, performRelayMaintenance } from "./app.ts";
import { managedRelayInfo } from "./config.ts";
import { D1RelayState } from "./state/d1-state.ts";

export interface CloudflareBindings {
  DB: D1Database;
  QUOTA_RELAY_INSTANCE_ID?: string;
}

export default {
  async fetch(request, environment): Promise<Response> {
    const state = new D1RelayState(environment.DB);
    const relayInfo = managedRelayInfo(
      environment.QUOTA_RELAY_INSTANCE_ID ?? "gotry-managed-primary",
    );
    const app = createRelayApp({ state, relayInfo });
    return app.fetch(request);
  },
  async scheduled(_event, environment, context): Promise<void> {
    const state = new D1RelayState(environment.DB);
    context.waitUntil(performRelayMaintenance(state, new Date()).then(() => undefined));
  },
} satisfies ExportedHandler<CloudflareBindings>;
