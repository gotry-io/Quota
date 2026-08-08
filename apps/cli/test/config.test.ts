import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/commands.ts";
import * as promptModule from "../src/config/prompt.ts";

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

  it("prompts for the API key when set is interactive", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-cli-config-"));
    process.env.XDG_CONFIG_HOME = root;
    const secret = "sk-or-v1-prompted-secret-key";
    const prompt = vi.spyOn(promptModule, "promptLine").mockResolvedValue(secret);
    Object.defineProperty(process.stdin, "isTTY", { configurable: true, value: true });

    const capture = captureOutput();
    const code = await runCli(["config", "set", "openrouter"], capture.output);
    expect(code).toBe(0);
    expect(prompt).toHaveBeenCalledWith("OpenRouter API key: ", { secret: true });
    expect(capture.stdout.join("\n")).toContain("Configured openrouter");
    expect(capture.stdout.join("\n")).not.toContain(secret);
    const file = await readFile(join(root, "quotacli", "providers.json"), "utf8");
    expect(file).toContain(secret);
  });

  it("rejects bare set without a TTY", async () => {
    Object.defineProperty(process.stdin, "isTTY", { configurable: true, value: false });
    const capture = captureOutput();
    const code = await runCli(["config", "set", "openrouter"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toMatch(/No interactive terminal/);
  });

  it("sets gets lists and unsets openrouter without printing the full key", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-cli-config-"));
    process.env.XDG_CONFIG_HOME = root;

    const secret = "sk-or-v1-super-secret-fixture-key";
    Object.defineProperty(process.stdin, "isTTY", { configurable: true, value: true });
    vi.spyOn(promptModule, "promptLine").mockResolvedValue(secret);

    const setCapture = captureOutput();
    const setCode = await runCli(["config", "set", "openrouter"], setCapture.output);
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

  it("rejects the removed stdin option", async () => {
    const capture = captureOutput();
    const code = await runCli(["config", "set", "openrouter", "--api-key-stdin"], capture.output);
    expect(code).toBe(2);
    expect(capture.stderr.join("\n")).toContain("Unknown option: --api-key-stdin");
  });

  it("prompts for required base URL for litellm", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-cli-config-"));
    process.env.XDG_CONFIG_HOME = root;
    Object.defineProperty(process.stdin, "isTTY", { configurable: true, value: true });
    const secret = "sk-litellm-secret";
    const prompt = vi
      .spyOn(promptModule, "promptLine")
      .mockResolvedValueOnce(secret)
      .mockResolvedValueOnce("https://litellm.example.com");

    const capture = captureOutput();
    expect(await runCli(["config", "set", "litellm"], capture.output)).toBe(0);
    expect(prompt).toHaveBeenNthCalledWith(1, "LiteLLM API key: ", { secret: true });
    expect(prompt).toHaveBeenNthCalledWith(2, "LiteLLM base URL (required): ");
    const file = await readFile(join(root, "quotacli", "providers.json"), "utf8");
    expect(file).toContain(secret);
    expect(file).toContain("https://litellm.example.com");
  });

  it("rejects a fixed-provider base URL before reading the API key", async () => {
    Object.defineProperty(process.stdin, "isTTY", { configurable: true, value: true });
    const prompt = vi.spyOn(promptModule, "promptLine");
    const capture = captureOutput();

    expect(
      await runCli(
        ["config", "set", "openrouter", "--base-url", "https://proxy.example"],
        capture.output,
      ),
    ).toBe(2);
    expect(prompt).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("OpenRouter does not support --base-url");
  });
});
