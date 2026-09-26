import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import AccountNav from "./AccountNav.svelte";

afterEach(cleanup);

function current(): string[] {
  return screen
    .getAllByRole("link")
    .filter((link) => link.getAttribute("aria-current") === "page")
    .map((link) => link.textContent ?? "");
}

it("marks the nav item a page belongs to, and none for the account menu's pages", () => {
  render(AccountNav, { currentPath: "/my/usage" });
  expect(current()).toEqual(["Home"]);

  cleanup();
  render(AccountNav, { currentPath: "/my/subscriptions/0123456789ab" });
  expect(current()).toEqual(["Quota"]);

  cleanup();
  render(AccountNav, { currentPath: "/my/settings" });
  expect(current()).toEqual([]);
});
