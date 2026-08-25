import type { Handle, RequestEvent } from "@sveltejs/kit";
import { dev } from "$app/environment";
import { env } from "$env/dynamic/private";

export const handle: Handle = async ({ event, resolve }) => {
  event.locals.viewer = await resolveViewer(event);

  const response = await resolve(event);
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.delete("ETag");
  return response;
};

async function resolveViewer(event: RequestEvent): Promise<App.Locals["viewer"]> {
  const port = event.platform?.document;
  if (port) return port.getViewer(event.request.headers);
  if (!dev) throw new Error("web document port missing");
  const label = env.QUOTA_DEV_VIEWER?.trim();
  return label ? { displayLabel: label } : null;
}
