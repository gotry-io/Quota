import { withPrivateNoStore } from "../web-document-ssr.ts";

/** Why a browser sign-in page could not finish. Never a token or cookie value. */
export type BrowserSignInFailureReason =
  | "no_session"
  | "expired"
  | "rate_limited"
  | "invalid_request"
  /** The channel this browser proved is already how another Quota Account is reached. */
  | "identity_taken";

const reasonCopy: Record<BrowserSignInFailureReason, string> = {
  no_session: "This browser isn't signed in to Quota.",
  expired: "This sign-in took too long and expired.",
  rate_limited: "Too many sign-in attempts. Wait a moment and try again.",
  invalid_request: "This sign-in request couldn't be completed.",
  identity_taken: "That account is already linked to another Quota account.",
};

export function acceptsHtml(accept: string | undefined): boolean {
  if (!accept) return false;
  for (const part of accept.split(",")) {
    const segments = part
      .split(";")
      .map((segment) => segment.trim())
      .filter((segment) => segment.length > 0);
    const media = segments[0]?.toLowerCase();
    if (media !== "text/html") continue;
    let quality = 1;
    for (const param of segments.slice(1)) {
      const separator = param.indexOf("=");
      if (separator <= 0) continue;
      const key = param.slice(0, separator).trim().toLowerCase();
      if (key !== "q") continue;
      const parsed = Number.parseFloat(param.slice(separator + 1).trim());
      quality = Number.isFinite(parsed) ? parsed : 0;
    }
    if (quality > 0) return true;
  }
  return false;
}

/**
 * A page a person in `ASWebAuthenticationSession` can read. JSON clients keep the original
 * status and body: only an Accept that names `text/html` gets this 200.
 */
export function browserSignInErrorPage(
  reason: BrowserSignInFailureReason,
  providerName?: string,
): Response {
  const explanation =
    reason === "identity_taken" && providerName
      ? `That ${providerName} account is already linked to another Quota account.`
      : reasonCopy[reason];
  const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Sign-in didn't finish</title>
  </head>
  <body data-reason="${reason}">
    <h1>Sign-in didn't finish</h1>
    <p>${explanation}</p>
    <p>Return to Quota and try again.</p>
  </body>
</html>
`;
  return withPrivateNoStore(
    new Response(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    }),
  );
}

/** Prefer the HTML page when the caller asked for HTML; otherwise the JSON error stands. */
export function htmlOrJsonSignInError(
  accept: string | undefined,
  json: Response,
  reason: BrowserSignInFailureReason,
  providerName?: string,
): Response {
  if (!acceptsHtml(accept)) return json;
  const page = browserSignInErrorPage(reason, providerName);
  const retryAfter = json.headers.get("Retry-After");
  if (!retryAfter) return page;
  const headers = new Headers(page.headers);
  headers.set("Retry-After", retryAfter);
  return new Response(page.body, { status: page.status, statusText: page.statusText, headers });
}
