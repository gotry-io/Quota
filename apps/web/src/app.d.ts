import type { WebDocumentPort, WebDocumentViewer } from "$lib/server/document-port";

declare global {
  namespace App {
    interface Locals {
      viewer: WebDocumentViewer | null;
      retryAfterSeconds?: number;
    }
    interface Platform {
      document: WebDocumentPort;
      ctx?: ExecutionContext;
      caches?: CacheStorage;
      cf?: IncomingRequestCfProperties;
    }
  }
}
