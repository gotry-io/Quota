import type { PageServerLoad } from "./$types";

/**
 * The board is rendered, not fetched.
 *
 * Everything ranked on it is the same for every reader, so the first HTML byte already carries
 * the places — which is also what a link preview needs to read. The one thing the port answers
 * per reader is which handle is theirs, so the page can point it out.
 */
export const load: PageServerLoad = async ({ locals, request }) => {
  return await locals.document.readLeaderboard(request.headers);
};
