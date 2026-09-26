import { redirect } from "@sveltejs/kit";
import { DASHBOARD_PATH } from "$lib/routes";
import type { PageServerLoad } from "./$types";

/**
 * Usage became Home ([ADR 0064](../../../../../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md));
 * a shipped bookmark keeps its period.
 */
export const load: PageServerLoad = ({ url }) => {
  redirect(302, `${DASHBOARD_PATH}${url.search}`);
};
