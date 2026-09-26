import { cleanup, render, screen } from "@testing-library/svelte";
import { createRawSnippet } from "svelte";
import { afterEach, expect, it } from "vitest";
import PageHeader from "./PageHeader.svelte";

afterEach(cleanup);

it("reads as one sentence and draws only the reader's numbers in ink", () => {
  render(PageHeader, {
    children: createRawSnippet(() => ({
      render: () => "<span>You ran <b>1.2M tokens</b> through <b>4 models</b> today.</span>",
    })),
  });

  const heading = screen.getByRole("heading", { level: 1 });
  expect(heading.textContent).toBe("You ran 1.2M tokens through 4 models today.");
  const numbers = heading.querySelectorAll("b");
  expect(numbers).toHaveLength(2);
  expect(getComputedStyle(heading).color).toBe("var(--body)");
  for (const number of numbers) expect(getComputedStyle(number).color).toBe("var(--ink)");
});
