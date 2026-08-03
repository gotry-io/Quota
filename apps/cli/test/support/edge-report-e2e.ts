import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { QuotaCollectionReportSchema } from "@gotry-io/quota-protocol";
import {
  type EdgeCommandDependencies,
  type EdgeCommandOutput,
  runEdgeCommand,
} from "../../src/edge/commands.ts";
import { RelayClient } from "../../src/edge/client.ts";
import type { EdgeReportService } from "../../src/edge/launch-agent.ts";
import { EdgeCredentialStore } from "../../src/edge/store.ts";

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

const unusedService: EdgeReportService = {
  async start() {
    throw new Error("The E2E report runner does not manage a background service.");
  },
  async status() {
    return "stopped";
  },
  async stop() {},
};
const dependencies: EdgeCommandDependencies = {
  createClient: (relayUrl) => new RelayClient(relayUrl),
  store: new EdgeCredentialStore(),
  platform: process.platform,
  service: unusedService,
  now: () => new Date(),
  deviceName: () => "Quota E2E",
  collect: async () => parsedReport.data,
};
const output: EdgeCommandOutput = {
  stdout: (message) => process.stdout.write(message.endsWith("\n") ? message : `${message}\n`),
  stderr: (message) => process.stderr.write(message.endsWith("\n") ? message : `${message}\n`),
};

process.exitCode = await runEdgeCommand(["report"], output, dependencies);
