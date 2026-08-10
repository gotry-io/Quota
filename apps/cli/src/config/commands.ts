import { parseArgs } from "node:util";
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
import { cliParseError } from "../arguments.ts";
import { promptLine } from "./prompt.ts";

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
  if (parsed.baseUrl !== undefined) {
    const error = baseUrlError(parsed.baseUrl, spec, entry.displayName);
    if (error) {
      output.stderr(error);
      return 2;
    }
  }

  let apiKey: string;
  try {
    apiKey = (await promptLine(`${entry.displayName} API key: `, { secret: true })).trim();
  } catch {
    output.stderr("Could not read the API key.");
    return 1;
  }
  if (!apiKey) {
    output.stderr(`${entry.displayName} API key must not be empty.`);
    return 2;
  }

  let baseUrl = parsed.baseUrl;
  if (baseUrl === undefined && spec.supportsBaseUrl) {
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
    const error = baseUrlError(baseUrl, spec, entry.displayName);
    if (error) {
      output.stderr(error);
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

function baseUrlError(
  baseUrl: string,
  spec: ProviderApiKeyConfigSpec,
  displayName: string,
): string | undefined {
  if (!spec.supportsBaseUrl) {
    return `${displayName} does not support --base-url.`;
  }
  if (normalizeBaseUrl(baseUrl, { allowPrivateHttp: spec.allowPrivateHttp === true })) {
    return undefined;
  }
  return spec.allowPrivateHttp
    ? "Invalid base URL. Use HTTPS, or HTTP only for loopback/private/.local hosts."
    : "Invalid base URL. Use an HTTPS origin such as https://litellm.example.com.";
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
    if (secret.base_url && PROVIDER_CATALOG[provider].config?.supportsBaseUrl === true) {
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
  | { ok: true; provider: ProviderId; baseUrl?: string }
  | { ok: false; error: string };

function parseConfigSetArgs(args: readonly string[]): ConfigSetParse {
  if (args.length === 0) {
    return {
      ok: false,
      error: "Missing provider. Usage: quotacli config set <provider>",
    };
  }

  let parsed: {
    values: { "base-url"?: string; "api-key"?: string };
    positionals: string[];
  };
  try {
    parsed = parseArgs({
      args: [...args],
      options: {
        "base-url": { type: "string" },
        "api-key": { type: "string" },
      },
      strict: true,
      allowPositionals: true,
    });
  } catch (error) {
    return { ok: false, error: cliParseError(error) };
  }
  if (parsed.positionals.length !== 1) {
    return { ok: false, error: "Expected exactly one provider." };
  }
  const providerRaw = parsed.positionals[0]!;
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

  if (parsed.values["api-key"] !== undefined) {
    return {
      ok: false,
      error:
        "Do not pass API keys on the command line. Run `quotacli config set <provider>` and enter the key when prompted.",
    };
  }
  const baseUrl = parsed.values["base-url"];

  if (!process.stdin.isTTY) {
    return {
      ok: false,
      error: "No interactive terminal. Run in a TTY to enter the key when prompted.",
    };
  }

  return {
    ok: true,
    provider,
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
  quotacli config get <provider>
  quotacli config unset <provider>
  quotacli config list

Providers:
${providers || "  (none)"}

Examples:
  quotacli config set deepseek
  quotacli config set litellm --base-url https://litellm.example.com
  quotacli config get openrouter
  quotacli config unset openrouter

Interactive set prompts for the API key (input is hidden). Providers that need a base URL
prompt for it unless --base-url is passed.
Secrets are stored owner-only at ~/.config/quotacli/providers.json (or $XDG_CONFIG_HOME/quotacli/).
get/list never print the full key. Collection prefers config over env fallbacks.`;
}
