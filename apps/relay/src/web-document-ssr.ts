import type { WebDocumentPort, WebDocumentViewer } from "../../web/src/lib/server/document-port.ts";

/**
 * What a document may load, for every document response that does not state it itself.
 *
 * A rendered page states its own: `apps/web/svelte.config.js` declares these directives and
 * SvelteKit stamps each response with the nonce that lets its bootstrap script and the theme
 * script in `app.html` run. Everything else a document request produces — a `__data.json`
 * payload, a redirect, the failure page below — carries no inline script at all, so the same
 * policy without a nonce is the whole answer for those.
 */
const DOCUMENT_CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "object-src 'none'",
  "form-action 'self'",
].join("; ");

/**
 * The one place every document response passes, so it is where a document's headers are decided.
 *
 * Documents are per-viewer and never cacheable, and the three headers beside the policy are the
 * ones a browser needs stated rather than guessed: no content sniffing, no cross-origin framing,
 * and no referrer leaving this origin.
 */
export function withPrivateNoStore(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Cache-Control", "private, no-store");
  headers.delete("ETag");
  if (!headers.has("Content-Security-Policy")) {
    headers.set("Content-Security-Policy", DOCUMENT_CONTENT_SECURITY_POLICY);
  }
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "same-origin");
  headers.set("X-Frame-Options", "DENY");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function memoizeWebDocumentPort(inner: WebDocumentPort): {
  port: WebDocumentPort;
  hasViewer(): Promise<boolean>;
} {
  let viewer: Promise<WebDocumentViewer | null> | undefined;
  return {
    port: {
      getViewer(headers) {
        viewer ??= inner.getViewer(headers);
        return viewer;
      },
    },
    async hasViewer() {
      if (!viewer) return false;
      try {
        return (await viewer) !== null;
      } catch {
        return false;
      }
    },
  };
}

export async function runDocumentSsr(
  request: Request,
  port: WebDocumentPort,
  render: (document: WebDocumentPort) => Promise<Response>,
): Promise<Response> {
  const path = new URL(request.url).pathname;
  const memoized = memoizeWebDocumentPort(port);
  try {
    const responded = await render(memoized.port);
    logDocumentSsr("document_ssr", path, responded.status, await memoized.hasViewer());
    return withPrivateNoStore(responded);
  } catch {
    logDocumentSsr("document_ssr_failed", path, 500, await memoized.hasViewer());
    return withPrivateNoStore(documentSsrFailureResponse());
  }
}

export function documentSsrFailureResponse(): Response {
  return new Response(
    `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Quota</title>
  </head>
  <body>
    <h1>Quota could not load this page.</h1>
    <p>Refresh to try again.</p>
  </body>
</html>
`,
    {
      status: 500,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "private, no-store",
      },
    },
  );
}

function logDocumentSsr(
  event: "document_ssr" | "document_ssr_failed",
  path: string,
  status: number,
  has_viewer: boolean,
): void {
  const line = JSON.stringify({ event, path, status, has_viewer });
  if (event === "document_ssr_failed") {
    console.error(line);
    return;
  }
  console.log(line);
}
