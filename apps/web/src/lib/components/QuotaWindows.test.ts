import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import QuotaWindows from "./QuotaWindows.svelte";

afterEach(cleanup);

it("keys windows by id when titles repeat", () => {
  render(QuotaWindows, {
    windows: [
      { id: "weekly_a", title: "Weekly", used_percent: 10 },
      { id: "weekly_b", title: "Weekly", used_percent: 90 },
    ],
  });

  expect(screen.getAllByText("Weekly")).toHaveLength(2);
  expect(screen.getByText("90%")).toBeTruthy();
  expect(screen.getByText("10%")).toBeTruthy();
});

it("prints the pace headline on overview and the detail explanation only when asked", () => {
  const windows = [
    {
      id: "five_hour",
      title: "5 Hours",
      used_percent: 85,
      resets_at: "2026-09-05T12:00:00Z",
      duration_seconds: 18_000,
    },
  ];
  const now = new Date("2026-09-05T09:30:00Z");
  const { rerender } = render(QuotaWindows, { windows, now });
  expect(screen.getByText("May run out about 2h before reset")).toBeTruthy();
  expect(screen.queryByText(/even pace/)).toBeNull();

  rerender({ windows, now, showPaceDetail: true });
  expect(screen.getByText("May run out about 2h before reset")).toBeTruthy();
  expect(screen.getByText("Using quota faster than an even pace (+70 points)")).toBeTruthy();
});

it("exposes each percent window as a meter that names remaining once", () => {
  render(QuotaWindows, {
    windows: [
      { id: "weekly_a", title: "Weekly", used_percent: 10 },
      {
        id: "included",
        title: "Included",
        used_percent: 68.75,
        remaining_value: 12.5,
        limit_value: 40,
        value_unit: "usd",
      },
    ],
  });

  const meter = screen.getByRole("meter", { name: "Weekly 90%" });
  expect(meter.getAttribute("aria-valuenow")).toBe("90");
  expect(meter.getAttribute("aria-valuemin")).toBe("0");
  expect(meter.getAttribute("aria-valuemax")).toBe("100");
  expect(meter.querySelector(".quota-window-remaining")?.getAttribute("aria-hidden")).toBe("true");
  expect(screen.queryByRole("meter", { name: /Included/ })).toBeNull();
  expect(screen.getByText("$12.50 of $40.00")).toBeTruthy();
});

it("drops the reset line once the refill instant has passed", () => {
  const windows = [
    {
      id: "weekly",
      title: "Weekly",
      used_percent: 42,
      resets_at: "2026-08-12T10:00:00Z",
    },
  ];
  const { rerender } = render(QuotaWindows, {
    windows,
    now: new Date("2026-08-12T09:59:00Z"),
  });
  expect(screen.getByText("Resets in 1m")).toBeTruthy();

  rerender({ windows, now: new Date("2026-08-12T10:00:01Z") });
  expect(screen.queryByText(/Resets/)).toBeNull();
});
