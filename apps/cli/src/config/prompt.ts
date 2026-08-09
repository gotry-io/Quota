import { stdin, stdout } from "node:process";
import { createInterface } from "node:readline/promises";

export type PromptOptions = {
  /** Hide typed characters (API keys); secret prompts require a TTY with raw-mode support. */
  secret?: boolean;
};

/**
 * Interactive line prompt. Secrets use raw mode so the key never echoes to the terminal.
 * Injectable for tests via module mock.
 */
export async function promptLine(message: string, options: PromptOptions = {}): Promise<string> {
  if (options.secret) {
    if (!stdin.isTTY || typeof stdin.setRawMode !== "function") {
      throw new Error("Secret prompt requires an interactive terminal.");
    }
    return await promptSecret(message);
  }
  return await promptVisible(message);
}

async function promptVisible(message: string): Promise<string> {
  const rl = createInterface({ input: stdin, output: stdout });
  try {
    return await rl.question(message);
  } finally {
    rl.close();
  }
}

async function promptSecret(message: string): Promise<string> {
  stdout.write(message);
  stdin.resume();
  stdin.setEncoding("utf8");
  const wasRaw = stdin.isRaw === true;
  stdin.setRawMode(true);

  let value = "";
  try {
    return await new Promise<string>((resolve, reject) => {
      const onData = (chunk: string | Buffer) => {
        const text = typeof chunk === "string" ? chunk : chunk.toString("utf8");
        for (const char of text) {
          if (char === "\n" || char === "\r" || char === "\u0004") {
            cleanup();
            stdout.write("\n");
            resolve(value);
            return;
          }
          if (char === "\u0003") {
            cleanup();
            stdout.write("\n");
            reject(new Error("Interrupted"));
            return;
          }
          // Backspace / delete
          if (char === "\u007f" || char === "\b") {
            if (value.length > 0) {
              value = value.slice(0, -1);
            }
            continue;
          }
          // Ignore other control characters
          if (char < " ") {
            continue;
          }
          value += char;
        }
      };

      const cleanup = () => {
        stdin.off("data", onData);
        stdin.setRawMode(wasRaw);
        stdin.pause();
      };

      stdin.on("data", onData);
    });
  } catch (error) {
    stdin.setRawMode(wasRaw);
    stdin.pause();
    throw error;
  }
}
