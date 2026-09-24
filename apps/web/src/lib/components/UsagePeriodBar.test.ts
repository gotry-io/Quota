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
  render(UsagePeriodBar, { selection, today, earliest, onSelect });
  return { onSelect };
}

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
