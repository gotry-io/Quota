import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/commands.ts";
import * as stdinModule from "../src/config/stdin.ts";

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

describe("quotacli config", () => {
  const previousXdg = process.env.XDG_CONFIG_HOME;

  afterEach(() => {
    if (previousXdg === undefined) {
      delete process.env.XDG_CONFIG_HOME;
    } else {
      process.env.XDG_CONFIG_HOME = previousXdg;
    }
    vi.restoreAllMocks();
  });

  it("rejects plaintext --api-key on argv", async () => {
    const capture = captureOutput();
    const code = await runCli(
      ["config", "set", "openrouter", "--api-key", "sk-or-v1-nope"],
      capture.output,
    );
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toMatch(/Do not pass API keys on the command line/);
  });

  it("requires --api-key-stdin", async () => {
    const capture = captureOutput();
    const code = await runCli(["config", "set", "openrouter"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toMatch(/--api-key-stdin/);
  });

  it("sets gets lists and unsets openrouter without printing the full key", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-cli-config-"));
    process.env.XDG_CONFIG_HOME = root;

    const secret = "sk-or-v1-super-secret-fixture-key";
    vi.spyOn(stdinModule, "readStdinText").mockResolvedValue(secret);

    const setCapture = captureOutput();
    const setCode = await runCli(
      ["config", "set", "openrouter", "--api-key-stdin"],
      setCapture.output,
    );
    expect(setCode).toBe(0);
    expect(setCapture.stdout.join("\n")).toContain("Configured openrouter");
    expect(setCapture.stdout.join("\n")).toContain("···");
    expect(setCapture.stdout.join("\n")).not.toContain(secret);

    const file = await readFile(join(root, "quotacli", "providers.json"), "utf8");
    expect(file).toContain(secret);

    const getCapture = captureOutput();
    expect(await runCli(["config", "get", "openrouter"], getCapture.output)).toBe(0);
    expect(getCapture.stdout.join("\n")).toMatch(/openrouter: OpenRouter ···/);
    expect(getCapture.stdout.join("\n")).not.toContain(secret);

    const listCapture = captureOutput();
    expect(await runCli(["config", "list"], listCapture.output)).toBe(0);
    expect(listCapture.stdout.join("\n")).toContain("openrouter");
    expect(listCapture.stdout.join("\n")).not.toContain(secret);

    const unsetCapture = captureOutput();
    expect(await runCli(["config", "unset", "openrouter"], unsetCapture.output)).toBe(0);
    expect(unsetCapture.stdout.join("\n")).toContain("Removed openrouter");

    const getAfter = captureOutput();
    expect(await runCli(["config", "get", "openrouter"], getAfter.output)).toBe(0);
    expect(getAfter.stdout.join("\n")).toContain("not configured");
  });
});
