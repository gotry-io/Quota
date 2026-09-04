import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import AccountNav from "./AccountNav.svelte";

afterEach(cleanup);

it("marks the current account route", () => {
  render(AccountNav, { currentPath: "/my/usage" });

  expect(screen.getByRole("link", { name: "Usage" }).getAttribute("aria-current")).toBe("page");
  expect(screen.getByRole("link", { name: "Overview" }).getAttribute("aria-current")).toBeNull();
  expect(screen.getByRole("link", { name: "Devices" }).getAttribute("aria-current")).toBeNull();
  expect(screen.getByRole("link", { name: "Settings" }).getAttribute("aria-current")).toBeNull();
  expect(
    screen.getByRole("link", { name: "Overview" }).getAttribute("data-sveltekit-preload-data"),
  ).toBe("hover");
});

it("marks Overview only on /my", () => {
  render(AccountNav, { currentPath: "/my" });

  expect(screen.getByRole("link", { name: "Overview" }).getAttribute("aria-current")).toBe("page");
  expect(screen.getByRole("link", { name: "Usage" }).getAttribute("aria-current")).toBeNull();
});
