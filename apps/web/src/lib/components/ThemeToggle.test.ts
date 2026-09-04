import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import ThemeToggle from "./ThemeToggle.svelte";

const THEME_STORAGE_KEY = "quota-theme";

function option(name: string): HTMLElement {
  return screen.getByRole("button", { name });
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it("renders System, Light, and Dark and writes quota-theme", () => {
  render(ThemeToggle);

  fireEvent.click(option("Light"));
  expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("light");
  expect(document.documentElement.getAttribute("data-theme")).toBe("light");

  fireEvent.click(option("Dark"));
  expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
  expect(document.documentElement.getAttribute("data-theme")).toBe("dark");

  fireEvent.click(option("System"));
  expect(localStorage.getItem(THEME_STORAGE_KEY)).toBeNull();
  expect(document.documentElement.getAttribute("data-theme")).toBeNull();
});

it("still renders when localStorage throws", () => {
  const unavailable = (): never => {
    throw new Error("localStorage is not available");
  };
  vi.spyOn(localStorage, "getItem").mockImplementation(unavailable);
  vi.spyOn(localStorage, "setItem").mockImplementation(unavailable);
  vi.spyOn(localStorage, "removeItem").mockImplementation(unavailable);

  expect(() => render(ThemeToggle)).not.toThrow();
  expect(option("System")).toBeTruthy();
  expect(option("Light")).toBeTruthy();
  expect(option("Dark")).toBeTruthy();
  expect(() => fireEvent.click(option("Dark"))).not.toThrow();
});
