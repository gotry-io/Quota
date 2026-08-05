import type { ProviderId } from "@gotry-io/quota-protocol";
import {
  isConfigurableProviderId,
  maskApiKey,
  normalizeBaseUrl,
  PROVIDER_CATALOG,
  ProviderConfigStore,
  ProviderConfigStoreError,
} from "@gotry-io/quota-provider";
import type { CliOutput } from "../commands.ts";
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
  const spec = entry.config;
  if (spec?.kind !== "api_key") {
    output.stderr(`Config is not supported for provider: ${parsed.provider}`);
    return 2;
  }

  let apiKey: string;
  try {
    apiKey = (await readStdinText()).trim();
  } catch {
    output.stderr("Could not read the API key from stdin.");
    return 1;
  }
  if (!apiKey) {
    output.stderr(
      `${entry.displayName} API key must not be empty. Pass it on stdin with --api-key-stdin.`,
    );
    return 2;
  }

  if (parsed.baseUrl !== undefined) {
    if (!spec.supportsBaseUrl) {
      output.stderr(`${entry.displayName} does not support --base-url.`);
      return 2;
    }
    if (!normalizeBaseUrl(parsed.baseUrl)) {
      output.stderr(
        "Invalid --base-url. Use an HTTPS origin such as https://openrouter.ai/api/v1.",
      );
      return 2;
    }
  }

  try {
    await new ProviderConfigStore().set(parsed.provider, {
      api_key: apiKey,
      ...(parsed.baseUrl ? { base_url: parsed.baseUrl } : {}),
    });
  } catch (error) {
    output.stderr(storeError(error, `QuotaCLI could not save the ${entry.displayName} config.`));
    return 1;
  }

  output.stdout(`Configured ${parsed.provider} (${maskApiKey(apiKey, spec.maskLabel)}).`);
  return 0;
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

function parseConfigSetArgs(
  args: readonly string[],
): { ok: true; provider: ProviderId; baseUrl?: string } | { ok: false; error: string } {
  if (args.length === 0) {
    return {
      ok: false,
      error: "Missing provider. Usage: quotacli config set <provider> --api-key-stdin",
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

  let apiKeyStdin = false;
  let baseUrl: string | undefined;
  for (let index = 1; index < args.length; index += 1) {
    const arg = args[index]!;
    if (arg === "--api-key-stdin") {
      apiKeyStdin = true;
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
        error: "Do not pass API keys on the command line. Use --api-key-stdin and pipe the key.",
      };
    }
    return { ok: false, error: `Unknown option: ${arg}` };
  }

  if (!apiKeyStdin) {
    return {
      ok: false,
      error:
        "Missing --api-key-stdin. Pipe the key: printf '%s' \"$KEY\" | quotacli config set <provider> --api-key-stdin",
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
  quotacli config set <provider> --api-key-stdin [--base-url <https-url>]
  quotacli config get <provider>
  quotacli config unset <provider>
  quotacli config list

Providers:
${providers || "  (none)"}

Examples:
  printf '%s' "$OPENROUTER_API_KEY" | quotacli config set openrouter --api-key-stdin
  quotacli config get openrouter
  quotacli config unset openrouter

Secrets are stored owner-only at ~/.config/quotacli/providers.json (or $XDG_CONFIG_HOME/quotacli/).
get/list never print the full key. Collection prefers config over env fallbacks.`;
}
