import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import PeriodControl from "./PeriodControl.svelte";

afterEach(cleanup);

/** A Sunday, so a week's own dates are unambiguous. */
const today = new Date(2026, 8, 6);

it("opens a range form from More seeded with the period showing and applies the two dates", async () => {
  const onSelect = vi.fn();
  render(PeriodControl, { selection: { segment: "7d" }, today, earliest: "2025-09-07", onSelect });

  await fireEvent.click(screen.getByRole("button", { name: /More/ }));
  await fireEvent.click(screen.getByRole("menuitemradio", { name: "Custom range…" }));
  const form = screen.getByRole("form", { name: "Custom range" });
  const from = screen.getByLabelText("From") as HTMLInputElement;
  expect(from.value).toBe("2026-08-31");
  expect((screen.getByLabelText("To") as HTMLInputElement).value).toBe("2026-09-06");

  await fireEvent.input(from, { target: { value: "2026-08-01" } });
  await fireEvent.submit(form);
  expect(onSelect).toHaveBeenCalledWith({
    segment: "custom",
    from: "2026-08-01",
    to: "2026-09-06",
  });
});
