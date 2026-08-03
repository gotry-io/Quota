import {
  type ProviderId,
  ProviderIdSchema,
  QuotaCollectionReportSchema,
} from "@gotry-io/quota-protocol";
import {
  collectionExitCode,
  collectQuotaReport,
  diagnoseProviderSessions,
  providerDescriptors,
} from "@gotry-io/quota-provider";
import packageMetadata from "../package.json" with { type: "json" };
import { runEdgeCommand } from "./edge/commands.ts";
import { renderJson, renderText } from "./render.ts";

export const QUOTA_CLI_VERSION = packageMetadata.version;

export interface CliOutput {
  stdout(message: string): void;
  stderr(message: string): void;
}

export interface CliRuntime {
  isTty?: boolean;
  now?: Date;
}

const defaultOutput: CliOutput = {
  stdout: (message) => {
    process.stdout.write(message.endsWith("\n") ? message : `${message}\n`);
  },
  stderr: (message) => {
    process.stderr.write(message.endsWith("\n") ? message : `${message}\n`);
  },
};

export async function runCli(
  args: readonly string[],
  output: CliOutput = defaultOutput,
  runtime: CliRuntime = {},
): Promise<number> {
  const command = args[0] ?? "help";

  switch (command) {
    case "version":
    case "--version":
    case "-v":
      output.stdout(`QuotaCLI ${QUOTA_CLI_VERSION}`);
      return 0;

    case "providers":
      for (const provider of providerDescriptors) {
        output.stdout(`${provider.id}\t${provider.display_name}`);
      }
      return 0;

    case "doctor": {
      const diagnostics = await diagnoseProviderSessions({ probeKeychain: true });
      for (const diagnostic of diagnostics) {
        const marker = diagnostic.available ? "found" : "missing";
        output.stdout(
          `${diagnostic.provider}\t${marker}\t${diagnostic.credential_source}\t${diagnostic.detail}`,
        );
      }
      return 0;
    }

    case "quota":
      if (args.slice(1).some((arg) => arg === "--help" || arg === "-h")) {
        output.stdout(usage());
        return 0;
      }
      return await runQuotaCommand(args.slice(1), output, runtime);

    case "edge":
      return await runEdgeCommand(args.slice(1), output);

    case "help":
    case "--help":
    case "-h":
      output.stdout(usage());
      return 0;

    default:
      output.stderr(`Unknown command: ${command}\n\n${usage()}`);
      return 2;
  }
}

async function runQuotaCommand(
  args: readonly string[],
  output: CliOutput,
  runtime: CliRuntime,
): Promise<number> {
  const parsed = parseQuotaArgs(args, runtime.isTty ?? Boolean(process.stdout.isTTY));
  if (!parsed.ok) {
    output.stderr(`${parsed.error}\n\n${usage()}`);
    return 2;
  }

  const report = await collectQuotaReport({
    providers: parsed.providers,
    clientVersion: QUOTA_CLI_VERSION,
    ...(runtime.now ? { now: runtime.now } : {}),
  });
  const validated = QuotaCollectionReportSchema.parse(report);

  if (parsed.format === "json") {
    output.stdout(renderJson(validated, parsed.pretty));
  } else {
    output.stdout(renderText(validated));
  }

  return collectionExitCode(validated);
}

interface ParsedQuotaArgs {
  ok: true;
  providers: "all" | ProviderId[];
  format: "text" | "json";
  pretty: boolean;
}

interface ParsedQuotaArgsError {
  ok: false;
  error: string;
}

function parseQuotaArgs(
  args: readonly string[],
  isTty: boolean,
): ParsedQuotaArgs | ParsedQuotaArgsError {
  let provider: "all" | ProviderId[] = "all";
  let format: "text" | "json" | undefined;
  let pretty = false;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === undefined) {
      continue;
    }
    if (arg === "--pretty") {
      pretty = true;
      continue;
    }
    if (arg === "--provider" || arg.startsWith("--provider=")) {
      const value = arg === "--provider" ? args[++index] : arg.slice("--provider=".length);
      if (!value) {
        return { ok: false, error: "Missing value for --provider." };
      }
      const resolved = parseProviderOption(value);
      if (!resolved.ok) {
        return resolved;
      }
      provider = resolved.providers;
      continue;
    }
    if (arg === "--format" || arg.startsWith("--format=")) {
      const value = arg === "--format" ? args[++index] : arg.slice("--format=".length);
      if (!value) {
        return { ok: false, error: "Missing value for --format." };
      }
      if (value !== "text" && value !== "json") {
        return { ok: false, error: `Invalid --format value: ${value}` };
      }
      format = value;
      continue;
    }
    return { ok: false, error: `Unknown option: ${arg}` };
  }

  return {
    ok: true,
    providers: provider,
    format: format ?? (isTty ? "text" : "json"),
    pretty,
  };
}

function parseProviderOption(
  value: string,
): { ok: true; providers: "all" | ProviderId[] } | ParsedQuotaArgsError {
  if (value === "all") {
    return { ok: true, providers: "all" };
  }
  const parts = value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length === 0) {
    return { ok: false, error: "Missing value for --provider." };
  }
  const providers: ProviderId[] = [];
  for (const part of parts) {
    const parsed = ProviderIdSchema.safeParse(part);
    if (!parsed.success) {
      return {
        ok: false,
        error: `Invalid --provider value: ${part}. Expected codex|claude|grok|all.`,
      };
    }
    providers.push(parsed.data);
  }
  return { ok: true, providers };
}

function usage(): string {
  return `QuotaCLI

Usage:
  quotacli version
  quotacli providers
  quotacli doctor
  quotacli quota [--provider codex|claude|grok|all] [--format text|json] [--pretty]
  quotacli edge pair [--relay <url>]
  quotacli edge report
  quotacli edge start
  quotacli edge status
  quotacli edge stop
  quotacli edge unpair
  quotacli help

Defaults:
  --provider all
  --format text when attached to a terminal, otherwise json

Exit codes for quota:
  0  every requested provider returned at least one fresh snapshot
  1  collection completed with one or more provider failures
  2  invalid CLI arguments`;
}
