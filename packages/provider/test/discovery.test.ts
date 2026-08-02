import { describe, expect, it } from "vitest";
import { diagnoseProviderSessions } from "../src/discovery.ts";

describe("provider session discovery", () => {
  it("honors CODEX_HOME without reading credential contents", async () => {
    const visited: string[] = [];
    const diagnostics = await diagnoseProviderSessions({
      homeDirectory: "/home/quota",
      environment: { CODEX_HOME: "/sessions/codex" },
      platform: "linux",
      canAccess: async (path) => {
        visited.push(path);
        return path === "/sessions/codex/auth.json";
      },
    });

    expect(visited).toContain("/sessions/codex/auth.json");
    expect(diagnostics.find((item) => item.provider === "codex")?.available).toBe(true);
  });

  it("honors GROK_HOME and Claude config roots", async () => {
    const diagnostics = await diagnoseProviderSessions({
      homeDirectory: "/home/quota",
      environment: {
        GROK_HOME: "/sessions/grok",
        CLAUDE_CONFIG_DIR: "/sessions/claude",
      },
      platform: "linux",
      canAccess: async (path) =>
        path === "/sessions/grok/auth.json" || path === "/sessions/claude/.credentials.json",
    });

    expect(
      diagnostics.find((item) => item.credential_source === "/sessions/grok/auth.json")?.available,
    ).toBe(true);
    expect(
      diagnostics.find((item) => item.credential_source === "/sessions/claude/.credentials.json")
        ?.available,
    ).toBe(true);
  });
});
