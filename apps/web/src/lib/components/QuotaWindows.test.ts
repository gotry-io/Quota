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
