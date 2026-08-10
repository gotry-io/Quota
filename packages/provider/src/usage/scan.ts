import type { BillingAgent } from "@gotry-io/quota-protocol";
import { scanClaudeUsage } from "../providers/claude/usage.ts";
import { scanCodexUsage } from "../providers/codex/usage.ts";
import { scanGrokUsage } from "../providers/grok/usage.ts";
import { scanOpenCodeUsage } from "../providers/opencode/usage.ts";
import { scanPiUsage } from "../providers/pi/usage.ts";
import type { UsageScanOptions, UsageScanResult } from "./contracts.ts";

export async function scanLocalUsage(
  agent: BillingAgent,
  options: UsageScanOptions,
): Promise<UsageScanResult> {
  switch (agent) {
    case "codex":
      return await scanCodexUsage(options);
    case "claude_code":
      return await scanClaudeUsage(options);
    case "grok":
      return await scanGrokUsage(options);
    case "opencode":
      return await scanOpenCodeUsage(options);
    case "pi":
      return await scanPiUsage(options);
  }
}
