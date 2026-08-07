import type { ProviderId } from "@gotry-io/quota-protocol";
import {
  isConfigurableProviderId,
  maskApiKey,
  normalizeBaseUrl,
  PROVIDER_CATALOG,
  ProviderConfigStore,
  ProviderConfigStoreError,
  type ProviderApiKeyConfigSpec,
} from "@gotry-io/quota-provider";
import type { CliOutput } from "../commands.ts";
import { promptLine } from "./prompt.ts";
import { readStdinText } from "./stdin.ts";

export async function runConfigCommand(
  args: readonly string[],
  output: CliOutput,
): Promise<number> {
  const verb = args[0];
  if (!verb || verb === "--help" || verb === "-h") {
    output.stdout(configUsage());
    return 0;
  }

  switch (verb) {
    case "set":
      return await runConfigSet(args.slice(1), output);
    case "get":
      return await runConfigGet(args.slice(1), output);
    case "unset":
      return await runConfigUnset(args.slice(1), output);
    case "list":
      return await runConfigList(args.slice(1), output);
    default:
      output.stderr(`Unknown config command: ${verb}\n\n${configUsage()}`);
      return 2;
  }
}

async function runConfigSet(args: readonly string[], output: CliOutput): Promise<number> {
  const parsed = parseConfigSetArgs(args);
  if (!parsed.ok) {
    output.stderr(`${parsed.error}\n\n${configUsage()}`);
    return 2;
  }

  const entry = PROVIDER_CATALOG[parsed.provider];
  if (entry.config?.kind !== "api_key") {
    output.stderr(`Config is not supported for provider: ${parsed.provider}`);
    return 2;
  }
  // Catalog is `as const`; optional api_key flags need the shared interface for access.
  const spec = entry.config as ProviderApiKeyConfigSpec;

  let apiKey: string;
  try {
    apiKey = (await readApiKey(parsed.mode, entry.displayName)).trim();
  } catch {
    output.stderr("Could not read the API key.");
    return 1;
  }
  if (!apiKey) {
    output.stderr(`${entry.displayName} API key must not be empty.`);
    return 2;
  }

  let baseUrl = parsed.baseUrl;
  if (baseUrl === undefined && spec.supportsBaseUrl && parsed.mode === "prompt") {
    try {
      const answer = (
        await promptLine(
          spec.requireBaseUrl
            ? `${entry.displayName} base URL (required): `
            : `${entry.displayName} base URL (optional, Enter to skip): `,
        )
      ).trim();
      if (answer) {
        baseUrl = answer;
      } else if (spec.requireBaseUrl) {
        output.stderr(`${entry.displayName} requires a base URL.`);
        return 2;
      }
    } catch {
      output.stderr("Could not read the base URL.");
      return 1;
    }
  }

  if (baseUrl !== undefined) {
    if (!spec.supportsBaseUrl) {
      output.stderr(`${entry.displayName} does not support --base-url.`);
      return 2;
    }
    if (
      !normalizeBaseUrl(baseUrl, {
        allowPrivateHttp: spec.allowPrivateHttp === true,
      })
    ) {
      output.stderr(
        spec.allowPrivateHttp
          ? "Invalid base URL. Use HTTPS, or HTTP only for loopback/private/.local hosts."
          : "Invalid base URL. Use an HTTPS origin such as https://openrouter.ai/api/v1.",
      );
      return 2;
    }
  } else if (spec.requireBaseUrl) {
    output.stderr(
      `${entry.displayName} requires a base URL. Pass --base-url or enter it when prompted.`,
    );
    return 2;
  }

  try {
    await new ProviderConfigStore().set(parsed.provider, {
      api_key: apiKey,
      ...(baseUrl ? { base_url: baseUrl } : {}),
    });
  } catch (error) {
    output.stderr(storeError(error, `QuotaCLI could not save the ${entry.displayName} config.`));
    return 1;
  }

  output.stdout(`Configured ${parsed.provider} (${maskApiKey(apiKey, spec.maskLabel)}).`);
  return 0;
}

async function readApiKey(mode: "prompt" | "stdin", displayName: string): Promise<string> {
  if (mode === "stdin") {
    return await readStdinText();
  }
  return await promptLine(`${displayName} API key: `, { secret: true });
}

async function runConfigGet(args: readonly string[], output: CliOutput): Promise<number> {
  const provider = requireOneProvider(args, "get", output);
  if (!provider) {
    return 2;
  }

  try {
    const secret = await new ProviderConfigStore().get(provider);
    if (!secret) {
      output.stdout(`${provider}: not configured`);
      return 0;
    }
    output.stdout(`${provider}: ${maskApiKey(secret.api_key, maskLabel(provider))}`);
    if (secret.base_url) {
      output.stdout(`  base_url: ${secret.base_url}`);
    }
    return 0;
  } catch (error) {
    output.stderr(storeError(error, "QuotaCLI could not read the provider config."));
    return 1;
  }
}

