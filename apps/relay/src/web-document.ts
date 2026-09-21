import { manifest, Server } from "quota-sveltekit-server";
import type { WebDocumentPort } from "../../web/src/lib/server/document-port.ts";
import { clientAddress } from "./platform/client-address.ts";
import type { StaticFiles } from "./platform/static-files.ts";
import { runDocumentSsr } from "./web-document-ssr.ts";

const server = new Server(manifest);

export async function respondWithWebDocument(
  request: Request,
  assets: StaticFiles,
  platform: { document: WebDocumentPort },
): Promise<Response> {
  return runDocumentSsr(request, platform.document, async (document) => {
    await server.init({
      env: {},
      read: async (file) => {
        const asset = await assets.fetch(new URL(file, request.url));
        if (!asset.ok || !asset.body) {
          throw new Error(`read(...) failed: ${file} (${asset.status})`);
        }
        return asset.body;
      },
    });
    return server.respond(request, {
      platform: { document },
      getClientAddress() {
        return clientAddress(request.headers) ?? "";
      },
    });
  });
}
