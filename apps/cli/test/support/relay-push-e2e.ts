import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { QuotaCollectionReportSchema } from "@gotry-io/quota-protocol";
import { RelayClient } from "../../src/relay/client.ts";
import {
  type RelayCommandDependencies,
  type RelayCommandOutput,
  runRelayCommand,
} from "../../src/relay/commands.ts";
import type { RelayPushService } from "../../src/relay/launch-agent.ts";
import { RelayCredentialStore } from "../../src/relay/store.ts";

const reportPath = process.argv[2];
if (!reportPath || !isAbsolute(reportPath)) {
  process.stderr.write("The E2E collection report path must be absolute.\n");
  process.exit(2);
}

let report: unknown;
try {
  report = JSON.parse(await readFile(reportPath, "utf8"));
} catch {
  process.stderr.write("The E2E collection report could not be read.\n");
  process.exit(2);
}
const parsedReport = QuotaCollectionReportSchema.safeParse(report);
if (!parsedReport.success) {
  process.stderr.write("The E2E collection report is invalid.\n");
  process.exit(2);
}

const unusedService: RelayPushService = {
  async start() {
    throw new Error("The E2E report runner does not manage a background service.");
  },
  async status() {
    return "stopped";
  },
  async stop() {},
};
const dependencies: RelayCommandDependencies = {
  createClient: (relayUrl) => new RelayClient(relayUrl),
  store: new RelayCredentialStore(),
  platform: process.platform,
  service: unusedService,
  now: () => new Date(),
  deviceName: () => "Quota E2E",
  collect: async () => parsedReport.data,
  diagnoseProviders: async () => [],
};
const output: RelayCommandOutput = {
  stdout: (message) => process.stdout.write(message.endsWith("\n") ? message : `${message}\n`),
  stderr: (message) => process.stderr.write(message.endsWith("\n") ? message : `${message}\n`),
};

process.exitCode = await runRelayCommand(["push"], output, dependencies);
