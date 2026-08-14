import { error } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, platform, locals }) => {
  const port = platform?.document;
  if (!port) throw error(500, "document port missing");
  const result = await port.lookupPublicProfile(params.username);
  switch (result.status) {
    case "missing":
      throw error(404, "unavailable");
    case "rate_limited":
      locals.retryAfterSeconds = result.retryAfterSeconds;
      throw error(429, "rate_limited");
    case "exists":
      return { username: params.username };
  }
};
