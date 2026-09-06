import type { Handle, RequestEvent } from "@sveltejs/kit";
import { dev } from "$app/environment";
import type { WebDocumentPort } from "$lib/server/document-port";
import { devDocumentPort } from "$lib/server/dev-document-port";

export const handle: Handle = async ({ event, resolve }) => {
  event.locals.document = documentPort(event);
  event.locals.viewer = await event.locals.document.getViewer(event.request.headers);

  const response = await resolve(event);
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.delete("ETag");
  return response;
};

/**
 * The one place a load reaches account data from.
 *
 * In production it is Relay's own port; there is no other way in, and no `env`, `DB`, or secret
 * on `platform` for a load to find ([ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md)).
 */
function documentPort(event: RequestEvent): WebDocumentPort {
  const port = event.platform?.document;
  if (port) return port;
  if (!dev) throw new Error("web document port missing");
  return devDocumentPort();
}
