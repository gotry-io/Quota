import { cleanup, render } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import DeviceSummary from "./DeviceSummary.svelte";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

it("states each device as a name, verdict, and the age that verdict came from", () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T09:40:00Z"));

  const { container } = render(DeviceSummary, {
    devices: [
      {
        id: "device_1",
        display_name: "Studio",
        last_seen_at: "2026-08-12T09:31:00Z",
        last_observed_at: "2026-08-12T09:30:00Z",
      },
      {
        id: "device_2",
        display_name: "Laptop",
        last_seen_at: "2026-08-12T02:00:00Z",
        last_observed_at: "2026-08-12T02:00:00Z",
      },
    ],
  });

  const lines = [...container.querySelectorAll("li")].map((item) => item.textContent);
  expect(lines).toEqual([
    "Studio · Active · last reading 9m ago",
    "Laptop · Idle · last reading 7h ago",
  ]);
});
