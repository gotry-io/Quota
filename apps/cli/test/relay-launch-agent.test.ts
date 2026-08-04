import type { Stats } from "node:fs";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  LAUNCHCTL_PATH,
  type LaunchAgentFileSystem,
  type LaunchctlRunner,
  MacOSLaunchAgent,
  RELAY_LAUNCH_AGENT_LABEL,
  renderLaunchAgentPlist,
  resolveRelayPushProgramArguments,
} from "../src/relay/launch-agent.ts";

const temporaryDirectories: string[] = [];
const uid = 501;
const domainTarget = `gui/${uid}`;
const serviceTarget = `${domainTarget}/${RELAY_LAUNCH_AGENT_LABEL}`;

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("relay push invocation resolution", () => {
  it("uses the current executable directly for a standalone binary", () => {
    expect(
      resolveRelayPushProgramArguments({
        execPath: "/opt/quota/quotacli",
        argv1: "/opt/quota/quotacli",
        cwd: "/tmp",
      }),
    ).toEqual(["/opt/quota/quotacli", "relay", "push"]);
  });

  it("recognizes Bun's compiled virtual main path", () => {
    expect(
      resolveRelayPushProgramArguments({
        execPath: "/private/tmp/quota-argv-probe",
        argv1: "/$bunfs/root/quota-argv-probe",
        cwd: "/private/tmp",
      }),
    ).toEqual(["/private/tmp/quota-argv-probe", "relay", "push"]);
  });

  it("uses an installed npm CLI entry directly so Background Items show quotacli", () => {
    expect(
      resolveRelayPushProgramArguments({
        execPath: "/usr/local/bin/node",
        argv1: "/opt/homebrew/bin/quotacli",
        cwd: "/tmp",
      }),
    ).toEqual(["/opt/homebrew/bin/quotacli", "relay", "push"]);
  });

  it("uses an absolute quotacli.js package entry directly", () => {
    expect(
      resolveRelayPushProgramArguments({
        execPath: "/usr/local/bin/node",
        argv1: "/opt/quota/quotacli.js",
        cwd: "/tmp",
      }),
    ).toEqual(["/opt/quota/quotacli.js", "relay", "push"]);
  });

  it("resolves a relative development entry from an absolute cwd", () => {
    expect(
      resolveRelayPushProgramArguments({
        execPath: "/usr/local/bin/bun",
        argv1: "src/main.ts",
        cwd: "/opt/quota/apps/cli",
      }),
    ).toEqual(["/usr/local/bin/bun", "/opt/quota/apps/cli/src/main.ts", "relay", "push"]);
  });

  it.each([
    { execPath: "node", argv1: "/opt/quota/quotacli.js", cwd: "/tmp" },
    { execPath: "/usr/bin/node", cwd: "/tmp" },
    { execPath: "/usr/bin/node", argv1: "quotacli.js", cwd: "relative" },
  ])("rejects unresolved invocation paths %#", (invocation) => {
    expect(() => resolveRelayPushProgramArguments(invocation)).toThrow(
      /^QuotaCLI could not resolve/,
    );
  });
});

describe("LaunchAgent plist", () => {
  it("escapes arguments and configures RunAtLoad plus a push every 300 seconds", () => {
    const plist = renderLaunchAgentPlist([
      "/opt/a&b/node",
      "/opt/<quota>/main\"'.js",
      "relay",
      "push",
    ]);

    expect(plist).toContain(`<string>${RELAY_LAUNCH_AGENT_LABEL}</string>`);
    expect(plist).toContain("<string>/opt/a&amp;b/node</string>");
    expect(plist).toContain("<string>/opt/&lt;quota&gt;/main&quot;&apos;.js</string>");
    // RunAtLoad covers login/reboot. pair also does one foreground push for immediate
    // owner visibility; the extra load-time push after pair is acceptable.
    expect(plist).toContain("<key>RunAtLoad</key>\n  <true/>");
    expect(plist).toContain("<key>StartInterval</key>\n  <integer>300</integer>");
    expect(plist.match(/<string>\/dev\/null<\/string>/g)).toHaveLength(2);
    expect(plist).not.toContain("EnvironmentVariables");
  });

  it("inherits only allowlisted nonempty environment values", () => {
    const plist = renderLaunchAgentPlist(["/opt/quotacli", "relay", "push"], {
      PATH: "/opt/bin:/usr/bin",
      XDG_CONFIG_HOME: "/Users/test/config&a",
      CODEX_HOME: "/Users/test/.codex",
      CLAUDE_CONFIG_DIR: "/Users/test/<claude>",
      GROK_HOME: "/Users/test/.grok",
      CODEX_CLI_PATH: "/opt/bin/codex",
      CLAUDE_CLI_PATH: "/opt/bin/claude",
      GROK_CLI_PATH: "/opt/bin/grok",
      EMPTY_VALUE: "",
      SYNTHETIC_SECRET_TOKEN: "must-never-appear",
    });

    for (const key of [
      "PATH",
      "XDG_CONFIG_HOME",
      "CODEX_HOME",
      "CLAUDE_CONFIG_DIR",
      "GROK_HOME",
      "CODEX_CLI_PATH",
      "CLAUDE_CLI_PATH",
      "GROK_CLI_PATH",
    ]) {
      expect(plist).toContain(`<key>${key}</key>`);
    }
    expect(plist).toContain("/Users/test/config&amp;a");
    expect(plist).toContain("/Users/test/&lt;claude&gt;");
    expect(plist).not.toContain("SYNTHETIC_SECRET_TOKEN");
    expect(plist).not.toContain("must-never-appear");
  });

  it("does not inherit a relative XDG_CONFIG_HOME", () => {
    const plist = renderLaunchAgentPlist(["/opt/quotacli", "relay", "push"], {
      XDG_CONFIG_HOME: "relative/config",
    });

    expect(plist).not.toContain("EnvironmentVariables");
    expect(plist).not.toContain("relative/config");
  });
});

