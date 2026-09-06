import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import type { UsagePeriodSelection } from "$lib/usage-period";
import UsagePeriodBar from "./UsagePeriodBar.svelte";

afterEach(cleanup);

/** A Sunday, so a week's own dates are unambiguous in the title. */
const today = new Date(2026, 8, 6);
const earliest = "2025-09-07";

function mount(selection: UsagePeriodSelection) {
  const onSelect = vi.fn();
  const view = render(UsagePeriodBar, { selection, today, earliest, onSelect });
  return { onSelect, view };
}

it("presses the segment showing, titles the range, and steps a unit at a time", async () => {
  const { onSelect, view } = mount({ segment: "month", offset: 0 });

  expect(screen.getByRole("button", { name: "This month" }).getAttribute("aria-pressed")).toBe(
    "true",
  );
  expect(screen.getByRole("button", { name: "Last 30 days" }).getAttribute("aria-pressed")).toBe(
    "false",
  );
  expect(screen.getByText("Sep 1 – Sep 30, 2026")).toBeTruthy();

  // The current month is the last one: there is nothing ahead of it.
  expect(screen.getByRole("button", { name: "Next period" }).hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Previous period" }));
  expect(onSelect).toHaveBeenCalledWith({ segment: "month", offset: 1 });

  await view.rerender({ selection: { segment: "month", offset: 1 }, today, earliest, onSelect });
  expect(screen.getByText("Aug 1 – Aug 31, 2026")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Next period" }).hasAttribute("disabled")).toBe(false);
});

it("does not step a fixed window, and says what All covers", async () => {
  const { view, onSelect } = mount({ segment: "all" });

  expect(screen.getByText("Everything kept")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Previous period" }).hasAttribute("disabled")).toBe(
    true,
  );
  expect(screen.getByRole("button", { name: "Next period" }).hasAttribute("disabled")).toBe(true);

  await view.rerender({ selection: { segment: "day", offset: 0 }, today, earliest, onSelect });
  expect(screen.getByText("Sep 6, 2026")).toBeTruthy();
});

it("opens a range form seeded with the period showing and applies the two dates", async () => {
  const { onSelect } = mount({ segment: "7d" });

  expect(screen.queryByRole("form", { name: "Custom range" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Custom range" }));

  const form = screen.getByRole("form", { name: "Custom range" });
  const from = screen.getByLabelText("From") as HTMLInputElement;
  const to = screen.getByLabelText("To") as HTMLInputElement;
  expect(from.value).toBe("2026-08-31");
  expect(to.value).toBe("2026-09-06");

  await fireEvent.input(from, { target: { value: "2026-08-01" } });
  await fireEvent.submit(form);
  expect(onSelect).toHaveBeenCalledWith({
    segment: "custom",
    from: "2026-08-01",
    to: "2026-09-06",
  });
});
