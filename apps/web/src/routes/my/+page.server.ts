import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

/**
 * The dashboard is a signed-in shell, and nothing more.
 *
 * The Account read it fills itself from is bounded by the caller's calendar, and a document
 * request has no clock: rendering one here would answer in UTC, which every browser keeping
 * another calendar would then throw away and ask again for. One read per load, from the client
 * that knows what to ask for.
 */
export const load: PageServerLoad = ({ locals }) => {
  if (!locals.viewer) redirect(302, "/");
};
