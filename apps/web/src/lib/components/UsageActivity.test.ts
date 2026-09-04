import type { UsageActivityDayRead, UsageCostOutcome } from "@gotry-io/quota-protocol";
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import UsageActivity from "./UsageActivity.svelte";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function totals(input: number, output: number, messages = 1) {
  return {
    total_tokens: input + output,
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages,
  };
}

function cost(overrides: Partial<UsageCostOutcome> = {}): UsageCostOutcome {
  return {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: "1230000",
    catalog_revision: null,
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
    ...overrides,
  };
}

function day(
  date: string,
  input: number,
  output: number,
  dayCost: UsageCostOutcome,
  extra: Partial<UsageActivityDayRead> = {},
): UsageActivityDayRead {
  return { date, totals: totals(input, output), cost: dayCost, partial: false, ...extra };
}

function rover(container: HTMLElement): HTMLButtonElement {
  const button = container.querySelector("button.usage-activity-cell[tabindex='0']");
  if (!(button instanceof HTMLButtonElement)) {
    throw new Error("expected one active activity cell");
  }
  return button;
}

function handlers() {
  return {
    onSelectDate: vi.fn(),
    onClose: vi.fn(),
    onRetryDetail: vi.fn(),
  };
}

const range = { from: "2026-01-15", to: "2026-02-20" };
const reported = [
  day("2026-01-15", 100, 20, cost()),
  day("2026-02-12", 50, 10, cost(), { partial: true }),
];

it("keeps a single tab stop and moves with the activity keys", () => {
  const { container } = render(UsageActivity, {
    days: reported,
    range,
    ...handlers(),
  });

  expect(container.querySelectorAll("button.usage-activity-cell[tabindex='0']")).toHaveLength(1);
  expect(
    container.querySelectorAll("button.usage-activity-cell[tabindex='-1']").length,
  ).toBeGreaterThan(1);
  expect(rover(container).getAttribute("data-date")).toBe("2026-02-20");

  rover(container).focus();
  fireEvent.keyDown(rover(container), { key: "ArrowLeft" });
  expect(rover(container).getAttribute("data-date")).toBe("2026-02-19");
  expect(document.activeElement).toBe(rover(container));

  fireEvent.keyDown(rover(container), { key: "ArrowUp" });
  expect(rover(container).getAttribute("data-date")).toBe("2026-02-12");

  fireEvent.keyDown(rover(container), { key: "Home" });
  expect(rover(container).getAttribute("data-date")).toBe("2026-02-08");

  fireEvent.keyDown(rover(container), { key: "End" });
  expect(rover(container).getAttribute("data-date")).toBe("2026-02-14");

  fireEvent.keyDown(rover(container), { key: "PageUp" });
  expect(rover(container).getAttribute("data-date")).toBe("2026-01-15");
});

it("opens the focused day with Enter or Space", () => {
  const events = handlers();
  const { container } = render(UsageActivity, {
    days: reported,
    range,
    ...events,
  });

  rover(container).focus();
  fireEvent.keyDown(rover(container), { key: "Enter" });
  expect(events.onSelectDate).toHaveBeenCalledWith("2026-02-20");

  fireEvent.keyDown(rover(container), { key: " " });
  expect(events.onSelectDate).toHaveBeenCalledWith("2026-02-20");
});

it("opens the day panel and returns focus on Close", () => {
  const events = handlers();
  const detail: UsageActivityDayRead = {
    ...day("2026-01-15", 100, 20, cost()),
    agents: [
      {
        agent: "codex",
        providers: [
          {
            provider: "openai",
            models: [
              {
                model: "gpt-5",
                totals: totals(80, 20),
                cost: cost(),
              },
            ],
          },
        ],
      },
    ],
  };
  const { container } = render(UsageActivity, {
    days: reported,
    range,
    selectedDate: "2026-01-15",
    detail,
    detailLoading: false,
    ...events,
  });

  expect(rover(container).getAttribute("data-date")).toBe("2026-01-15");
  expect(
    container
      .querySelector("button.usage-activity-cell[aria-pressed='true']")
      ?.getAttribute("data-date"),
  ).toBe("2026-01-15");
  expect(screen.getByRole("heading", { name: "January 15, 2026" })).toBeTruthy();
  expect(screen.getByText("UTC")).toBeTruthy();
  expect(screen.getByRole("rowheader", { name: "Codex" })).toBeTruthy();
  expect(screen.getByRole("rowheader", { name: "gpt-5" })).toBeTruthy();

  const selected = container.querySelector('button.usage-activity-cell[data-date="2026-01-15"]');
  fireEvent.click(screen.getByRole("button", { name: "Close" }));
  expect(events.onClose).toHaveBeenCalledTimes(1);
  expect(document.activeElement).toBe(selected);
});

it("states an empty day, incomplete hours, loading, and retry", () => {
  const events = handlers();
  const empty = render(UsageActivity, {
    days: reported,
    range,
    selectedDate: "2026-01-15",
    detail: day("2026-01-15", 0, 0, cost()),
    detailLoading: false,
    ...events,
  });
  expect(screen.getByText("No Usage on this day.")).toBeTruthy();
  empty.unmount();

  const partial = render(UsageActivity, {
    days: reported,
    range,
    selectedDate: "2026-02-12",
    detailLoading: true,
    ...events,
  });
  expect(screen.getByText("Some hours on this day were scanned incompletely.")).toBeTruthy();
  expect(screen.getByRole("status", { name: "Loading this day's Usage" })).toBeTruthy();
  partial.unmount();

  render(UsageActivity, {
    days: reported,
    range,
    selectedDate: "2026-01-15",
    detailLoading: false,
    detailError: {
      status: "unavailable",
      message: "Quota couldn't load this. Retry.",
      action: { type: "retry" },
    },
    ...events,
  });
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  expect(events.onRetryDetail).toHaveBeenCalledTimes(1);
});

it("follows keyboard focus with the tooltip", () => {
  const { container } = render(UsageActivity, {
    days: reported,
    range,
    ...handlers(),
  });
  const cell = rover(container);
  cell.focus();
  fireEvent.focusIn(cell);
  expect(container.querySelector(".usage-activity-tooltip")?.textContent).toContain(
    "February 20, 2026",
  );

  fireEvent.keyDown(rover(container), { key: "ArrowLeft" });
  expect(container.querySelector(".usage-activity-tooltip")?.textContent).toContain(
    "February 19, 2026",
  );
});
