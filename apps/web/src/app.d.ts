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
      ctx?: ExecutionContext;
      caches?: CacheStorage;
      cf?: IncomingRequestCfProperties;
    }
  }
}
