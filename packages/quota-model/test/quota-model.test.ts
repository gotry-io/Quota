import { describe, expect, it } from "vitest";
import { remainingPercent } from "../src/index.ts";

describe("remainingPercent", () => {
  it("converts and clamps provider usage", () => {
    expect(remainingPercent(25)).toBe(75);
    expect(remainingPercent(-2)).toBe(100);
    expect(remainingPercent(120)).toBe(0);
  });
});
