import type { WebDocumentPort, WebDocumentViewer } from "$lib/server/document-port";

declare module "*.md?raw" {
  const markdown: string;
  export default markdown;
}

declare global {
  namespace App {
    interface Locals {
      viewer: WebDocumentViewer | null;
      document: WebDocumentPort;
    }
    interface Platform {
      document: WebDocumentPort;
      // The Node deployment has none of these: no waitUntil, no colo cache, and no Cloudflare
      // request properties (docs/decisions/0049-one-relay-two-runtimes.md).
      ctx?: ExecutionContext | undefined;
      caches?: CacheStorage | undefined;
      cf?: IncomingRequestCfProperties | undefined;
    }
  }
}
