import { redirect } from "@sveltejs/kit";
import type { LayoutServerLoad } from "./$types";

/**
 * Every `/my` document is a signed-in shell, and nothing more.
 *
 * The Account read the pages fill themselves from is bounded by the caller's calendar, and a
 * document request has no clock: rendering one here would answer in UTC, which every browser
 * keeping another calendar would then throw away and ask again for. One read per load, from the
 * client that knows what to ask for. Child navigations must not re-run this load, so it reads
 * only `locals`.
 */
export const load: LayoutServerLoad = ({ locals }) => {
  if (!locals.viewer) redirect(302, "/");
};
