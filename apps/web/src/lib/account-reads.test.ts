import { expect, it } from "vitest";
import { parseRedeemResponse, redeemCodePath } from "./account-reads.ts";

const grantedEntitlement = {
  status: "active",
  expires_at: "2026-12-01T00:00:00Z",
  will_renew: false,
  product_id: null,
  store: null,
  stale: false,
  checked_at: "2026-09-07T00:00:00Z",
};

function redeemOk(overrides: { duration?: string; campaign?: string } = {}) {
  return {
    protocol_version: 2,
    entitlement: grantedEntitlement,
    granted: {
      duration: overrides.duration ?? "three_month",
      campaign: overrides.campaign ?? "beta",
    },
  };
}

function relayError(code: string) {
  return { error: { code, message: code } };
}

it("names the redeem path", () => {
  expect(redeemCodePath()).toBe("/api/v2/account/redeem");
});

it("reads a successful grant and the mapped refusals", () => {
  expect(parseRedeemResponse(200, redeemOk())).toEqual({
    status: "ok",
    duration: "three_month",
    campaign: "beta",
  });
  expect(parseRedeemResponse(200, { ...redeemOk(), extra: true })).toEqual({
    status: "ok",
    duration: "three_month",
    campaign: "beta",
  });
  expect(parseRedeemResponse(404, relayError("code_invalid"))).toEqual({
    status: "error",
    code: "code_invalid",
  });
  expect(parseRedeemResponse(410, relayError("code_expired"))).toEqual({
    status: "error",
    code: "code_expired",
  });
  expect(parseRedeemResponse(409, relayError("code_already_redeemed"))).toEqual({
    status: "error",
    code: "code_already_redeemed",
  });
  expect(parseRedeemResponse(409, relayError("code_exhausted"))).toEqual({
    status: "error",
    code: "code_exhausted",
  });
  expect(parseRedeemResponse(502, relayError("billing_unavailable"))).toEqual({
    status: "error",
    code: "billing_unavailable",
  });
  expect(parseRedeemResponse(503, relayError("billing_unavailable"))).toEqual({
    status: "error",
    code: "billing_unavailable",
  });
  expect(parseRedeemResponse(429, null)).toEqual({
    status: "error",
    code: "rate_limited",
  });
});

it("ignores a body that is not a redeem answer", () => {
  expect(parseRedeemResponse(200, { protocol_version: 2 })).toBeNull();
  expect(parseRedeemResponse(404, relayError("not_found"))).toBeNull();
  expect(parseRedeemResponse(500, null)).toBeNull();
});
