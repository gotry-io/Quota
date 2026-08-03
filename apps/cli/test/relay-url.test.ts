import { describe, expect, it } from "vitest";
import { canonicalRelayUrl, DEFAULT_RELAY_URL } from "../src/relay/url.ts";

describe("relay Relay URL", () => {
  it("uses and canonicalizes the managed Relay origin", () => {
    expect(canonicalRelayUrl()).toBe(DEFAULT_RELAY_URL);
    expect(canonicalRelayUrl("https://relay.example.com/")).toBe("https://relay.example.com");
    expect(canonicalRelayUrl("https://relay.example.com:443")).toBe("https://relay.example.com");
  });

  it.each([
    " https://relay.example.com",
    "https://relay.example.com ",
    "https://user@relay.example.com",
    "https://user:secret@relay.example.com",
    "https://relay.example.com/api",
    "https://relay.example.com/./",
    "https://relay.example.com/api/..",
    "https://relay.example.com/%2e",
    "https://relay.example.com?owner=secret",
    "https://relay.example.com?",
    "https://relay.example.com#secret",
    "https://relay.example.com#",
    "ftp://relay.example.com",
    "relay.example.com",
    "https:relay.example.com",
    "https:\\\\relay.example.com",
    "http://relay.example.com",
    "http://127.0.0.2",
  ])("rejects unsafe Relay URL %s", (url) => {
    expect(() => canonicalRelayUrl(url)).toThrow();
  });

  it.each([
    ["http://localhost/", "http://localhost"],
    ["http://127.0.0.1:8787/", "http://127.0.0.1:8787"],
    ["http://[::1]:8787/", "http://[::1]:8787"],
  ])("allows loopback HTTP for development", (url, expected) => {
    expect(canonicalRelayUrl(url)).toBe(expected);
  });
});
