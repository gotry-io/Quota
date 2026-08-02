import { access } from "node:fs/promises";
import { homedir } from "node:os";
import type { ProviderDiagnostic } from "@gotry-io/provider-core";
import { CLAUDE_KEYCHAIN_SERVICE } from "./providers/claude/credentials.ts";
import { claudeCredentialPaths } from "./providers/claude/credentials.ts";
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
      detail: "Codex auth file",
      available: await canAccess(path),
    });
  }

  for (const path of claudeCredentialPaths(home, environment)) {
    diagnostics.push({
      provider: "claude",
      credential_source: path,
      detail: "Claude Code credential file",
      available: await canAccess(path),
    });
  }

  for (const path of grokAuthPaths(home, environment)) {
    diagnostics.push({
      provider: "grok",
      credential_source: path,
      detail: "Grok auth file",
      available: await canAccess(path),
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
      detail: options.probeKeychain
        ? available
          ? "Keychain item present"
          : "Keychain item missing or unreadable"
        : "Keychain discovery is performed during quota collection",
    });
  }

  return diagnostics;
}
