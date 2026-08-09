import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import packageMetadata from "../package.json" with { type: "json" };

const { collectQuotaReport, diagnoseProviderSessions } = vi.hoisted(() => ({
  collectQuotaReport: vi.fn(
    async (options: {
      providers?: "all" | string[];
      onProviderProgress?: (provider: string, state: "collecting" | "done") => void;
    }) => {
      const providers =
        options.providers === undefined || options.providers === "all"
          ? ["codex", "claude", "grok", "openrouter", "deepseek", "kimi", "litellm"]
          : options.providers;
      for (const provider of providers) {
        options.onProviderProgress?.(provider, "collecting");
      }
      for (const provider of providers) {
        options.onProviderProgress?.(provider, "done");
      }
      return {
        schema_version: 1 as const,
        captured_at: "2026-08-02T12:00:00Z",
        results: providers.map((provider, index) => {
          if (provider === "claude") {
            return {
              provider,
              outcome: "auth_required" as const,
              snapshots: [],
              message: "Claude credentials not found. Run `claude auth login`.",
            };
          }
          const snapshot: QuotaSnapshot = {
            provider: provider as
              | "codex"
              | "claude"
              | "grok"
              | "openrouter"
              | "deepseek"
              | "kimi"
              | "litellm",
            account: { fingerprint: `${provider}-fp`, fingerprint_scope: "source", plan: "plus" },
            windows: [
              {
                id: "five_hour",
                title: "5 hour",
                used_percent: 25 + index,
                resets_at: "2026-08-02T17:00:00Z",
              },
            ],
            source: `${provider}_source`,
            status: "available",
            observed_at: "2026-08-02T12:00:00Z",
          };
          return {
            provider,
            outcome: "success" as const,
            snapshots: [snapshot],
            source: snapshot.source,
          };
        }),
      };
    },
  ),
  diagnoseProviderSessions: vi.fn(async () => [
    {
      provider: "codex" as const,
      available: true,
      credential_source: "~/.codex/auth.json",
    },
  ]),
}));

vi.mock("@gotry-io/quota-provider", async () => {
  const actual = await vi.importActual<typeof import("@gotry-io/quota-provider")>(
    "@gotry-io/quota-provider",
  );
  return {
    ...actual,
    diagnoseProviderSessions,
    collectQuotaReport,
  };
});

import { QUOTA_CLI_VERSION, runCli } from "../src/commands.ts";

function captureOutput() {
  const stdout: string[] = [];
  const stderr: string[] = [];
  const progress: Array<string | undefined> = [];

  return {
    stdout,
    stderr,
    progress,
    output: {
      stdout: (message: string) => stdout.push(message),
      stderr: (message: string) => stderr.push(message),
      progress: (message?: string) => progress.push(message),
    },
  };
}

