import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import PlatformIcon from "./PlatformIcon.svelte";

afterEach(cleanup);

it("names each platform a Device can report, and Unknown for anything else", () => {
  const mac = render(PlatformIcon, { platform: "macos" });
  expect(screen.getByRole("img", { name: "macOS" })).toBeTruthy();
  mac.unmount();

  const phone = render(PlatformIcon, { platform: "ios" });
  expect(screen.getByRole("img", { name: "iOS" })).toBeTruthy();
  phone.unmount();

  render(PlatformIcon, { platform: "linux" });
  expect(screen.getByRole("img", { name: "Unknown" })).toBeTruthy();
});
