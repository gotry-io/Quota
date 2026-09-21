import { beforeEach, describe, expect, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createRelayApp } from "../src/app.ts";
import {
  addressIsTrusted,
  applyNodeForwardedTrust,
  clientAddress,
  DEFAULT_CLIENT_ADDRESS_HEADER,
  DEFAULT_TRUSTED_PROXIES,
  parseClientAddressHeader,
  parseTrustedProxies,
} from "../src/platform/client-address.ts";
import type { RelayDatabase } from "../src/platform/database.ts";
import { SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";
import { testDatabase } from "./support/database.ts";
import { SignedInWebSessionStub } from "./web-session-stub.ts";

const origin = "https://quota.gotry.io";
const now = new Date("2026-08-10T00:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const defaultTrusted = parseTrustedProxies(undefined);

let db: RelayDatabase;

beforeEach(async () => {
  db = await testDatabase();
  await db.batch([db.prepare("DELETE FROM rate_limit_counters")]);
});

describe("parseTrustedProxies", () => {
  it("defaults to loopback, RFC1918, and unique-local IPv6 when unset or empty", () => {
    expect(parseTrustedProxies(undefined)).toEqual(parseTrustedProxies(DEFAULT_TRUSTED_PROXIES));
    expect(parseTrustedProxies("")).toEqual(parseTrustedProxies(DEFAULT_TRUSTED_PROXIES));
    expect(parseTrustedProxies("  ")).toEqual(parseTrustedProxies(DEFAULT_TRUSTED_PROXIES));
    expect(addressIsTrusted("127.0.0.1", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("::1", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("10.1.2.3", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("172.18.0.4", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("192.168.1.9", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("fd12:3456::1", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("203.0.113.9", defaultTrusted)).toBe(false);
    expect(addressIsTrusted("8.8.8.8", defaultTrusted)).toBe(false);
  });

  it("matches an IPv4-mapped IPv6 peer against an IPv4 CIDR", () => {
    expect(addressIsTrusted("::ffff:10.0.0.2", defaultTrusted)).toBe(true);
    expect(addressIsTrusted("::ffff:203.0.113.9", defaultTrusted)).toBe(false);
    const onlyPrivate = parseTrustedProxies("10.0.0.0/8");
    expect(addressIsTrusted("::FFFF:10.9.8.7", onlyPrivate)).toBe(true);
  });

  it("refuses a list that is not CIDRs or addresses", () => {
    for (const source of ["nope", "10.0.0.0/99", "10.0.0.0/8,", "10.0.0.0/8, ", "2001:db8::/129"]) {
      expect(() => parseTrustedProxies(source), source).toThrow(/invalid RELAY_TRUSTED_PROXIES/);
    }
  });
});

describe("clientAddress", () => {
  it("takes CF-Connecting-IP before X-Forwarded-For", () => {
    const headers = new Headers({
      "CF-Connecting-IP": "203.0.113.10",
      "X-Forwarded-For": "198.51.100.1, 203.0.113.10, 172.16.0.2",
    });
    expect(clientAddress(headers, defaultTrusted)).toBe("203.0.113.10");
  });

  it("takes the right-most X-Forwarded-For hop that is not a trusted proxy", () => {
    const headers = new Headers({
      "X-Forwarded-For": "198.51.100.1, 203.0.113.10, 172.16.0.2",
    });
    expect(clientAddress(headers, defaultTrusted)).toBe("203.0.113.10");
  });
});

describe("applyNodeForwardedTrust", () => {
  it("ignores a forged CF-Connecting-IP from an untrusted peer", () => {
    const request = new Request(`${origin}/healthz`, {
      headers: {
        "CF-Connecting-IP": "198.51.100.1",
        "X-Forwarded-For": "198.51.100.1",
        "X-Real-IP": "198.51.100.1",
        Forwarded: "for=198.51.100.1",
      },
    });
    applyNodeForwardedTrust(request, "203.0.113.50", defaultTrusted);
    expect(request.headers.get("CF-Connecting-IP")).toBeNull();
    expect(request.headers.get("X-Real-IP")).toBeNull();
    expect(request.headers.get("Forwarded")).toBeNull();
    expect(request.headers.get("X-Forwarded-For")).toBe("203.0.113.50");
    expect(clientAddress(request.headers, defaultTrusted)).toBe("203.0.113.50");
  });

  it("keeps forwarding headers from a trusted peer, including a mapped IPv6 peer", () => {
    const request = new Request(`${origin}/healthz`, {
      headers: {
        "X-Forwarded-For": "198.51.100.1, 203.0.113.10, 172.16.0.2",
      },
    });
    applyNodeForwardedTrust(request, "::ffff:10.0.0.2", defaultTrusted);
    expect(request.headers.get("X-Forwarded-For")).toBe("198.51.100.1, 203.0.113.10, 172.16.0.2");
    expect(clientAddress(request.headers, defaultTrusted)).toBe("203.0.113.10");
  });

  it("ignores a forged CF-Connecting-IP from a trusted peer when the header is X-Forwarded-For", () => {
    const request = new Request(`${origin}/healthz`, {
      headers: {
        "CF-Connecting-IP": "198.51.100.1",
        "X-Forwarded-For": "198.51.100.1, 203.0.113.10, 172.16.0.2",
      },
    });
    applyNodeForwardedTrust(request, "10.0.0.2", defaultTrusted);
    expect(request.headers.get("CF-Connecting-IP")).toBeNull();
    expect(clientAddress(request.headers, defaultTrusted)).toBe("203.0.113.10");
  });

  it("honours CF-Connecting-IP from a trusted peer when that header is chosen", () => {
    const request = new Request(`${origin}/healthz`, {
      headers: {
        "CF-Connecting-IP": "198.51.100.1",
        "X-Forwarded-For": "203.0.113.10, 172.16.0.2",
      },
    });
    applyNodeForwardedTrust(request, "10.0.0.2", defaultTrusted, "cf-connecting-ip");
    expect(request.headers.get("X-Forwarded-For")).toBeNull();
    expect(clientAddress(request.headers, defaultTrusted)).toBe("198.51.100.1");
  });
});

describe("parseClientAddressHeader", () => {
  it("defaults to x-forwarded-for and refuses any other value", () => {
    expect(parseClientAddressHeader(undefined)).toBe(DEFAULT_CLIENT_ADDRESS_HEADER);
    expect(parseClientAddressHeader("")).toBe("x-forwarded-for");
    expect(parseClientAddressHeader("  cf-connecting-ip  ")).toBe("cf-connecting-ip");
    expect(parseClientAddressHeader("X-Forwarded-For")).toBe("x-forwarded-for");
    for (const source of ["x-real-ip", "forwarded", "true", "cf-connecting-ip,x-forwarded-for"]) {
      expect(() => parseClientAddressHeader(source), source).toThrow(
        /invalid RELAY_CLIENT_ADDRESS_HEADER/,
      );
    }
  });
});

describe("anonymous rate-limit identity", () => {
  it("puts two forged identities from one untrusted peer in one bucket", async () => {
    const state = new D1AccountState(db);
    const hasher = new SecretHasher(secret);
    const app = createRelayApp({
      state,
      usageState: new D1UsageState(db),
      accountService: new AccountService(state, hasher, secret),
      webSessions: new SignedInWebSessionStub("account_addr", now),
      hasher,
      now: () => now,
    });
    const peer = "203.0.113.50";
    const hit = async (forged: string) => {
      const request = new Request(`${origin}/oauth/v2/complete?login_token=guess`, {
        headers: {
          "CF-Connecting-IP": forged,
          "X-Forwarded-For": forged,
        },
      });
      applyNodeForwardedTrust(request, peer, defaultTrusted);
      return app.request(request);
    };

    let limited: Response | null = null;
    for (let attempt = 0; attempt < 31 && limited === null; attempt += 1) {
      const response = await hit("198.51.100.1");
      if (response.status === 429) limited = response;
    }
    expect(limited?.status).toBe(429);
    expect((await hit("198.51.100.2")).status).toBe(429);
  });
});
