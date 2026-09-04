import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import RetryNotice from "./RetryNotice.svelte";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it("exposes an alert and calls Retry", () => {
  const onRetry = vi.fn();
  render(RetryNotice, {
    message: "Quota couldn't load this. Retry.",
    onRetry,
  });
  expect(screen.getByRole("alert").textContent).toContain("Quota couldn't load this. Retry.");
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  expect(onRetry).toHaveBeenCalledTimes(1);
});
