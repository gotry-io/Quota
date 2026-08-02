import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { createFetchTransport, readJsonObject } from "../src/runtime/http.ts";
import { JsonRpcClient, resolveExecutable } from "../src/runtime/process.ts";

describe("provider runtime safety", () => {
  it("rejects redirects for authenticated provider requests", async () => {
    const fetchImpl = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      expect(init?.redirect).toBe("error");
      return new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const transport = createFetchTransport(fetchImpl as typeof fetch);

    await expect(
      transport({
        url: "https://example.invalid/fixed",
        headers: { Authorization: "Bearer fixture" },
      }),
    ).resolves.toMatchObject({ status: 200 });
  });

  it("preserves non-success status when the response body is not JSON", async () => {
    const result = await readJsonObject(
      async () => ({
        status: 401,
        headers: new Headers({ "content-type": "text/html" }),
        bodyText: "<html>not json</html>",
      }),
      { url: "https://example.invalid/fixed" },
    );

    expect(result.status).toBe(401);
    expect(result.json).toBeNull();
  });

  it("does not start an RPC subprocess for an already-aborted signal", async () => {
    const controller = new AbortController();
    controller.abort();
    const client = new JsonRpcClient({
      executable: "/definitely/not/a/real/executable",
      args: [],
      initializeTimeoutMs: 10,
      requestTimeoutMs: 10,
      signal: controller.signal,
    });

    await expect(client.start()).rejects.toMatchObject({
      category: "unavailable",
      message: "RPC cancelled.",
    });
  });

  it.skipIf(process.platform === "win32")(
    "requires execute permission when resolving provider CLIs",
    async () => {
      await withTemporaryExecutable("#!/bin/sh\nexit 0\n", async (executable, directory) => {
        await chmod(executable, 0o644);
        await expect(
          resolveExecutable("fixture-provider", { PATH: directory }),
        ).resolves.toBeUndefined();

        await chmod(executable, 0o755);
        await expect(resolveExecutable("fixture-provider", { PATH: directory })).resolves.toBe(
          executable,
        );
      });
    },
  );

  it.skipIf(process.platform === "win32")(
    "ignores malformed RPC noise before a valid response",
    async () => {
      await withTemporaryExecutable(
        '#!/bin/sh\nIFS= read -r request\nprintf \'%s\\n\' \'not-json\' \'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\'\n',
        async (executable) => {
          const client = new JsonRpcClient({
            executable,
            args: [],
            initializeTimeoutMs: 1_000,
            requestTimeoutMs: 1_000,
          });
          try {
            await expect(client.request({ method: "fixture/read" })).resolves.toEqual({ ok: true });
          } finally {
            client.shutdown();
          }
        },
      );
    },
  );

  it.skipIf(process.platform === "win32")(
    "force-kills an RPC child that ignores the timeout signal",
    async () => {
      await withTemporaryExecutable(
        "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$1\"\nIFS= read -r request\nwhile :; do :; done\n",
        async (executable, directory) => {
          const marker = join(directory, "pid");
          const client = new JsonRpcClient({
            executable,
            args: [marker],
            initializeTimeoutMs: 30,
            requestTimeoutMs: 30,
          });
          try {
            await client.start();
            await expectFile(marker);
            await expect(client.request({ method: "fixture/hang" })).rejects.toMatchObject({
              category: "unavailable",
            });
            const pid = Number(await readFile(marker, "utf8"));
            expect(Number.isSafeInteger(pid)).toBe(true);
            await expectProcessExit(pid);
          } finally {
            client.shutdown();
          }
        },
      );
    },
  );
});

async function withTemporaryExecutable(
  contents: string,
  action: (executable: string, directory: string) => Promise<void>,
): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "quota-provider-runtime-"));
  const executable = join(directory, "fixture-provider");
  try {
    await writeFile(executable, contents, { mode: 0o755 });
    await action(executable, directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function expectProcessExit(pid: number): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") {
        return;
      }
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`RPC child ${pid} did not exit after forced termination.`);
}

async function expectFile(path: string): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (Date.now() < deadline) {
    try {
      await readFile(path, "utf8");
      return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw error;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Expected subprocess marker ${path} was not created.`);
}
