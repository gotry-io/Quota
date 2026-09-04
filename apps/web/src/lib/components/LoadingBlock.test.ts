import { cleanup, render } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import LoadingBlock from "./LoadingBlock.svelte";

afterEach(cleanup);

it("marks the skeleton busy", () => {
  const { container } = render(LoadingBlock, { lines: 3, label: "Loading Usage activity" });
  const block = container.querySelector("[aria-busy='true']");
  expect(block).not.toBeNull();
  expect(block?.getAttribute("aria-busy")).toBe("true");
  expect(block?.getAttribute("aria-label")).toBe("Loading Usage activity");
  expect(container.querySelectorAll(".loading-block-line")).toHaveLength(3);
});
