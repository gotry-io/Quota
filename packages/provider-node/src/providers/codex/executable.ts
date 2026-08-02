import { join } from "node:path";
import { resolveProviderExecutable } from "../../runtime/process.ts";

export async function resolveCodexExecutable(
  homeDirectory: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): Promise<string | undefined> {
  return await resolveProviderExecutable({
    name: "codex",
    overrideKey: "CODEX_CLI_PATH",
    environment,
    knownPaths: [
      join(homeDirectory, ".local", "bin", "codex"),
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      join(homeDirectory, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"),
      join(homeDirectory, "Applications", "Codex.app", "Contents", "Resources", "codex"),
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
    ],
  });
}
