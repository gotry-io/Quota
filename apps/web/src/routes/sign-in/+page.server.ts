import { error } from "@sveltejs/kit";
import { DASHBOARD_PATH, signInReturnPath } from "$lib/routes";
import type { PageServerLoad } from "./$types";

/**
 * Where this sign-in returns to, checked before the page renders a link to it.
 *
 * A return target that survives a round trip through an identity provider is exactly the shape
 * an open redirect takes, so anything but a same-origin path is a bad request rather than a
 * silent fallback.
 */
export const load: PageServerLoad = ({ url }) => {
  const requested = url.searchParams.get("return_to");
  const returnTo = requested === null ? DASHBOARD_PATH : signInReturnPath(requested);
  if (returnTo === null) error(400, "That sign-in link does not name a page on Quota.");
  return { returnTo };
};
