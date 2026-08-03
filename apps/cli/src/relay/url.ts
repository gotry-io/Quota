export const DEFAULT_RELAY_URL = "https://quota.gotry.io";

const loopbackHostnames = new Set(["localhost", "127.0.0.1", "[::1]"]);

export class RelayUrlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RelayUrlError";
  }
}

export function canonicalRelayUrl(value = DEFAULT_RELAY_URL): string {
  if (value.trim() !== value) {
    throw new RelayUrlError("Relay URL must not have surrounding whitespace.");
  }

  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new RelayUrlError("Relay URL is invalid.");
  }

  const schemeSeparator = value.indexOf("://");
  if (
    schemeSeparator < 1 ||
    value.slice(0, schemeSeparator).toLowerCase() !== url.protocol.slice(0, -1)
  ) {
    throw new RelayUrlError("Relay URL must include an explicit HTTP or HTTPS scheme.");
  }

  if (url.username || url.password) {
    throw new RelayUrlError("Relay URL must not contain credentials.");
  }
  if (url.search || url.hash || url.href.includes("?") || url.href.includes("#")) {
    throw new RelayUrlError("Relay URL must not contain a query or fragment.");
  }
  const authorityAndPath = value.slice(schemeSeparator + 3);
  const rawPathStart = authorityAndPath.indexOf("/");
  const rawPath = rawPathStart === -1 ? "" : authorityAndPath.slice(rawPathStart);
  if (url.pathname !== "/" || (rawPath !== "" && rawPath !== "/")) {
    throw new RelayUrlError("Relay URL must use the origin root without a path.");
  }
  if (url.protocol === "http:") {
    if (!loopbackHostnames.has(url.hostname.toLowerCase())) {
      throw new RelayUrlError(
        "Relay URL must use HTTPS unless it is a loopback development address.",
      );
    }
  } else if (url.protocol !== "https:") {
    throw new RelayUrlError("Relay URL must use HTTPS.");
  }

  return url.origin;
}
