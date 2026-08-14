import { manifest, Server } from "quota-sveltekit-server";
import type { WebDocumentPort } from "../../web/src/lib/server/document-port.ts";
import type { CloudflareBindings } from "./cloudflare.ts";
import { runDocumentSsr } from "./web-document-ssr.ts";

const server = new Server(manifest);

export async function respondWithWebDocument(
  request: Request,
  environment: Pick<CloudflareBindings, "ASSETS">,
  context: ExecutionContext,
  platform: { document: WebDocumentPort },
): Promise<Response> {
  return runDocumentSsr(request, platform.document, async (document) => {
    await server.init({
      env: {},
      read: async (file) => {
        const asset = await environment.ASSETS.fetch(new URL(file, request.url));
        if (!asset.ok || !asset.body) {
          throw new Error(`read(...) failed: ${file} (${asset.status})`);
        }
        return asset.body;
      },
    });
    return server.respond(request, {
      platform: {
        document,
        ctx: context,
        caches,
        cf: request.cf,
      },
      getClientAddress() {
        return request.headers.get("cf-connecting-ip") ?? "";
      },
    });
  });
}
