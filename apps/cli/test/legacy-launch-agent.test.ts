import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanupLegacyMacOSLaunchAgent } from "../src/relay/legacy-launch-agent.ts";

const uid = 501;
const serviceTarget = "gui/501/io.gotry.quotacli.relay";
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true })));
});

describe("legacy macOS LaunchAgent cleanup", () => {
  it("does nothing when the old plist is absent", async () => {
    const root = await temporaryDirectory();
    const runner = vi.fn(async () => ({ exitCode: 0 }));

    await cleanupLegacyMacOSLaunchAgent({
      plistPath: join(root, "Library", "LaunchAgents", "io.gotry.quotacli.relay.plist"),
      uid,
      runner,
    });

    expect(runner).not.toHaveBeenCalled();
  });

  it.each([0, 3])("bootouts and removes the old plist on exit %s", async (exitCode) => {
    const root = await temporaryDirectory();
    const directory = join(root, "Library", "LaunchAgents");
    const plistPath = join(directory, "io.gotry.quotacli.relay.plist");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(plistPath, "synthetic plist", { mode: 0o600 });
    const runner = vi.fn(async () => ({ exitCode }));

    await cleanupLegacyMacOSLaunchAgent({ plistPath, uid, runner });

    expect(runner).toHaveBeenCalledWith("/bin/launchctl", ["bootout", serviceTarget]);
    await expect(lstat(plistPath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("retains the plist when launchctl fails", async () => {
    const root = await temporaryDirectory();
    const directory = join(root, "LaunchAgents");
    const plistPath = join(directory, "io.gotry.quotacli.relay.plist");
    await mkdir(directory, { mode: 0o700 });
    await writeFile(plistPath, "synthetic plist", { mode: 0o600 });

    await expect(
      cleanupLegacyMacOSLaunchAgent({
        plistPath,
        uid,
        runner: async () => ({ exitCode: 1 }),
      }),
    ).rejects.toThrow("QuotaCLI could not remove the legacy background task.");

    expect(await readFile(plistPath, "utf8")).toBe("synthetic plist");
  });

  it("rejects a symlink plist without touching its target", async () => {
    const root = await temporaryDirectory();
    const directory = join(root, "LaunchAgents");
    const target = join(root, "target.plist");
    const plistPath = join(directory, "io.gotry.quotacli.relay.plist");
    await mkdir(directory, { mode: 0o700 });
    await writeFile(target, "target", { mode: 0o600 });
    await symlink(target, plistPath);
    const runner = vi.fn(async () => ({ exitCode: 0 }));

    await expect(cleanupLegacyMacOSLaunchAgent({ plistPath, uid, runner })).rejects.toThrow(
      "QuotaCLI could not remove the legacy background task.",
    );

    expect(runner).not.toHaveBeenCalled();
    expect(await readFile(target, "utf8")).toBe("target");
  });
});

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "quotacli-legacy-launch-agent-"));
  temporaryDirectories.push(directory);
  return directory;
}
