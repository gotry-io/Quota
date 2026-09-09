import { runHourlyMaintenance } from "./app.ts";
import { type RelayPlatform, type RelaySecrets, respondAsRelay } from "./deployment.ts";
import { WorkersReadingCache } from "./platform/reading-cache.ts";
import { WorkersStaticFiles } from "./platform/static-files.ts";
import { D1AccountState } from "./state/d1-account-state.ts";

export interface CloudflareBindings extends RelaySecrets {
  DB: D1Database;
  ASSETS: Fetcher;
}

function workersPlatform(environment: CloudflareBindings): RelayPlatform {
  return {
    database: environment.DB,
    assets: new WorkersStaticFiles(environment.ASSETS),
    statusCache: new WorkersReadingCache(),
    secrets: environment,
  };
}

export default {
  fetch(request, environment, context): Promise<Response> {
    return respondAsRelay(request, workersPlatform(environment), context);
  },
  async scheduled(_controller, environment): Promise<void> {
    await runHourlyMaintenance(new D1AccountState(environment.DB), new Date());
  },
} satisfies ExportedHandler<CloudflareBindings>;
