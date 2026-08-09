import {
  PROVIDER_IDS,
  type ProviderId,
  ProviderIdSchema,
  QuotaCollectionReportSchema,
} from "@gotry-io/quota-protocol";
import {
  collectionExitCode,
  collectQuotaReport,
  diagnoseProviderSessions,
  PROVIDER_CATALOG,
} from "@gotry-io/quota-provider";
import packageMetadata from "../package.json" with { type: "json" };
import { configUsage, runConfigCommand } from "./config/commands.ts";
import { runDoctorCommand, runRelayCommand } from "./relay/commands.ts";
import { renderJson, renderText } from "./render.ts";

export const QUOTA_CLI_VERSION = packageMetadata.version;

export interface CliOutput {
  stdout(message: string): void;
  stderr(message: string): void;
  progress?(message?: string): void;
}

export interface CliRuntime {
  isTty?: boolean;
  progressIsTty?: boolean;
  color?: boolean;
  now?: Date;
}

const defaultOutput: CliOutput = {
  stdout: (message) => {
    process.stdout.write(message.endsWith("\n") ? message : `${message}\n`);
  },
  stderr: (message) => {
    process.stderr.write(message.endsWith("\n") ? message : `${message}\n`);
  },
  progress: (message) => {
    process.stderr.write(`\r\u001B[2K${message ?? ""}`);
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

    case "status":
      if (args.slice(1).some((arg) => arg === "--help" || arg === "-h")) {
        output.stdout(usage());
        return 0;
      }
      return await runStatusCommand(args.slice(1), output, runtime);

    case "doctor":
      if (args.slice(1).some((arg) => arg === "--help" || arg === "-h")) {
        output.stdout(usage());
        return 0;
      }
      if (args.length !== 1) {
        output.stderr(`The doctor command does not accept options.\n\n${usage()}`);
        return 2;
      }
      return await runDoctorCommand(output);

    case "relay":
      return await runRelayCommand(args.slice(1), output);

    case "config":
      return await runConfigCommand(args.slice(1), output);

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

async function runStatusCommand(
  args: readonly string[],
  output: CliOutput,
  runtime: CliRuntime,
): Promise<number> {
  const isTty = runtime.isTty ?? Boolean(process.stdout.isTTY);
  const progressIsTty = runtime.progressIsTty ?? runtime.isTty ?? Boolean(process.stderr.isTTY);
  const parsed = parseStatusArgs(args, isTty);
  if (!parsed.ok) {
    output.stderr(`${parsed.error}\n\n${usage()}`);
    return 2;
  }

  const showProgress = parsed.format === "text" && progressIsTty && output.progress !== undefined;
  if (showProgress) {
    output.progress?.("Discovering configured providers…");
  }

  let report: Awaited<ReturnType<typeof collectQuotaReport>> | undefined;
  try {
    const providers =
      parsed.providers === "auto" ? await discoverConfiguredProviders() : parsed.providers;
    let completed = 0;
    report = await collectQuotaReport({
      providers,
      clientVersion: QUOTA_CLI_VERSION,
      ...(runtime.now ? { now: runtime.now } : {}),
      ...(showProgress
        ? {
            onProviderProgress: (provider: ProviderId, state: "collecting" | "done") => {
              if (state === "done") {
                completed += 1;
              }
              const total = providers === "all" ? PROVIDER_IDS.length : providers.length;
              output.progress?.(
                `Collecting quota ${completed}/${total} · ${PROVIDER_CATALOG[provider].displayName} ${state === "done" ? "complete" : "started"}`,
              );
            },
          }
        : {}),
    });
  } catch {
    // The command boundary reports only fixed recovery guidance; discovery may touch secret paths.
  } finally {
    if (showProgress) {
      output.progress?.();
    }
  }
  if (report === undefined) {
    output.stderr(
      "QuotaCLI could not discover or collect local provider quota. Run `quotacli doctor` for setup details.",
    );
    return 1;
  }
  const validated = QuotaCollectionReportSchema.parse(report);

  if (parsed.format === "json") {
    output.stdout(renderJson(validated, parsed.pretty));
  } else {
    output.stdout(
      renderText(validated, {
        color:
          runtime.color ?? (Boolean(process.stdout.isTTY) && process.env.NO_COLOR === undefined),
      }),
    );
  }

  return collectionExitCode(validated);
}

interface ParsedStatusArgs {
  ok: true;
  providers: "auto" | "all" | ProviderId[];
  format: "text" | "json";
  pretty: boolean;
}

interface ParsedStatusArgsError {
  ok: false;
  error: string;
}

function parseStatusArgs(
  args: readonly string[],
  isTty: boolean,
): ParsedStatusArgs | ParsedStatusArgsError {
  let provider: "auto" | "all" | ProviderId[] = "auto";
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

async function discoverConfiguredProviders(): Promise<ProviderId[]> {
  const diagnostics = await diagnoseProviderSessions({ probeKeychain: true });
  return PROVIDER_IDS.filter((provider) =>
    diagnostics.some((diagnostic) => diagnostic.provider === provider && diagnostic.available),
  );
}

function parseProviderOption(
  value: string,
): { ok: true; providers: "all" | ProviderId[] } | ParsedStatusArgsError {
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
        error: `Invalid --provider value: ${part}. Expected ${providerChoiceList()}.`,
      };
    }
    if (!providers.includes(parsed.data)) {
      providers.push(parsed.data);
    }
  }
  return { ok: true, providers };
}

function providerChoiceList(): string {
  return `${PROVIDER_IDS.join("|")}|all`;
}

function usage(): string {
  return `QuotaCLI

Usage:
  quotacli version
  quotacli status [--provider ${providerChoiceList()}] [--format text|json] [--pretty]
  quotacli doctor
  quotacli relay pair [--relay <url>]
  quotacli relay push
  quotacli relay unpair
  quotacli config set <provider> [--base-url <url>]
  quotacli config get <provider>
  quotacli config unset <provider>
  quotacli config list
  quotacli help

Defaults:
  --provider configured providers discovered from local credentials
  --format text when attached to a terminal, otherwise json

relay pair stores a device credential, uploads one snapshot immediately, then enables macOS
background push every 5 minutes.
relay push collects local quota and uploads one snapshot to the paired Relay.
status collects and renders local provider quota.
doctor summarizes local provider readiness and Relay pairing/background state without collection.
config stores API-key providers (openrouter, deepseek, kimi, litellm) in ~/.config/quotacli/providers.json (owner-only).

Exit codes for status:
  0  every requested provider returned at least one fresh snapshot
  1  no configured provider, or collection completed with a provider/session failure
  2  invalid CLI arguments

${configUsage()}`;
}
