import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { ProviderCollectionError } from "@gotry-io/provider-core";
import { JSON_RPC_STDERR_LIMIT_BYTES, JSON_RPC_STDOUT_LINE_LIMIT_BYTES } from "./limits.ts";
import { sanitizeMessage } from "./errors.ts";

export async function resolveExecutable(
  name: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): Promise<string | undefined> {
  if (name.includes("/") || name.includes("\\")) {
    if (await canExecute(name)) {
      return name;
    }
    return undefined;
  }

  const pathValue = environment.PATH ?? "";
  const parts = pathValue.split(delimiter).filter(Boolean);
  for (const part of parts) {
    const candidate = join(part, name);
    if (await canExecute(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

async function canExecute(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export interface JsonRpcClientOptions {
  executable: string;
  args: readonly string[];
  environment?: Readonly<Record<string, string | undefined>>;
  initializeTimeoutMs: number;
  requestTimeoutMs: number;
  signal?: AbortSignal;
}

export interface JsonRpcRequestOptions {
  method: string;
  params?: unknown;
  timeoutMs?: number;
  notification?: boolean;
}

export class JsonRpcClient {
  private child: ChildProcessWithoutNullStreams | undefined;
  private nextId = 1;
  private stdoutBuffer = Buffer.alloc(0);
  private stderrBytes = 0;
  private readonly pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private closed = false;
  private closeError: Error | undefined;
  private readonly onAbort: (() => void) | undefined;

  constructor(private readonly options: JsonRpcClientOptions) {
    if (options.signal) {
      this.onAbort = () => {
        this.failAll(new ProviderCollectionError("unavailable", "RPC cancelled."));
        this.terminate();
      };
      if (options.signal.aborted) {
        this.onAbort();
      } else {
        options.signal.addEventListener("abort", this.onAbort, { once: true });
      }
    }
  }

  async start(): Promise<void> {
    if (this.child) {
      return;
    }
    if (this.closed || this.options.signal?.aborted) {
      throw (
        this.closeError ?? new ProviderCollectionError("unavailable", "RPC process is not running.")
      );
    }
    const env: NodeJS.ProcessEnv = {};
    const source = this.options.environment ?? process.env;
    for (const [key, value] of Object.entries(source)) {
      if (typeof value === "string") {
        env[key] = value;
      }
    }

    this.child = spawn(this.options.executable, [...this.options.args], {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
      windowsHide: true,
    });

    this.child.stdout.on("data", (chunk: Buffer) => this.onStdout(chunk));
    this.child.stderr.on("data", (chunk: Buffer) => {
      this.stderrBytes += chunk.byteLength;
      if (this.stderrBytes > JSON_RPC_STDERR_LIMIT_BYTES) {
        this.failAll(new ProviderCollectionError("error", "RPC stderr exceeded capture limit."));
        this.terminate();
      }
    });
    this.child.on("error", (error) => {
      this.failAll(
        new ProviderCollectionError(
          "unavailable",
          sanitizeMessage(error.message || "Failed to start RPC process."),
        ),
      );
      this.terminate();
    });
    this.child.on("close", () => {
      this.closed = true;
      // Only reject in-flight waiters; avoid throwing after an intentional shutdown.
      if (this.pending.size > 0) {
        this.failAll(
          this.closeError ??
            new ProviderCollectionError("unavailable", "RPC process closed unexpectedly."),
        );
      }
    });
  }

  async request(options: JsonRpcRequestOptions): Promise<unknown> {
    await this.start();
    if (!this.child || this.closed) {
      throw (
        this.closeError ?? new ProviderCollectionError("unavailable", "RPC process is not running.")
      );
    }

    if (options.notification) {
      await this.writePayload({
        method: options.method,
        params: options.params ?? {},
      });
      return undefined;
    }

    const id = this.nextId++;
    const timeoutMs = options.timeoutMs ?? this.options.requestTimeoutMs;
    const payload: Record<string, unknown> = {
      jsonrpc: "2.0",
      id,
      method: options.method,
      params: options.params ?? {},
    };

    const responsePromise = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.closeError = new ProviderCollectionError(
          "unavailable",
          `RPC timed out on \`${options.method}\`.`,
        );
        this.terminate();
        reject(this.closeError);
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });

    try {
      await this.writePayload(payload);
    } catch (error) {
      const waiter = this.pending.get(id);
      if (waiter) {
        clearTimeout(waiter.timer);
        this.pending.delete(id);
        waiter.reject(
          error instanceof Error
            ? error
            : new ProviderCollectionError("unavailable", "Failed to write RPC request."),
        );
      }
      this.terminate();
      return await responsePromise;
    }
    return responsePromise;
  }

  async initialize(
    method: string,
    params: unknown,
    timeoutMs = this.options.initializeTimeoutMs,
  ): Promise<unknown> {
    return this.request({ method, params, timeoutMs });
  }

  shutdown(): void {
    this.closeError = new ProviderCollectionError("unavailable", "RPC client shut down.");
    this.terminate();
    if (this.onAbort && this.options.signal) {
      this.options.signal.removeEventListener("abort", this.onAbort);
    }
  }

  private async writePayload(payload: Record<string, unknown>): Promise<void> {
    if (!this.child || this.closed) {
      throw (
        this.closeError ?? new ProviderCollectionError("unavailable", "RPC process is not running.")
      );
    }
    const line = `${JSON.stringify(payload)}\n`;
    await new Promise<void>((resolve, reject) => {
      this.child?.stdin.write(line, (error) => {
        if (error) {
          reject(
            new ProviderCollectionError(
              "unavailable",
              sanitizeMessage(error.message || "Failed to write RPC request."),
            ),
          );
          return;
        }
        resolve();
      });
    });
  }

  private onStdout(chunk: Buffer): void {
    this.stdoutBuffer = Buffer.concat([this.stdoutBuffer, chunk]);
    while (true) {
      const newline = this.stdoutBuffer.indexOf(0x0a);
      if (newline < 0) {
        if (this.stdoutBuffer.byteLength > JSON_RPC_STDOUT_LINE_LIMIT_BYTES) {
          this.failAll(
            new ProviderCollectionError("error", "RPC stdout line exceeded size limit."),
          );
          this.terminate();
        }
        return;
      }
      const lineBuf = this.stdoutBuffer.subarray(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.subarray(newline + 1);
      if (lineBuf.byteLength > JSON_RPC_STDOUT_LINE_LIMIT_BYTES) {
        this.failAll(new ProviderCollectionError("error", "RPC stdout line exceeded size limit."));
        this.terminate();
        return;
      }
      const line = lineBuf.toString("utf8").trim();
      if (!line) {
        continue;
      }
      this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let message: unknown;
    try {
      message = JSON.parse(line) as unknown;
    } catch {
      // Skip non-JSON noise.
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return;
    }
    const record = message as Record<string, unknown>;
    if (!("id" in record) || record.id === null || record.id === undefined) {
      // Notification.
      return;
    }
    const id = typeof record.id === "number" ? record.id : Number(record.id);
    if (!Number.isFinite(id)) {
      return;
    }
    const waiter = this.pending.get(id);
    if (!waiter) {
      return;
    }
    clearTimeout(waiter.timer);
    this.pending.delete(id);

    if (record.error && typeof record.error === "object" && !Array.isArray(record.error)) {
      const errorRecord = record.error as Record<string, unknown>;
      const code = typeof errorRecord.code === "number" ? errorRecord.code : undefined;
      const errorMessage =
        typeof errorRecord.message === "string" ? errorRecord.message : "RPC request failed.";
      const lower = errorMessage.toLowerCase();
      if (code === -32601 || lower.includes("method not found")) {
        waiter.reject(new ProviderCollectionError("unsupported", sanitizeMessage(errorMessage)));
        return;
      }
      if (
        lower.includes("authentication required") ||
        lower.includes("not authenticated") ||
        lower.includes("login")
      ) {
        waiter.reject(new ProviderCollectionError("auth_required", sanitizeMessage(errorMessage)));
        return;
      }
      waiter.reject(new ProviderCollectionError("error", sanitizeMessage(errorMessage)));
      return;
    }

    waiter.resolve(record.result);
  }

  private failAll(error: Error): void {
    this.closeError = error;
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.pending.clear();
  }

  private terminate(): void {
    if (!this.child) {
      this.closed = true;
      return;
    }
    const child = this.child;
    this.closed = true;
    try {
      child.stdin.end();
    } catch {
      // ignore
    }
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) {
          child.kill("SIGKILL");
        }
      }, 500).unref?.();
    }
  }
}