describe("macOS LaunchAgent lifecycle", () => {
  it("bootouts, writes a private plist atomically, then bootstraps", async () => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "Library", "LaunchAgents", "relay.plist");
    const { runner, calls } = runnerWithExitCodes(3, 0);
    const service = launchAgent(plistPath, runner, {
      XDG_CONFIG_HOME: "/private/config",
      SYNTHETIC_SECRET_TOKEN: "must-not-be-written",
    });

    await service.start();

    expect(calls).toEqual([
      { executable: LAUNCHCTL_PATH, args: ["bootout", serviceTarget] },
      {
        executable: LAUNCHCTL_PATH,
        args: ["bootstrap", domainTarget, plistPath],
      },
    ]);
    const contents = await readFile(plistPath, "utf8");
    expect(contents).toContain("<string>/opt/quota/quotacli.js</string>");
    expect(contents).not.toContain("<string>/usr/local/bin/node</string>");
    expect(contents).toContain("<string>/private/config</string>");
    expect(contents).not.toContain("must-not-be-written");
    expect((await lstat(plistPath)).mode & 0o777).toBe(0o600);
    expect((await lstat(join(root, "Library", "LaunchAgents"))).mode & 0o777).toBe(0o700);
  });

  it("accepts an existing loaded service during restart", async () => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "LaunchAgents", "relay.plist");
    const { runner, calls } = runnerWithExitCodes(0, 0);

    await launchAgent(plistPath, runner).start();

    expect(calls.map((call) => call.args[0])).toEqual(["bootout", "bootstrap"]);
  });

  it("has zero runner and filesystem side effects for an invalid invocation", async () => {
    const runner = vi.fn<LaunchctlRunner>(async () => ({ exitCode: 0 }));
    const filesystem = unusedFileSystem();
    const service = new MacOSLaunchAgent({
      plistPath: "/tmp/io.gotry.quotacli.relay.plist",
      uid,
      invocation: { execPath: "relative", argv1: "main.js", cwd: "/tmp" },
      runner,
      filesystem,
    });

    await expect(service.start()).rejects.toThrow(
      "QuotaCLI could not resolve its executable path.",
    );
    expect(runner).not.toHaveBeenCalled();
    for (const operation of Object.values(filesystem)) {
      expect(operation).not.toHaveBeenCalled();
    }
  });

  it("cleans up the new plist when bootstrap fails", async () => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "LaunchAgents", "relay.plist");
    const { runner, calls } = runnerWithExitCodes(3, 1, 0);
    const service = launchAgent(plistPath, runner);

    await expect(service.start()).rejects.toThrow("QuotaCLI could not load the LaunchAgent.");
    expect(calls.map((call) => call.args[0])).toEqual(["bootout", "bootstrap", "bootout"]);
    await expect(lstat(plistPath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not write when the initial bootout fails", async () => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "LaunchAgents", "relay.plist");
    const { runner, calls } = runnerWithExitCodes(1);

    await expect(launchAgent(plistPath, runner).start()).rejects.toThrow(
      "QuotaCLI could not unload the existing LaunchAgent.",
    );
    expect(calls).toHaveLength(1);
    await expect(lstat(plistPath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it.each([
    { exitCode: 0, expected: "loaded" as const },
    { exitCode: 113, expected: "stopped" as const },
  ])("maps launchctl print exit $exitCode to $expected", async ({ exitCode, expected }) => {
    const root = await temporaryDirectory();
    const { runner, calls } = runnerWithExitCodes(exitCode);
    const service = launchAgent(join(root, "relay.plist"), runner);

    await expect(service.status()).resolves.toBe(expected);
    expect(calls).toEqual([{ executable: LAUNCHCTL_PATH, args: ["print", serviceTarget] }]);
  });

  it("turns unexpected launchctl print exits into a fixed error", async () => {
    const root = await temporaryDirectory();
    const { runner } = runnerWithExitCodes(42);

    await expect(launchAgent(join(root, "relay.plist"), runner).status()).rejects.toThrow(
      "QuotaCLI could not inspect the LaunchAgent.",
    );
  });

  it.each([0, 3])("removes the plist when bootout exits %s", async (exitCode) => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "LaunchAgents", "relay.plist");
    await mkdir(join(root, "LaunchAgents"), { recursive: true, mode: 0o700 });
    await writeFile(plistPath, "synthetic plist", { mode: 0o600 });
    const { runner } = runnerWithExitCodes(exitCode);

    await launchAgent(plistPath, runner).stop();

    await expect(lstat(plistPath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("leaves the plist in place when bootout fails", async () => {
    const root = await temporaryDirectory();
    const plistPath = join(root, "LaunchAgents", "relay.plist");
    await mkdir(join(root, "LaunchAgents"), { recursive: true, mode: 0o700 });
    await writeFile(plistPath, "synthetic plist", { mode: 0o600 });
    const { runner } = runnerWithExitCodes(1);

    await expect(launchAgent(plistPath, runner).stop()).rejects.toThrow(
      "QuotaCLI could not unload the LaunchAgent.",
    );
    expect(await readFile(plistPath, "utf8")).toBe("synthetic plist");
  });

  it("rejects a symlink LaunchAgent directory", async () => {
    const root = await temporaryDirectory();
    const target = join(root, "target");
    const link = join(root, "LaunchAgents");
    await mkdir(target, { mode: 0o700 });
    await symlink(target, link);
    const { runner, calls } = runnerWithExitCodes(3);

    await expect(launchAgent(join(link, "relay.plist"), runner).start()).rejects.toThrow(
      "The LaunchAgent directory is invalid.",
    );
    expect(calls).toEqual([]);
    await expect(lstat(join(target, "relay.plist"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects a symlink LaunchAgent file", async () => {
    const root = await temporaryDirectory();
    const directory = join(root, "LaunchAgents");
    const target = join(root, "target.plist");
    const plistPath = join(directory, "relay.plist");
    await mkdir(directory, { mode: 0o700 });
    await writeFile(target, "target", { mode: 0o600 });
    await symlink(target, plistPath);
    const { runner, calls } = runnerWithExitCodes(3);

    await expect(launchAgent(plistPath, runner).start()).rejects.toThrow(
      "The LaunchAgent file is invalid.",
    );
    expect(calls).toEqual([]);
    expect(await readFile(target, "utf8")).toBe("target");
  });
});

function launchAgent(
  plistPath: string,
  runner: LaunchctlRunner,
  environment: NodeJS.ProcessEnv = {},
): MacOSLaunchAgent {
  return new MacOSLaunchAgent({
    plistPath,
    uid,
    invocation: {
      execPath: "/usr/local/bin/node",
      argv1: "/opt/quota/quotacli.js",
      cwd: "/opt/quota",
    },
    environment,
    runner,
  });
}

function runnerWithExitCodes(...exitCodes: number[]): {
  runner: LaunchctlRunner;
  calls: Array<{ executable: string; args: string[] }>;
} {
  const calls: Array<{ executable: string; args: string[] }> = [];
  const runner: LaunchctlRunner = async (executable, args) => {
    calls.push({ executable, args: [...args] });
    const exitCode = exitCodes.shift();
    if (exitCode === undefined) {
      throw new Error("Unexpected launchctl call");
    }
    return { exitCode };
  };
  return { runner, calls };
}

function unusedFileSystem(): LaunchAgentFileSystem & Record<string, ReturnType<typeof vi.fn>> {
  return {
    chmod: vi.fn(async () => undefined),
    lstat: vi.fn(async () => ({}) as Stats),
    mkdir: vi.fn(async () => undefined),
    open: vi.fn(async () => ({
      writeFile: async () => undefined,
      sync: async () => undefined,
      close: async () => undefined,
    })),
    rename: vi.fn(async () => undefined),
    unlink: vi.fn(async () => undefined),
  };
}

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "quotacli-launch-agent-"));
  temporaryDirectories.push(directory);
  return directory;
}
