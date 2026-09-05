import { expect } from "vitest";

/**
 * Where `/oauth/v2/authorize` sent this browser to confirm which Account it is signing in as.
 *
 * A native login no longer leaves for an identity provider on its own: it lands on `/sign-in`,
 * and the completion route it will come back to is that page's `return_to`
 * ([ADR 0032](../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 */
export function signInReturnTo(response: Response): string {
  const location = new URL(response.headers.get("location") ?? "", "https://quota.gotry.io");
  expect(location.pathname).toBe("/sign-in");
  const returnTo = location.searchParams.get("return_to");
  expect(returnTo).toMatch(/^\/oauth\/v2\/complete\?login_token=/);
  return returnTo ?? "";
}
