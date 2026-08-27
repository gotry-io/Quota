import { redirect } from "@sveltejs/kit";
import { DASHBOARD_PATH } from "$lib/routes";

/** `/app` shipped in 0.0.4, so the bookmark stays a redirect while `/my` is canonical. */
export function load(): never {
  redirect(302, DASHBOARD_PATH);
}
