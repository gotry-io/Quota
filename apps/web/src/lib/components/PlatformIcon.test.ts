import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import PlatformIcon from "./PlatformIcon.svelte";

afterEach(cleanup);

it("names macOS for macos and Unknown for anything else", () => {
  const mac = render(PlatformIcon, { platform: "macos" });
  expect(screen.getByRole("img", { name: "macOS" })).toBeTruthy();
  mac.unmount();

  render(PlatformIcon, { platform: "linux" });
  expect(screen.getByRole("img", { name: "Unknown" })).toBeTruthy();
});
