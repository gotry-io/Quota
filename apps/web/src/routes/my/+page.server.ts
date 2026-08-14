import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = ({ locals, platform, request }) => {
  if (!locals.viewer) redirect(302, "/");
  return {
    streamed: {
      summary: platform?.document.getAccountSummary?.(request.headers) ?? null,
    },
  };
};
