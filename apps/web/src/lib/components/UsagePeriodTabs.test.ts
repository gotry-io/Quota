import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import UsagePeriodTabs from "./UsagePeriodTabs.svelte";

afterEach(cleanup);

it("presses the tab that matches the period query and writes the next query", async () => {
  const onSelectQuery = vi.fn();
  const view = render(UsagePeriodTabs, { selectedQuery: "30d", onSelectQuery });

  expect(screen.getByRole("button", { name: "Today" }).getAttribute("aria-pressed")).toBe("false");
  expect(screen.getByRole("button", { name: "7 Days" }).getAttribute("aria-pressed")).toBe("false");
  expect(screen.getByRole("button", { name: "30 Days" }).getAttribute("aria-pressed")).toBe("true");
  expect(screen.getByRole("button", { name: "Up to 2 years" }).getAttribute("aria-pressed")).toBe(
    "false",
  );

  fireEvent.click(screen.getByRole("button", { name: "Today" }));
  expect(onSelectQuery).toHaveBeenCalledWith("today");

  await view.rerender({ selectedQuery: "today", onSelectQuery });
  expect(screen.getByRole("button", { name: "Today" }).getAttribute("aria-pressed")).toBe("true");
  expect(screen.getByRole("button", { name: "30 Days" }).getAttribute("aria-pressed")).toBe(
    "false",
  );

  fireEvent.click(screen.getByRole("button", { name: "Up to 2 years" }));
  expect(onSelectQuery).toHaveBeenCalledWith("all");
});
