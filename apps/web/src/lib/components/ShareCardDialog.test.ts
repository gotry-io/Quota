import type { PublicUsageResponse } from "@gotry-io/quota-protocol";
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import ShareCardDialog from "./ShareCardDialog.svelte";

beforeEach(() => {
  // jsdom has no top layer and no canvas: the dialog and the drawing are stubbed so this test
  // is about the wiring — which control opens what, and what the clipboard receives.
  HTMLDialogElement.prototype.showModal = vi.fn(function showModal(this: HTMLDialogElement) {
    this.open = true;
  });
  HTMLDialogElement.prototype.close = vi.fn(function close(this: HTMLDialogElement) {
    this.open = false;
  });
  HTMLCanvasElement.prototype.getContext = vi.fn(() => null);
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it("opens the card on Share and closes it again", async () => {
  const { container } = render(ShareCardDialog, { profile: profile() });
  const dialog = container.querySelector("dialog");

  expect(dialog?.open).toBe(false);
  await fireEvent.click(screen.getByRole("button", { name: "Share" }));
  expect(dialog?.open).toBe(true);

  await fireEvent.click(screen.getByRole("button", { name: "Close" }));
  expect(dialog?.open).toBe(false);
});

it("copies the page's own URL, and says so once", async () => {
  const writeText = vi.fn(async () => {});
  vi.stubGlobal("navigator", { ...navigator, clipboard: { writeText } });

  render(ShareCardDialog, { profile: profile() });
  await fireEvent.click(screen.getByRole("button", { name: "Share" }));
  await fireEvent.click(screen.getByRole("button", { name: "Copy link" }));

  expect(writeText).toHaveBeenCalledWith("https://quota.gotry.io/u/kyle");
  expect(await screen.findByRole("button", { name: "Copied" })).toBeTruthy();
});

function profile(): PublicUsageResponse {
  return {
    protocol_version: 6,
    handle: "kyle",
    published_at: "2026-06-01T09:00:00Z",
    generated_at: "2026-09-06T12:00:00Z",
    last_30_days: {
      totals: { total_tokens: 12, input_tokens: 10, output_tokens: 2, messages: 1 },
      providers: [{ provider: "openai", total_tokens: 12, share_permille: 1_000 }],
    },
    all: {
      totals: { total_tokens: 12, input_tokens: 10, output_tokens: 2, messages: 1 },
      providers: [{ provider: "openai", total_tokens: 12, share_permille: 1_000 }],
    },
    activity: [{ date: "2026-09-06", level: 4 }],
  };
}
