import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";

const LOGIN_TIMEOUT_MILLISECONDS = 10 * 60 * 1000;

export interface BrowserAuthorizationResult {
  code: string;
  code_verifier: string;
  redirect_uri: string;
}

export interface BrowserAuthorizationOptions {
  origin: string;
  clientId?: string;
  open?: (url: string) => Promise<void>;
  signal?: AbortSignal;
  timeoutMilliseconds?: number;
}

export class BrowserAuthorizationError extends Error {
  readonly code: "cancelled" | "expired" | "invalid_callback" | "browser_unavailable";

  constructor(
    code: "cancelled" | "expired" | "invalid_callback" | "browser_unavailable",
    message: string,
  ) {
    super(message);
    this.name = "BrowserAuthorizationError";
    this.code = code;
  }
}

export async function runBrowserAuthorization(
  options: BrowserAuthorizationOptions,
): Promise<BrowserAuthorizationResult> {
  const state = base64Url(randomBytes(32));
  const codeVerifier = base64Url(randomBytes(48));
  const challenge = base64Url(createHash("sha256").update(codeVerifier).digest());
  const timeoutMilliseconds = options.timeoutMilliseconds ?? LOGIN_TIMEOUT_MILLISECONDS;
  const opener = options.open ?? openSystemBrowser;

  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (address === null || typeof address === "string") {
    server.close();
    throw new BrowserAuthorizationError("invalid_callback", "Could not bind the login callback.");
  }
  const redirectUri = `http://127.0.0.1:${address.port}/callback`;
  const authorize = new URL("/oauth/v2/authorize", options.origin);
  authorize.searchParams.set("client_id", options.clientId ?? "quotacli");
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("redirect_uri", redirectUri);
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("code_challenge", challenge);
  authorize.searchParams.set("code_challenge_method", "S256");

  const callbackAbort = new AbortController();
  const callbackSignal = AbortSignal.any([
    callbackAbort.signal,
    AbortSignal.timeout(timeoutMilliseconds),
    ...(options.signal ? [options.signal] : []),
  ]);
  const callback = waitForCallback(server, state, callbackSignal);
  void callback.catch(() => undefined);
  try {
    await opener(authorize.toString());
    const code = await callback;
    return { code, code_verifier: codeVerifier, redirect_uri: redirectUri };
  } catch (error) {
    callbackAbort.abort();
    await callback.catch(() => undefined);
    throw error;
  } finally {
    callbackAbort.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

async function waitForCallback(
  server: ReturnType<typeof createServer>,
  state: string,
  signal: AbortSignal,
): Promise<string> {
  return await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (result: { code: string } | { error: BrowserAuthorizationError }) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      if ("error" in result) reject(result.error);
      else resolve(result.code);
    };
    const onAbort = () => {
      const expired =
        signal.reason instanceof DOMException && signal.reason.name === "TimeoutError";
      finish({
        error: new BrowserAuthorizationError(
          expired ? "expired" : "cancelled",
          expired ? "Quota login expired." : "Quota login was cancelled.",
        ),
      });
    };
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) {
      onAbort();
      return;
    }

    server.on("request", (request, response) => {
      const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
      if (request.method !== "GET" || requestUrl.pathname !== "/callback") {
        response.writeHead(404).end();
        return;
      }
      response.setHeader("Content-Type", "text/plain; charset=utf-8");
      response.setHeader("Cache-Control", "no-store");
      const queryKeys = [...requestUrl.searchParams.keys()];
      const exactCallback =
        queryKeys.length === 2 &&
        new Set(queryKeys).size === 2 &&
        queryKeys.includes("state") &&
        queryKeys.includes("code") !== queryKeys.includes("error");
      const returnedState = requestUrl.searchParams.get("state");
      const code = requestUrl.searchParams.get("code");
      const error = requestUrl.searchParams.get("error");
      if (!exactCallback || returnedState !== state) {
        response
          .writeHead(400)
          .end("Quota login callback was rejected. You can close this window.");
        return;
      }
      if (error !== null) {
        response.writeHead(400).end("Quota login was cancelled. You can close this window.");
        finish({ error: new BrowserAuthorizationError("cancelled", "Quota login was cancelled.") });
        return;
      }
      if (!code || code.length > 4096) {
        response
          .writeHead(400)
          .end("Quota login callback was rejected. You can close this window.");
        finish({
          error: new BrowserAuthorizationError(
            "invalid_callback",
            "Quota login callback was invalid.",
          ),
        });
        return;
      }
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response
        .writeHead(200)
        .end(
          '<!doctype html><meta charset="utf-8"><title>Quota login complete</title><p>Quota login complete. Return to QuotaBar or your terminal.</p><p>If this tab stays open, close it manually.</p><script>window.close()</script>',
        );
      finish({ code });
    });
  });
}

async function openSystemBrowser(url: string): Promise<void> {
  const command =
    process.platform === "darwin"
      ? { executable: "open", arguments: [url] }
      : process.platform === "win32"
        ? { executable: "rundll32.exe", arguments: ["url.dll,FileProtocolHandler", url] }
        : { executable: "xdg-open", arguments: [url] };
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command.executable, command.arguments, {
      stdio: "ignore",
      windowsHide: true,
    });
    child.once("error", () =>
      reject(
        new BrowserAuthorizationError(
          "browser_unavailable",
          "QuotaCLI could not open the system browser.",
        ),
      ),
    );
    child.once("spawn", resolve);
  });
}

function base64Url(value: Uint8Array): string {
  return Buffer.from(value).toString("base64url");
}
