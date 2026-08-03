import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import packageMetadata from "../package.json" with { type: "json" };

const { collectQuotaReport, diagnoseProviderSessions } = vi.hoisted(() => ({
  collectQuotaReport: vi.fn(async (options: { providers?: "all" | string[] }) => {
    const providers =
      options.providers === undefined || options.providers === "all"
        ? ["codex", "claude", "grok"]
        : options.providers;
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
          provider: provider as "codex" | "claude" | "grok",
          account: { fingerprint: `${provider}-fp`, plan: "plus" },
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
  }),
  diagnoseProviderSessions: vi.fn(async () => []),
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

  return {
    stdout,
    stderr,
    output: {
      stdout: (message: string) => stdout.push(message),
      stderr: (message: string) => stderr.push(message),
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

  it("probes Keychain during doctor diagnostics", async () => {
    const capture = captureOutput();
    const code = await runCli(["doctor"], capture.output);

    expect(code).toBe(0);
    expect(diagnoseProviderSessions).toHaveBeenCalledWith({ probeKeychain: true });
  });

  it("lists the initial providers", async () => {
    const capture = captureOutput();
    const code = await runCli(["providers"], capture.output);

    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("codex");
    expect(capture.stdout.join("\n")).toContain("claude");
    expect(capture.stdout.join("\n")).toContain("grok");
  });

  it("returns a usage error for an unknown command", async () => {
    const capture = captureOutput();
    const code = await runCli(["unknown"], capture.output);

    expect(code).toBe(2);
    expect(capture.stderr[0]).toContain("Unknown command");
  });

  it("renders quota json with partial success and exit code 1", async () => {
    const capture = captureOutput();
    const code = await runCli(
      ["quota", "--provider", "all", "--format", "json", "--pretty"],
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
    ]);
    expect(payload.results[1].outcome).toBe("auth_required");
    expect(JSON.stringify(payload)).not.toMatch(/Bearer |eyJ[a-zA-Z0-9]/i);
    expect(collectQuotaReport).toHaveBeenLastCalledWith(
      expect.objectContaining({ clientVersion: packageMetadata.version }),
    );
  });

  it("rejects invalid provider values with exit code 2", async () => {
    const capture = captureOutput();
    const code = await runCli(["quota", "--provider", "nope"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toContain("Invalid --provider");
  });

  it("includes quota in help text", async () => {
    const capture = captureOutput();
    const code = await runCli(["help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli quota");
    expect(capture.stdout.join("\n")).toContain("quotacli edge report");
    expect(capture.stdout.join("\n")).toContain("quotacli edge start");
    expect(capture.stdout.join("\n")).toContain("quotacli edge status");
    expect(capture.stdout.join("\n")).toContain("quotacli edge stop");
  });

  it("returns quota help successfully", async () => {
    const capture = captureOutput();
    const code = await runCli(["quota", "--help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli quota");
    expect(capture.stderr).toHaveLength(0);
  });

  it("routes edge help without starting pairing", async () => {
    const capture = captureOutput();
    const code = await runCli(["edge", "--help"], capture.output);
    expect(code).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli edge pair");
    expect(capture.stdout.join("\n")).toContain("quotacli edge start");
    expect(capture.stderr).toHaveLength(0);
  });

  it("routes unknown edge commands to an edge usage error", async () => {
    const capture = captureOutput();
    const code = await runCli(["edge", "unknown"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toContain("Unknown edge command");
  });
});
