const timeoutMilliseconds = 20_000;
const maximumResponseBytes = 16 * 1024;
const resendUrl = "https://api.resend.com/emails";
const defaultFrom = "Quota <login@gotry.io>";

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export type EmailSendResult = { id: string } | { failed: true };

/** One outbound mailer. Production speaks Resend; tests replace it. */
export interface EmailSender {
  send(message: EmailMessage): Promise<EmailSendResult>;
}

export function isEmailSendFailure(result: EmailSendResult): result is { failed: true } {
  return "failed" in result;
}

export interface ResendEmailEnvironment {
  apiKey: string;
  fetch?: typeof fetch;
  from?: string;
}

/**
 * Resend as Quota's mailer.
 *
 * The address is in the body Resend must see and nowhere else this object keeps. A timeout or a
 * failing status is a failed send, not an exception: the sign-in that asked for the mail still
 * answers 202, and the caller logs `email_send_failed` with the address hash, never the address.
 */
export class ResendEmailSender implements EmailSender {
  readonly #fetch: typeof fetch;
  readonly #from: string;

  constructor(private readonly environment: ResendEmailEnvironment) {
    const implementation = environment.fetch ?? fetch;
    this.#fetch = (input, init) => implementation.call(globalThis, input, init);
    this.#from = environment.from ?? defaultFrom;
  }

  async send(message: EmailMessage): Promise<EmailSendResult> {
    let response: Response;
    try {
      response = await this.#fetch(resendUrl, {
        method: "POST",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${this.environment.apiKey}`,
          "Content-Type": "application/json",
          "User-Agent": "QuotaRelay",
        },
        body: JSON.stringify({
          from: this.#from,
          to: [message.to],
          subject: message.subject,
          html: message.html,
          text: message.text,
        }),
        signal: AbortSignal.timeout(timeoutMilliseconds),
      });
    } catch {
      return { failed: true };
    }
    if (!response.ok) {
      await response.body?.cancel();
      return { failed: true };
    }
    const body = await readBoundedJSON(response);
    return typeof body.id === "string" && body.id ? { id: body.id } : { failed: true };
  }
}

async function readBoundedJSON(response: Response): Promise<Record<string, unknown>> {
  const reader = response.body?.getReader();
  if (!reader) return {};
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumResponseBytes) {
      await reader.cancel();
      return {};
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return {};
  }
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : {};
}
