import type { AccountIdentity } from "@gotry-io/quota-protocol";
import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { KEEP_ONE_SIGN_IN_COPY } from "$lib/account-errors";
import SignInMethodSettings from "./SignInMethodSettings.svelte";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function identity(
  provider: AccountIdentity["provider"],
  label: string,
  linkedAt = "2026-01-04T12:00:00Z",
): AccountIdentity {
  return { provider, label, linked_at: linkedAt };
}

it("lists Apple, GitHub, and Email, and disables Unlink on the last channel", () => {
  render(SignInMethodSettings, {
    identities: [identity("github", "octocat")],
    onChanged: async () => {},
    onError: () => {},
  });

  const rows = [...document.querySelectorAll("[data-provider]")].map((row) =>
    row.getAttribute("data-provider"),
  );
  expect(rows).toEqual(["apple", "github", "email"]);
  expect(screen.getByText("octocat")).toBeDefined();
  expect(screen.getByRole("button", { name: "Unlink" })).toHaveProperty("disabled", true);
  expect(screen.getByText(KEEP_ONE_SIGN_IN_COPY)).toBeDefined();
  expect(document.querySelector('[data-provider="apple"] a')?.getAttribute("href")).toBe(
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
  expect(document.querySelector('[data-provider="github"] a')).toBeNull();
  expect(document.querySelector('[data-provider="email"] a')).toBeNull();
  expect(screen.getByRole("button", { name: "Link" })).toBeDefined();
});
