import { error } from "@sveltejs/kit";
import { DASHBOARD_PATH, SETTINGS_PATH, signInReturnPath } from "$lib/routes";
import type { PageServerLoad } from "./$types";

/**
 * Where this sign-in returns to, checked before the page renders a link to it.
 *
 * A return target that survives a round trip through an identity provider is exactly the shape
 * an open redirect takes, so anything but a same-origin path is a bad request rather than a
 * silent fallback. `intent=link` is how QuotaBar and Quota for iPhone send someone to bind a
 * channel: unsigned visitors sign in the usual way and land on Settings.
 */
export const load: PageServerLoad = ({ url }) => {
  const linking = url.searchParams.get("intent") === "link";
  const requested = url.searchParams.get("return_to");
  const returnTo =
    requested === null ? (linking ? SETTINGS_PATH : DASHBOARD_PATH) : signInReturnPath(requested);
  if (returnTo === null) error(400, "That sign-in link does not name a page on Quota.");
  return { returnTo, linking };
};