describe("QuotaCLI", () => {
  it("derives runtime and npm command metadata from package.json", async () => {
    expect(QUOTA_CLI_VERSION).toBe(packageMetadata.version);
    expect(packageMetadata.bin.quotacli).toBe("dist/npm/quotacli.js");

    const capture = captureOutput();
    expect(await runCli(["version"], capture.output)).toBe(0);
    expect(capture.stdout).toEqual([`QuotaCLI ${packageMetadata.version}`]);
  });

  it("returns a usage error for an unknown command", async () => {
    const capture = captureOutput();
    const code = await runCli(["unknown"], capture.output);

    expect(code).toBe(2);
    expect(capture.stderr[0]).toContain("Unknown command");
  });

  it("renders status json with partial success and exit code 1", async () => {
    diagnoseProviderSessions.mockClear();
    const capture = captureOutput();
    const code = await runCli(
      ["status", "--provider", "all", "--format", "json", "--pretty"],
      capture.output,
      { isTty: false },
    );

    expect(code).toBe(1);
    const payload = JSON.parse(capture.stdout.join(""));
    expect(payload.schema_version).toBe(1);
    expect(payload.results.map((result: { provider: string }) => result.provider)).toEqual([
      "codex",
      "claude",
      "grok",
      "openrouter",
      "deepseek",
      "kimi",
      "litellm",
    ]);
    expect(payload.results[1].outcome).toBe("auth_required");
    expect(JSON.stringify(payload)).not.toMatch(/Bearer |eyJ[a-zA-Z0-9]/i);
    expect(collectQuotaReport).toHaveBeenLastCalledWith(
      expect.objectContaining({ clientVersion: packageMetadata.version }),
    );
    expect(diagnoseProviderSessions).not.toHaveBeenCalled();
    expect(capture.progress).toHaveLength(0);
  });

  it("defaults to discovered providers and reports TTY collection progress", async () => {
    const capture = captureOutput();
    const code = await runCli(["status", "--format", "text"], capture.output, {
      isTty: true,
      color: false,
    });

    expect(code).toBe(0);
    expect(collectQuotaReport).toHaveBeenLastCalledWith(
      expect.objectContaining({ providers: ["codex"] }),
    );
    expect(capture.stdout.join("\n")).toContain("Codex");
    expect(capture.stdout.join("\n")).not.toContain("Claude Code");
    expect(capture.progress).toContain("Discovering configured providers…");
    expect(capture.progress).toContain("Collecting quota 0/1 · Codex started");
    expect(capture.progress).toContain("Collecting quota 1/1 · Codex complete");
    expect(capture.progress.at(-1)).toBeUndefined();
  });

  it("does not emit progress when stderr is redirected", async () => {
    const capture = captureOutput();
    const code = await runCli(["status", "--format", "text"], capture.output, {
      isTty: true,
      progressIsTty: false,
      color: false,
    });

    expect(code).toBe(0);
    expect(capture.progress).toHaveLength(0);
    expect(capture.stdout.join("\n")).toContain("Codex");
  });

  it("deduplicates explicit providers before collection and progress", async () => {
    const capture = captureOutput();
    const code = await runCli(
      ["status", "--provider", "codex,codex", "--format", "text"],
      capture.output,
      { isTty: true, color: false },
    );

    expect(code).toBe(0);
    expect(collectQuotaReport).toHaveBeenLastCalledWith(
      expect.objectContaining({ providers: ["codex"] }),
    );
    expect(capture.progress).toContain("Collecting quota 1/1 · Codex complete");
    expect(capture.progress.join("\n")).not.toContain("/2");
  });

  it("returns exit code 1 with setup guidance when no provider is configured", async () => {
    diagnoseProviderSessions.mockResolvedValueOnce([]);
    const capture = captureOutput();
    const code = await runCli(["status", "--format", "text"], capture.output, {
      isTty: true,
      color: false,
    });

    expect(code).toBe(1);
    expect(collectQuotaReport).toHaveBeenLastCalledWith(expect.objectContaining({ providers: [] }));
    expect(capture.stdout.join("\n")).toContain("No configured providers found");
    expect(capture.stdout.join("\n")).toContain("quotacli doctor");
    expect(capture.progress.at(-1)).toBeUndefined();
  });

  it("fails closed without leaking discovery errors", async () => {
    diagnoseProviderSessions.mockRejectedValueOnce(new Error("secret provider path"));
    const capture = captureOutput();
    const code = await runCli(["status", "--format", "text"], capture.output, {
      isTty: true,
      color: false,
    });

    expect(code).toBe(1);
    expect(capture.stdout).toHaveLength(0);
    expect(capture.stderr.join("\n")).toContain("quotacli doctor");
    expect(capture.stderr.join("\n")).not.toContain("secret provider path");
    expect(capture.progress.at(-1)).toBeUndefined();
  });

  it("renders auth failures as explicit sign-in recovery copy", async () => {
    const capture = captureOutput();
    const code = await runCli(["status", "--provider", "all", "--format", "text"], capture.output, {
      isTty: true,
    });

    expect(code).toBe(1);
    const text = capture.stdout.join("");
    expect(text).toContain("Claude Code");
    expect(text).toContain("● Sign-in required");
    expect(text).toContain("Run `claude auth login`");
    expect(text).toContain("plus");
    expect(text).toContain("████");
    expect(text).toContain("────────────────");
    expect(text).not.toContain("auth_required —");
  });

  it("rejects invalid provider values with exit code 2", async () => {
    const capture = captureOutput();
    const code = await runCli(["status", "--provider", "nope"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toContain("Invalid --provider");
  });

  it("includes the simplified command surface in help text", async () => {
    const capture = captureOutput();
    const code = await runCli(["help"], capture.output);
    expect(code).toBe(0);
    const text = capture.stdout.join("\n");
    expect(text).toContain("quotacli status [--provider");
    expect(text).toContain("quotacli doctor");
    expect(text).toContain("quotacli relay pair");
    expect(text).toContain("quotacli relay push");
    expect(text).toContain("quotacli relay unpair");
    expect(text).not.toContain("quotacli edge");
    expect(text).not.toContain("quotacli quota");
    expect(text).not.toContain("quotacli providers");
    expect(text).not.toContain("relay start");
    expect(text).not.toContain("relay stop");
    expect(text).not.toContain("relay report");
  });

  it("returns status help successfully", async () => {
    const capture = captureOutput();
    const code = await runCli(["status", "--help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli status [--provider");
    expect(capture.stderr).toHaveLength(0);
  });

  it("returns doctor help without probing local state", async () => {
    diagnoseProviderSessions.mockClear();
    const capture = captureOutput();
    const code = await runCli(["doctor", "--help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli doctor");
    expect(diagnoseProviderSessions).not.toHaveBeenCalled();
  });

  it("routes relay help without starting pairing", async () => {
    const capture = captureOutput();
    const code = await runCli(["relay", "--help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli relay pair");
    expect(capture.stdout.join("\n")).toContain("quotacli relay push");
    expect(capture.stderr).toHaveLength(0);
  });

  it("routes unknown relay commands to a relay usage error", async () => {
    const capture = captureOutput();
    const code = await runCli(["relay", "unknown"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toContain("Unknown relay command");
  });

  it("rejects removed top-level commands", async () => {
    for (const command of ["quota", "providers", "edge"]) {
      const capture = captureOutput();
      expect(await runCli([command], capture.output)).toBe(2);
      expect(capture.stderr.join("\n")).toContain("Unknown command");
    }
  });
});
