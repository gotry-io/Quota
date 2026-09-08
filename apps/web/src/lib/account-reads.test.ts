import { expect, it } from "vitest";
import { parseAccountResponse } from "./account-reads.ts";

function accountOk() {
  return {
    protocol_version: 2,
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-01-04T12:00:00Z",
    },
    identities: [{ provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" }],
  };
}

it("reads account metadata and identities", () => {
  expect(parseAccountResponse(200, accountOk())).toEqual({
    status: "ok",
    account: accountOk(),
  });
  const extra = parseAccountResponse(200, { ...accountOk(), extra: true });
  expect(extra.status).toBe("ok");
  if (extra.status === "ok") {
    expect(extra.account.account.display_label).toBe("octocat");
    expect(extra.account.identities).toEqual(accountOk().identities);
  }
});

it("ignores a body that is not an account answer", () => {
  expect(parseAccountResponse(200, { protocol_version: 2 }).status).toBe("unavailable");
  expect(parseAccountResponse(500, null).status).toBe("unavailable");
});
