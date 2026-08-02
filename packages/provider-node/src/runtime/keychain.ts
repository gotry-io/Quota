import { spawn } from "node:child_process";
import { KEYCHAIN_OUTPUT_LIMIT_BYTES, KEYCHAIN_READ_TIMEOUT_MS } from "./limits.ts";

const SECURITY_BIN = "/usr/bin/security";

export interface KeychainReadOptions {
  service: string;
  account?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
  platform?: NodeJS.Platform;
}

/**
 * Read-only macOS Keychain generic password lookup via absolute /usr/bin/security.
 * Never writes or deletes keychain items.
 */
export async function readGenericPassword(
  options: KeychainReadOptions,
): Promise<string | undefined> {
  const platform = options.platform ?? process.platform;
  if (platform !== "darwin") {
    return undefined;
  }
  if (options.signal?.aborted) {
    return undefined;
  }

  const args = ["find-generic-password", "-s", options.service, "-w"];
  if (options.account && options.account.length > 0) {
    args.push("-a", options.account);
  }

  return await new Promise<string | undefined>((resolve) => {
    const child = spawn(SECURITY_BIN, args, {
      stdio: ["ignore", "pipe", "pipe"],
      shell: false,
      windowsHide: true,
    });

    const chunks: Buffer[] = [];
    let capturedBytes = 0;
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onAbort = () => {
      terminateChild(child);
      finish(undefined);
    };
    const finish = (value: string | undefined) => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer) {
        clearTimeout(timer);
      }
      options.signal?.removeEventListener("abort", onAbort);
      resolve(value);
    };

    timer = setTimeout(() => {
      terminateChild(child);
      finish(undefined);
    }, options.timeoutMs ?? KEYCHAIN_READ_TIMEOUT_MS);

    if (options.signal) {
      options.signal.addEventListener("abort", onAbort, { once: true });
    }

    child.stdout.on("data", (chunk: Buffer) => {
      capturedBytes += chunk.byteLength;
      if (capturedBytes > KEYCHAIN_OUTPUT_LIMIT_BYTES) {
        terminateChild(child);
        finish(undefined);
        return;
      }
      chunks.push(chunk);
    });
    // Drain diagnostics without ever retaining or emitting them.
    child.stderr.resume();
    child.on("error", () => {
      finish(undefined);
    });
    child.on("close", (code) => {
      if (code !== 0) {
        finish(undefined);
        return;
      }
      const text = Buffer.concat(chunks)
        .toString("utf8")
        .replace(/\r?\n$/, "");
      finish(text.length > 0 ? text : undefined);
    });
  });
}

function terminateChild(child: ReturnType<typeof spawn>): void {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
    }
  }, 500).unref?.();
}
