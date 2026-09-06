import { error } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

/**
 * A public page is rendered, not fetched.
 *
 * Everything on it is the same for every reader, so there is no calendar to ask the browser
 * for and no session to wait on: the first HTML byte already carries the numbers, which is
 * also what a link preview needs to read. A handle with no page behind it is a 404 here rather
 * than an empty page, so a mistyped link says so.
 */
export const load: PageServerLoad = async ({ params, locals }) => {
  const profile = await locals.document.readPublicProfile(params.handle);
  if (!profile) error(404, "No public Quota profile is published at this address.");
  return { profile };
};