async function runConfigUnset(args: readonly string[], output: CliOutput): Promise<number> {
  const provider = requireOneProvider(args, "unset", output);
  if (!provider) {
    return 2;
  }

  try {
    const removed = await new ProviderConfigStore().unset(provider);
    output.stdout(removed ? `Removed ${provider} config.` : `${provider}: not configured`);
    return 0;
  } catch (error) {
    output.stderr(storeError(error, "QuotaCLI could not update the provider config."));
    return 1;
  }
}

async function runConfigList(args: readonly string[], output: CliOutput): Promise<number> {
  if (args.length !== 0) {
    output.stderr(`Usage: quotacli config list\n\n${configUsage()}`);
    return 2;
  }
  try {
    const store = new ProviderConfigStore();
    const configured = await store.listConfigured();
    if (configured.length === 0) {
      output.stdout("No provider secrets configured.");
      return 0;
    }
    for (const id of configured) {
      const secret = await store.get(id);
      output.stdout(`${id}\t${secret ? maskApiKey(secret.api_key, maskLabel(id)) : "configured"}`);
    }
    return 0;
  } catch (error) {
    output.stderr(storeError(error, "QuotaCLI could not list provider config."));
    return 1;
  }
}

function requireOneProvider(
  args: readonly string[],
  verb: string,
  output: CliOutput,
): ProviderId | undefined {
  if (args.length !== 1) {
    output.stderr(`Usage: quotacli config ${verb} <provider>\n\n${configUsage()}`);
    return undefined;
  }
  const raw = args[0]!;
  if (!isConfigurableProviderId(raw)) {
    output.stderr(`Unknown or non-configurable provider: ${raw}`);
    return undefined;
  }
  return raw;
}

function maskLabel(provider: ProviderId): string {
  const config = PROVIDER_CATALOG[provider].config;
  return config?.kind === "api_key" ? config.maskLabel : PROVIDER_CATALOG[provider].displayName;
}

type ConfigSetParse =
  | { ok: true; provider: ProviderId; mode: "prompt" | "stdin"; baseUrl?: string }
  | { ok: false; error: string };

function parseConfigSetArgs(args: readonly string[]): ConfigSetParse {
  if (args.length === 0) {
    return {
      ok: false,
      error: "Missing provider. Usage: quotacli config set <provider>",
    };
  }

  const providerRaw = args[0]!;
  if (!isConfigurableProviderId(providerRaw)) {
    const supported = Object.values(PROVIDER_CATALOG)
      .filter((e) => e.config !== null)
      .map((e) => e.id)
      .join(", ");
    return {
      ok: false,
      error: `Unknown or non-configurable provider: ${providerRaw}. Supported: ${supported || "(none)"}.`,
    };
  }
  const provider = providerRaw;

  let useStdin = false;
  let baseUrl: string | undefined;
  for (let index = 1; index < args.length; index += 1) {
    const arg = args[index]!;
    if (arg === "--api-key-stdin") {
      useStdin = true;
      continue;
    }
    if (arg === "--base-url" || arg.startsWith("--base-url=")) {
      const value = arg === "--base-url" ? args[++index] : arg.slice("--base-url=".length);
      if (!value) {
        return { ok: false, error: "Missing value for --base-url." };
      }
      baseUrl = value;
      continue;
    }
    if (arg === "--api-key" || arg.startsWith("--api-key=")) {
      return {
        ok: false,
        error:
          "Do not pass API keys on the command line. Run `quotacli config set <provider>` and enter the key when prompted, or pipe with --api-key-stdin.",
      };
    }
    return { ok: false, error: `Unknown option: ${arg}` };
  }

  if (!useStdin && !process.stdin.isTTY) {
    return {
      ok: false,
      error:
        "No interactive terminal. Run in a TTY to be prompted, or pipe the key with --api-key-stdin.",
    };
  }

  return {
    ok: true,
    provider,
    mode: useStdin ? "stdin" : "prompt",
    ...(baseUrl !== undefined ? { baseUrl } : {}),
  };
}

function storeError(error: unknown, fallback: string): string {
  return error instanceof ProviderConfigStoreError ? error.message : fallback;
}

export function configUsage(): string {
  const providers = Object.values(PROVIDER_CATALOG)
    .filter((e) => e.config !== null)
    .map((e) => `  ${e.id}`)
    .join("\n");

  return `QuotaCLI config

Usage:
  quotacli config set <provider> [--base-url <url>]
  quotacli config set <provider> --api-key-stdin [--base-url <url>]
  quotacli config get <provider>
  quotacli config unset <provider>
  quotacli config list

Providers:
${providers || "  (none)"}

Examples:
  quotacli config set deepseek
  quotacli config set litellm --base-url https://litellm.example.com
  printf '%s' "$OPENROUTER_API_KEY" | quotacli config set openrouter --api-key-stdin
  quotacli config get openrouter
  quotacli config unset openrouter

Interactive set prompts for the API key (input is hidden). Providers that need a base URL
prompt for it unless --base-url is passed. --api-key-stdin is for scripts/pipes only.
Secrets are stored owner-only at ~/.config/quotacli/providers.json (or $XDG_CONFIG_HOME/quotacli/).
get/list never print the full key. Collection prefers config over env fallbacks.`;
}
