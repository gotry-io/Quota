import type { WebDocumentPort, WebDocumentViewer } from "../../web/src/lib/server/document-port.ts";

export function withPrivateNoStore(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Cache-Control", "private, no-store");
  headers.delete("ETag");
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
  const getAccountSummary = inner.getAccountSummary;
  return {
    port: {
      getViewer(headers) {
        viewer ??= inner.getViewer(headers);
        return viewer;
      },
      ...(getAccountSummary
        ? {
            getAccountSummary(headers: Headers) {
              return getAccountSummary(headers);
            },
          }
        : {}),
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
