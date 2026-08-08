import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { API_KEY_SPECS } from "./api-key/specs.ts";
import { resolveApiKeyCredentials } from "./api-key/resolve.ts";
import type { ProviderDiagnostic } from "./contracts.ts";
import { CLAUDE_KEYCHAIN_SERVICE, claudeCredentialPaths } from "./providers/claude/credentials.ts";
import { codexAuthPaths } from "./providers/codex/credentials.ts";
import { grokAuthPaths } from "./providers/grok/credentials.ts";
import { readGenericPassword } from "./runtime/keychain.ts";

interface DiscoveryOptions {
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  platform?: NodeJS.Platform;
  canAccess?: (path: string) => Promise<boolean>;
  probeKeychain?: boolean;
}

async function defaultCanAccess(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export async function diagnoseProviderSessions(
  options: DiscoveryOptions = {},
): Promise<ProviderDiagnostic[]> {
  const home = options.homeDirectory ?? homedir();
  const environment = options.environment ?? process.env;
  const platform = options.platform ?? process.platform;
  const canAccess = options.canAccess ?? defaultCanAccess;

  const diagnostics: ProviderDiagnostic[] = [];

  for (const path of codexAuthPaths(home, environment)) {
    diagnostics.push({
      provider: "codex",
      credential_source: path,
      available: await canAccess(path),
    });
  }

  for (const path of claudeCredentialPaths(home, environment)) {
    diagnostics.push({
      provider: "claude",
      credential_source: path,
      available: await canAccess(path),
    });
  }

  for (const path of grokAuthPaths(home, environment)) {
    diagnostics.push({
      provider: "grok",
      credential_source: path,
      available: await canAccess(path),
    });
  }

  for (const [id, spec] of Object.entries(API_KEY_SPECS)) {
    const resolved = await resolveApiKeyCredentials(spec, { environment });
    const envHint = spec.envKeys[0] ?? "API_KEY";
    diagnostics.push({
      provider: id as keyof typeof API_KEY_SPECS,
      credential_source: resolved?.source ?? `config|env:${envHint}`,
      available: resolved !== undefined,
    });
  }

  if (platform === "darwin") {
    let available = false;
    if (options.probeKeychain) {
      const payload = await readGenericPassword({
        service: CLAUDE_KEYCHAIN_SERVICE,
        platform,
      });
      available = payload !== undefined && payload.length > 0;
    }
    diagnostics.push({
      provider: "claude",
      available,
      credential_source: `macOS Keychain: ${CLAUDE_KEYCHAIN_SERVICE}`,
    });
  }

  return diagnostics;
}
