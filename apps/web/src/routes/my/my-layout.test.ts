import { expect, it } from "vitest";
import { load } from "./+layout.server.ts";

const loadLayout = load as unknown as (event: {
  locals: { viewer: { displayLabel: string } | null };
  url: URL;
  untrack: <T>(fn: () => T) => T;
}) => void;

function signedOut(path: string): unknown {
  try {
    loadLayout({
      locals: { viewer: null },
      url: new URL(`https://quota.gotry.io${path}`),
      untrack: (fn) => fn(),
    });
  } catch (thrown) {
    return thrown;
  }
  return null;
}

it("sends a signed-out visit to sign-in and back to the page it asked for", () => {
  expect(signedOut("/my/devices")).toMatchObject({
    status: 302,
    location: "/sign-in?return_to=%2Fmy%2Fdevices",
  });
  expect(signedOut("/my/usage?period=day")).toMatchObject({
    location: "/sign-in?return_to=%2Fmy%2Fusage%3Fperiod%3Dday",
  });
});
