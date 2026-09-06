import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createWebDocumentPort } from "../src/account/web-document-port.ts";
import { GitHubIdentityProvider } from "../src/account/github-identity.ts";
import { SignInHandoff } from "../src/account/identity.ts";
import { WebSessions } from "../src/account/web-session.ts";
import { createRelayApp } from "../src/app.ts";
import { encodeBase64UrlJSON, SecretHasher } from "../src/security.ts";
import { D1AccountState } from "../src/state/d1-account-state.ts";
import { D1UsageState } from "../src/state/d1-usage-state.ts";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
    }
  }
}

declare module "vitest" {
  export interface ProvidedContext {
    TEST_MIGRATIONS: D1Migration[];
  }
}

const now = new Date("2026-08-10T00:00:00.000Z");
const secret = "test-secret-that-is-long-enough-for-hmac-and-aes";
const origin = "https://quota.gotry.io";
const githubProfileId = 583_231;

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
  // Every test here signs in as the same GitHub profile, so it must start from no Account at all.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM usage_daily"),
    env.DB.prepare("DELETE FROM usage_hourly"),
    env.DB.prepare("DELETE FROM usage_hour_scans"),
    env.DB.prepare("DELETE FROM quota_snapshots"),
    env.DB.prepare("DELETE FROM sessions"),
    env.DB.prepare("DELETE FROM login_grants"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM account_identities"),
    env.DB.prepare("DELETE FROM accounts"),
    env.DB.prepare("DELETE FROM rate_limit_counters"),
    env.DB.prepare("DELETE FROM email_challenges"),
  ]);
});

describe("browser sign-in through GitHub", () => {
  it("opens a session Relay itself stores, then closes it on sign-out", async () => {
    const github = fakeGitHub();
    const relay = harness(github);

    const started = await relay.app.request(`${origin}/api/auth/github/start`);
    expect(started.status).toBe(302);
    expect(started.headers.get("cache-control")).toBe("no-store");
    const authorize = new URL(started.headers.get("location") ?? "");
    expect(`${authorize.origin}${authorize.pathname}`).toBe(
      "https://github.com/login/oauth/authorize",
    );
    expect(authorize.searchParams.get("client_id")).toBe("github-client");
    expect(authorize.searchParams.get("redirect_uri")).toBe(`${origin}/api/auth/github/callback`);
    // No scope is requested at all, and the code is bound to a verifier this browser holds.
    expect(authorize.searchParams.get("scope")).toBe("");
    expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
    expect(authorize.searchParams.get("code_challenge")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const state = authorize.searchParams.get("state") ?? "";
    expect(state).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const handoff = onlyCookie(started);
    expect(handoff.attributes).toContain("HttpOnly");
    expect(handoff.attributes).toContain("Secure");
    expect(handoff.attributes).toContain("SameSite=Lax");
    expect(handoff.attributes).toContain("Max-Age=600");
    expect(handoff.name).toBe("__Host-quota_oauth");

    const callback = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${encodeURIComponent(state)}`,
      { headers: { Cookie: `${handoff.name}=${handoff.value}` } },
    );
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe("/my");
    expect(callback.headers.get("cache-control")).toBe("no-store");
    const cookies = setCookies(callback);
    const session = cookies.get("__Host-quota_session");
    expect(session?.attributes).toContain("HttpOnly");
    expect(session?.attributes).toContain("Secure");
    expect(session?.attributes).toContain("SameSite=Lax");
    expect(session?.attributes).toContain("Path=/");
    expect(session?.value).toMatch(/^qw_[A-Za-z0-9_-]{43}$/);
    // The sign-in in flight is finished, so what carried it is cleared in the same answer.
    expect(cookies.get("__Host-quota_oauth")?.attributes).toContain("Max-Age=0");

    // The exchange named the verifier from the cookie and Relay's own callback, and asked GitHub
    // for the profile once.
    expect(github.tokenForm?.get("code")).toBe("first-code");
    expect(github.tokenForm?.get("code_verifier")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(github.tokenForm?.get("redirect_uri")).toBe(`${origin}/api/auth/github/callback`);
    expect(github.profileReads).toBe(1);

    const sessionCookie = `__Host-quota_session=${session?.value}`;
    const stored = await env.DB.prepare(
      "SELECT client_kind, device_id, refresh_token_hash, access_token_hash, authenticated_at FROM sessions",
    ).all<Record<string, unknown>>();
    expect(stored.results).toHaveLength(1);
    expect(stored.results[0]).toMatchObject({
      client_kind: "web",
      device_id: null,
      refresh_token_hash: null,
      authenticated_at: now.toISOString(),
    });
    expect(stored.results[0]?.access_token_hash).toBe(
      await new SecretHasher(secret).hash("web-access", session?.value ?? ""),
    );

    const account = await env.DB.prepare("SELECT id, display_label FROM accounts").first<{
      id: string;
      display_label: string;
    }>();
    expect(account?.display_label).toBe("octocat");
    // The Account is its own opaque id, and the identity that opened it is a row of its own
    // holding nothing but the HMAC of what GitHub proved.
    expect(account?.id).toMatch(/^account_[0-9a-f-]{36}$/);
    const identity = await env.DB.prepare(
      "SELECT account_id, provider, subject, label FROM account_identities",
    ).first<{ account_id: string; provider: string; subject: string; label: string }>();
    expect(identity).toMatchObject({
      account_id: account?.id,
      provider: "github",
      label: "octocat",
    });
    expect(identity?.subject).toMatch(/^[0-9a-f]{64}$/);
    expect(identity?.subject).not.toContain(String(githubProfileId));

    const read = await relay.app.request(`${origin}/api/v2/account`, {
      headers: { Cookie: sessionCookie },
    });
    expect(read.status).toBe(200);
    expect(await read.json()).toMatchObject({ account: { display_label: "octocat" } });

    // The document render reads the same row the API does.
    const viewer = await relay.document.getViewer(new Headers({ Cookie: sessionCookie }));
    expect(viewer).toEqual({ displayLabel: "octocat" });

    // One table, but not one credential domain: the cookie is hashed under `web-access`, and no
    // Bearer prefix names that domain, so the cookie cannot be presented as a token.
    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          headers: { Authorization: `Bearer ${session?.value}` },
        })
      ).status,
    ).toBe(401);
    expect(
      (
        await relay.app.request(`${origin}/api/v6/device/snapshots`, {
          method: "PUT",
          headers: {
            Authorization: `Bearer ${session?.value}`,
            "Content-Type": "application/json",
          },
          body: "{}",
        })
      ).status,
    ).toBe(401);

    const signedOut = await relay.app.request(`${origin}/api/auth/logout`, {
      method: "POST",
      headers: {
        Cookie: sessionCookie,
        Origin: origin,
        "Sec-Fetch-Site": "same-origin",
      },
    });
    expect(signedOut.status).toBe(200);
    expect(signedOut.headers.get("cache-control")).toBe("no-store");
    expect(setCookies(signedOut).get("__Host-quota_session")?.attributes).toContain("Max-Age=0");
    expect(
      (await relay.app.request(`${origin}/api/v2/account`, { headers: { Cookie: sessionCookie } }))
        .status,
    ).toBe(401);
    expect(await relay.document.getViewer(new Headers({ Cookie: sessionCookie }))).toBeNull();
  });

  it("accepts the issuer GitHub now names in its redirect, and only that one", async () => {
    // RFC 9207: GitHub appends `iss=https://github.com` to the authorization-code redirect.
    // A callback naming any other issuer is not GitHub's.
    for (const [issuer, status] of [
      ["https://github.com/login/oauth", 302],
      ["https://github.com", 400],
    ] as const) {
      const relay = harness(fakeGitHub());
      const started = await relay.app.request(`${origin}/api/auth/github/start`);
      const authorize = new URL(started.headers.get("location") ?? "");
      const state = authorize.searchParams.get("state") ?? "";
      const handoff = setCookies(started).get("__Host-quota_oauth");
      const callback = await relay.app.request(
        `${origin}/api/auth/github/callback?code=first-code&iss=${encodeURIComponent(issuer)}&state=${encodeURIComponent(state)}`,
        { headers: { Cookie: `${handoff?.name}=${handoff?.value}` } },
      );
      expect(callback.status, issuer).toBe(status);
    }
  });

  it("refuses a callback whose state or handoff cookie does not match", async () => {
    const github = fakeGitHub();
    const relay = harness(github);
    const started = await relay.app.request(`${origin}/api/auth/github/start`);
    const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
    const handoff = onlyCookie(started);
    const cookie = `${handoff.name}=${handoff.value}`;

    const wrongState = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${"z".repeat(43)}`,
      { headers: { Cookie: cookie } },
    );
    expect(wrongState.status).toBe(400);

    const noCookie = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${encodeURIComponent(state)}`,
    );
    expect(noCookie.status).toBe(400);

    const tamperedCookie = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${encodeURIComponent(state)}`,
      { headers: { Cookie: `${handoff.name}=${handoff.value.slice(0, -2)}ff` } },
    );
    expect(tamperedCookie.status).toBe(400);

    // Nothing reached GitHub, and no session exists to have been opened.
    expect(github.exchanges).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM sessions").first("count")).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts").first("count")).toBe(0);
  });

  it("refuses a handoff whose deadline has passed or cannot be read", async () => {
    const github = fakeGitHub();
    const clock = { at: now };
    const relay = harness(github, () => clock.at);
    const started = await relay.app.request(`${origin}/api/auth/github/start`);
    const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
    const handoff = onlyCookie(started);

    clock.at = new Date(now.getTime() + 10 * 60_000 + 1);
    const expired = await relay.app.request(
      `${origin}/api/auth/github/callback?code=late-code&state=${encodeURIComponent(state)}`,
      { headers: { Cookie: `${handoff.name}=${handoff.value}` } },
    );
    expect(expired.status).toBe(400);
    expect(github.exchanges).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM sessions").first("count")).toBe(0);

    // A deadline nothing can read is not an absent deadline: it must fail closed. This payload is
    // signed the same way Relay signs its own, so only the deadline itself is under test.
    const hasher = new SecretHasher(secret);
    const forged = encodeBase64UrlJSON({
      provider: "github",
      intent: { kind: "sign_in" },
      state,
      verifier: "a".repeat(43),
      return_to: "/my",
      expires_at: "whenever",
    });
    const sealed = `${forged}.${await hasher.hash("oauth-handoff", forged)}`;
    const unreadable = await relay.app.request(
      `${origin}/api/auth/github/callback?code=late-code&state=${encodeURIComponent(state)}`,
      { headers: { Cookie: `__Host-quota_oauth=${sealed}` } },
    );
    expect(unreadable.status).toBe(400);
    expect(github.exchanges).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM sessions").first("count")).toBe(0);
  });

  it("maps a code GitHub will not spend twice to a rejected sign-in", async () => {
    const github = fakeGitHub();
    const relay = harness(github);
    expect((await signIn(relay, "reused-code")).status).toBe(302);

    // GitHub answers a replayed code with an error body rather than a failing status.
    const replayed = await signIn(relay, "reused-code");
    expect(replayed.status).toBe(400);
    expect(await replayed.json()).toMatchObject({ error: { code: "invalid_request" } });
    expect(github.exchanges).toBe(2);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM sessions").first("count")).toBe(1);
  });

  it("keeps the GitHub access token and the session token out of storage and answers", async () => {
    const github = fakeGitHub();
    const relay = harness(github);
    const logged: string[] = [];
    const originalLog = console.log;
    const originalError = console.error;
    console.log = (value: unknown) => void logged.push(String(value));
    console.error = (value: unknown) => void logged.push(String(value));
    let callback: Response;
    try {
      callback = await signIn(relay, "quiet-code");
    } finally {
      console.log = originalLog;
      console.error = originalError;
    }
    const session = setCookies(callback).get("__Host-quota_session")?.value ?? "";
    expect(session).toBeTruthy();

    const read = await relay.app.request(`${origin}/api/v2/account`, {
      headers: { Cookie: `__Host-quota_session=${session}` },
    });
    const body = await read.text();
    expect(body).not.toContain(session);
    expect(body).not.toContain(github.accessToken);
    expect(logged.join("\n")).not.toContain(session);
    expect(logged.join("\n")).not.toContain(github.accessToken);

    const tables = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'",
    ).all<{ name: string }>();
    for (const { name } of tables.results) {
      const rows = JSON.stringify((await env.DB.prepare(`SELECT * FROM "${name}"`).all()).results);
      expect(rows).not.toContain(github.accessToken);
      expect(rows).not.toContain(session);
    }
  });

  it("refuses a return the browser could not have reached on this origin", async () => {
    const relay = harness(fakeGitHub());
    for (const returnTo of [
      "https://attacker.invalid/",
      "//attacker.invalid/",
      "/my\\@attacker.invalid",
      "my",
    ]) {
      expect(
        (
          await relay.app.request(
            `${origin}/api/auth/github/start?return_to=${encodeURIComponent(returnTo)}`,
          )
        ).status,
      ).toBe(400);
    }
    expect((await relay.app.request(`${origin}/api/auth/github/start?unexpected=1`)).status).toBe(
      400,
    );

    const deepLink = await relay.app.request(
      `${origin}/api/auth/github/start?return_to=${encodeURIComponent("/my?device=device_1")}`,
    );
    expect(deepLink.status).toBe(302);
  });

  it("checks the return path again at the redirect that spends it", async () => {
    const relay = harness(fakeGitHub());
    const started = await relay.app.request(`${origin}/api/auth/github/start`);
    const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
    const handoff = onlyCookie(started);
    // A handoff sealed with a target the start route would have refused. Relay signs this cookie,
    // so nothing outside can forge one — and the callback still refuses to send the browser there,
    // because the value has left this Worker and come back before becoming a `Location`.
    const forged = await sealedHandoff({
      provider: "github",
      intent: { kind: "sign_in" },
      state,
      verifier: "x".repeat(43),
      return_to: "https://attacker.invalid/",
      expires_at: new Date(now.getTime() + 60_000).toISOString(),
    });
    const callback = await relay.app.request(
      `${origin}/api/auth/github/callback?code=forged-return&state=${encodeURIComponent(state)}`,
      { headers: { Cookie: `${handoff.name}=${forged}` } },
    );
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe("/my");
  });

  it("answers HTML sign-in failures when Accept names HTML and keeps JSON otherwise", async () => {
    const relay = harness(fakeGitHub());
    const secretToken = "guess-login-token-must-not-leak";

    const jsonComplete = await relay.app.request(
      `${origin}/oauth/v2/complete?login_token=${encodeURIComponent(secretToken)}`,
    );
    expect(jsonComplete.status).toBe(401);
    expect(jsonComplete.headers.get("content-type")).toMatch(/application\/json/);
    expect(await jsonComplete.json()).toMatchObject({ error: { code: "unauthorized" } });

    const htmlComplete = await relay.app.request(
      `${origin}/oauth/v2/complete?login_token=${encodeURIComponent(secretToken)}`,
      { headers: { Accept: "text/html,application/xhtml+xml" } },
    );
    expect(htmlComplete.status).toBe(200);
    expect(htmlComplete.headers.get("content-type")).toMatch(/text\/html/);
    const completeBody = await htmlComplete.text();
    expect(completeBody).toContain("Sign-in didn't finish");
    expect(completeBody).toContain("no_session");
    expect(completeBody).toContain("Return to Quota and try again.");
    expect(completeBody).not.toContain(secretToken);

    const jsonCallback = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${"z".repeat(43)}`,
    );
    expect(jsonCallback.status).toBe(400);
    expect(jsonCallback.headers.get("content-type")).toMatch(/application\/json/);

    const htmlCallback = await relay.app.request(
      `${origin}/api/auth/github/callback?code=first-code&state=${"z".repeat(43)}`,
      { headers: { Accept: "text/html" } },
    );
    expect(htmlCallback.status).toBe(200);
    expect(htmlCallback.headers.get("content-type")).toMatch(/text\/html/);
    const callbackBody = await htmlCallback.text();
    expect(callbackBody).toContain("no_session");
    expect(callbackBody).toContain("Sign-in didn't finish");

    const jsonInvalid = await relay.app.request(
      `${origin}/oauth/v2/complete?login_token=x&extra=1`,
    );
    expect(jsonInvalid.status).toBe(400);

    const htmlInvalid = await relay.app.request(
      `${origin}/oauth/v2/complete?login_token=x&extra=1`,
      { headers: { Accept: "text/html" } },
    );
    expect(htmlInvalid.status).toBe(200);
    expect(await htmlInvalid.text()).toContain("invalid_request");
  });

  it("rate-limits the browser round trip at both ends", async () => {
    const relay = harness(fakeGitHub());
    const request = (path: string) =>
      relay.app.request(`${origin}${path}`, { headers: { "CF-Connecting-IP": "203.0.113.7" } });

    // The two ends share one class and one subject, so exhausting either exhausts both: the
    // completion route is the only thing that turns a login token into an authorization code.
    let limited: Response | null = null;
    for (let attempt = 0; attempt < 31 && limited === null; attempt += 1) {
      const response = await request("/oauth/v2/complete?login_token=guess");
      if (response.status === 429) limited = response;
    }
    expect(limited?.status).toBe(429);
    expect(limited?.headers.get("Retry-After")).toMatch(/^\d+$/);
    expect((await request("/api/auth/github/start")).status).toBe(429);

    const htmlLimited = await relay.app.request(`${origin}/oauth/v2/complete?login_token=guess`, {
      headers: { Accept: "text/html", "CF-Connecting-IP": "203.0.113.7" },
    });
    expect(htmlLimited.status).toBe(200);
    expect(htmlLimited.headers.get("content-type")).toMatch(/text\/html/);
    expect(await htmlLimited.text()).toContain("rate_limited");
  });

  it("requires a same-origin request to sign out or delete the Account", async () => {
    const github = fakeGitHub();
    const relay = harness(github);
    const session = setCookies(await signIn(relay, "same-origin-code")).get(
      "__Host-quota_session",
    )?.value;
    const cookie = `__Host-quota_session=${session}`;

    expect(
      (
        await relay.app.request(`${origin}/api/auth/logout`, {
          method: "POST",
          headers: { Cookie: cookie },
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await relay.app.request(`${origin}/api/auth/logout`, {
          method: "POST",
          headers: { Cookie: cookie, Origin: "https://attacker.invalid" },
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          method: "DELETE",
          headers: { Cookie: cookie, "Sec-Fetch-Site": "cross-site", Origin: origin },
        })
      ).status,
    ).toBe(403);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts").first("count")).toBe(1);
  });

  it("refuses a destructive Web action once the sign-in is no longer recent", async () => {
    const github = fakeGitHub();
    const clock = { at: now };
    const relay = harness(github, () => clock.at);
    const session = setCookies(await signIn(relay, "stale-code")).get(
      "__Host-quota_session",
    )?.value;
    clock.at = new Date(now.getTime() + 10 * 60_000 + 1);

    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          method: "DELETE",
          headers: {
            Cookie: `__Host-quota_session=${session}`,
            Origin: origin,
            "Sec-Fetch-Site": "same-origin",
          },
        })
      ).status,
    ).toBe(403);
    // Reading is still allowed: only the destructive action needs a recent sign-in.
    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          headers: { Cookie: `__Host-quota_session=${session}` },
        })
      ).status,
    ).toBe(200);
  });

  it("deletes the Account, its Devices, and everything stored for them in one batch", async () => {
    const github = fakeGitHub();
    const relay = harness(github);
    const session = setCookies(await signIn(relay, "delete-code")).get(
      "__Host-quota_session",
    )?.value;
    const accountId = String(await env.DB.prepare("SELECT id FROM accounts").first("id"));
    await seedDeviceData(accountId);

    const deleted = await relay.app.request(`${origin}/api/v2/account`, {
      method: "DELETE",
      headers: {
        Cookie: `__Host-quota_session=${session}`,
        Origin: origin,
        "Sec-Fetch-Site": "same-origin",
      },
    });
    expect(deleted.status).toBe(204);
    expect(setCookies(deleted).get("__Host-quota_session")?.attributes).toContain("Max-Age=0");

    for (const table of [
      "accounts",
      "account_identities",
      "sessions",
      "devices",
      "quota_snapshots",
      "usage_hourly",
      "usage_hour_scans",
      "usage_daily",
      "login_grants",
    ]) {
      expect(await env.DB.prepare(`SELECT COUNT(*) AS count FROM "${table}"`).first("count")).toBe(
        0,
      );
    }
    // The cookie names a session that no longer exists, so it authenticates nothing.
    expect(
      (
        await relay.app.request(`${origin}/api/v2/account`, {
          headers: { Cookie: `__Host-quota_session=${session}` },
        })
      ).status,
    ).toBe(401);
  });
});

describe("an Account owns the identities that reach it", () => {
  it("opens one Account on a first sign-in and reaches the same one on the next", async () => {
    const relay = harness(fakeGitHub());
    const first = setCookies(await signIn(relay, "first-visit")).get("__Host-quota_session")?.value;

    const read = await relay.app.request(`${origin}/api/v2/account`, {
      headers: { Cookie: `__Host-quota_session=${first}` },
    });
    expect(read.status).toBe(200);
    expect(await read.json()).toMatchObject({
      account: { display_label: "octocat" },
      identities: [{ provider: "github", label: "octocat", linked_at: now.toISOString() }],
    });

    // The same GitHub profile is the same identity, so it reaches the Account it opened rather
    // than opening a second one.
    const second = setCookies(await signIn(relay, "return-visit")).get(
      "__Host-quota_session",
    )?.value;
    expect(second).not.toBe(first);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts").first("count")).toBe(1);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM account_identities").first("count"),
    ).toBe(1);

    // A renamed GitHub login is the same subject, and the Account is called what that channel
    // calls it now.
    const renamed = harness(fakeGitHub({ id: githubProfileId, login: "octocat-renamed" }));
    expect((await signIn(renamed, "renamed-visit")).status).toBe(302);
    expect(await env.DB.prepare("SELECT display_label FROM accounts").first("display_label")).toBe(
      "octocat-renamed",
    );
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM accounts").first("count")).toBe(1);
  });

  it("binds another channel to the Account that asked, and does it once", async () => {
    const relay = harness(fakeGitHub());
    const session = await seedAccountReachedByEmail("account_link", "linked@example.test");
    const cookie = `__Host-quota_session=${session}`;

    const linked = await linkGitHub(relay, cookie, "link-code");
    expect(linked.status).toBe(302);
    expect(linked.headers.get("location")).toBe("/my");
    // Linking opens no session: the browser keeps the one it arrived with.
    expect(setCookies(linked).get("__Host-quota_session")).toBeUndefined();
    expect(await identityProviders("account_link")).toEqual(["email", "github"]);
    // The Account is still called what the channel that opened it calls it.
    expect(await displayLabel("account_link")).toBe("linked@example.test");

    // Binding the same channel again is the state it is already in, so it succeeds and writes
    // nothing new.
    expect((await linkGitHub(relay, cookie, "link-again")).status).toBe(302);
    expect(await identityProviders("account_link")).toEqual(["email", "github"]);

    // A browser with no session has no Account to bind a channel to.
    expect((await relay.app.request(`${origin}/api/auth/github/start?intent=link`)).status).toBe(
      401,
    );
  });

  it("refuses a channel that is already how another Account is reached", async () => {
    const relay = harness(fakeGitHub());
    // Somebody already signs in with this GitHub profile.
    expect((await signIn(relay, "owner-code")).status).toBe(302);
    const session = await seedAccountReachedByEmail("account_taken", "taken@example.test");
    const cookie = `__Host-quota_session=${session}`;

    const refused = await linkGitHub(relay, cookie, "taken-code");
    expect(refused.status).toBe(409);
    expect(await refused.json()).toMatchObject({ error: { code: "conflict" } });
    // Nothing moved: the identity still belongs to the Account that had it.
    expect(await identityProviders("account_taken")).toEqual(["email"]);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM account_identities").first("count"),
    ).toBe(2);

    const asHtml = await linkGitHub(relay, cookie, "taken-again", { Accept: "text/html" });
    expect(asHtml.status).toBe(200);
    const page = await asHtml.text();
    expect(page).toContain("identity_taken");
    expect(page).toContain("That GitHub account is already linked to another Quota account.");
  });

  it("keeps the last way into an Account", async () => {
    const relay = harness(fakeGitHub());
    const session = setCookies(await signIn(relay, "unlink-code")).get(
      "__Host-quota_session",
    )?.value;
    const accountId = String(await env.DB.prepare("SELECT id FROM accounts").first("id"));
    const unlink = (provider: string) =>
      relay.app.request(`${origin}/api/v2/account/identities/${provider}`, {
        method: "DELETE",
        headers: {
          Cookie: `__Host-quota_session=${session}`,
          Origin: origin,
          "Sec-Fetch-Site": "same-origin",
        },
      });

    const refused = await unlink("github");
    expect(refused.status).toBe(409);
    expect(await refused.json()).toMatchObject({ error: { code: "conflict" } });
    expect(await identityProviders(accountId)).toEqual(["github"]);

    // A channel Relay speaks but this Account does not hold is not there to unbind.
    expect((await unlink("apple")).status).toBe(404);
    // One it has never heard of is not a channel at all.
    expect((await unlink("carrier-pigeon")).status).toBe(404);

    await env.DB.prepare(
      `INSERT INTO account_identities (account_id, provider, subject, label, created_at)
       VALUES (?1, 'email', 'email-subject-unlink', 'person@example.test', ?2)`,
    )
      .bind(accountId, new Date(now.getTime() + 1_000).toISOString())
      .run();
    expect((await unlink("github")).status).toBe(204);
    expect(await identityProviders(accountId)).toEqual(["email"]);
    // The Account is now called what the channel it is left with calls it.
    expect(await displayLabel(accountId)).toBe("person@example.test");
  });

  it("answers no such provider for a channel Relay does not sign in through", async () => {
    const relay = harness(fakeGitHub());
    for (const provider of ["apple", "email", "carrier-pigeon"]) {
      const started = await relay.app.request(`${origin}/api/auth/${provider}/start`);
      expect(started.status, provider).toBe(404);
      expect(await started.json()).toMatchObject({ error: { code: "not_found" } });
      expect((await relay.app.request(`${origin}/api/auth/${provider}/callback`)).status).toBe(404);
    }
  });

  it("sends a native sign-in to the page that confirms which Account this is", async () => {
    const relay = harness(fakeGitHub());
    const authorize = new URL(`${origin}/oauth/v2/authorize`);
    authorize.search = new URLSearchParams({
      response_type: "code",
      client_id: "quotabar",
      redirect_uri: "http://127.0.0.1:43210/callback",
      state: "client-state-123456789",
      code_challenge: "a".repeat(43),
      code_challenge_method: "S256",
    }).toString();

    const started = await relay.app.request(authorize);
    expect(started.status).toBe(302);
    const location = new URL(started.headers.get("location") ?? "", origin);
    expect(location.pathname).toBe("/sign-in");
    const returnTo = location.searchParams.get("return_to") ?? "";
    expect(returnTo).toMatch(/^\/oauth\/v2\/complete\?login_token=/);
    // Nothing left for a provider, so no sign-in is in flight and no cookie was set.
    expect(started.headers.getSetCookie()).toEqual([]);
  });
});

/** An Account reached today by an address, and a browser signed in as it. Returns the cookie. */
async function seedAccountReachedByEmail(accountId: string, label: string): Promise<string> {
  const token = `qw_${accountId.replaceAll("_", "-").padEnd(43, "x").slice(0, 43)}`;
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO accounts (id, display_label, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
    ).bind(accountId, label, now.toISOString()),
    env.DB.prepare(
      `INSERT INTO account_identities (account_id, provider, subject, label, created_at)
       VALUES (?1, 'email', ?2, ?3, ?4)`,
    ).bind(accountId, `email-subject-${accountId}`, label, now.toISOString()),
    env.DB.prepare(
      `INSERT INTO sessions (
         id, family_id, account_id, device_id, device_generation, client_kind,
         access_token_hash, refresh_token_hash, scopes_json,
         authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
       ) VALUES (?1, ?1, ?2, NULL, NULL, 'web', ?3, NULL,
         '["account:read","account:manage"]', ?4, ?5, ?5, ?4, ?4)`,
    ).bind(
      `session_${accountId}`,
      accountId,
      await new SecretHasher(secret).hash("web-access", token),
      now.toISOString(),
      new Date(now.getTime() + 60 * 60_000).toISOString(),
    ),
  ]);
  return token;
}

async function linkGitHub(
  relay: ReturnType<typeof harness>,
  cookie: string,
  code: string,
  headers: Record<string, string> = {},
): Promise<Response> {
  const started = await relay.app.request(`${origin}/api/auth/github/start?intent=link`, {
    headers: { Cookie: cookie },
  });
  expect(started.status).toBe(302);
  const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
  const handoff = onlyCookie(started);
  return relay.app.request(
    `${origin}/api/auth/github/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`,
    { headers: { Cookie: `${cookie}; ${handoff.name}=${handoff.value}`, ...headers } },
  );
}

async function identityProviders(accountId: string): Promise<string[]> {
  const rows = await env.DB.prepare(
    "SELECT provider FROM account_identities WHERE account_id = ?1 ORDER BY provider",
  )
    .bind(accountId)
    .all<{ provider: string }>();
  return rows.results.map((row) => row.provider);
}

function displayLabel(accountId: string): Promise<unknown> {
  return env.DB.prepare("SELECT display_label FROM accounts WHERE id = ?1")
    .bind(accountId)
    .first("display_label");
}

interface GitHubStub {
  fetch: typeof fetch;
  accessToken: string;
  exchanges: number;
  profileReads: number;
  tokenForm: URLSearchParams | null;
}

/**
 * GitHub as this flow sees it: one code may be spent once, and a replay comes back as an error
 * body under a 200, which is what GitHub actually answers.
 */
function fakeGitHub(profile = { id: githubProfileId, login: "octocat" }): GitHubStub {
  const spent = new Set<string>();
  const stub: GitHubStub = {
    accessToken: "gho_fake_provider_access_token",
    exchanges: 0,
    profileReads: 0,
    tokenForm: null,
    fetch: async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (url === "https://github.com/login/oauth/access_token") {
        stub.exchanges += 1;
        const form = new URLSearchParams(String(init?.body ?? ""));
        stub.tokenForm = form;
        const code = form.get("code") ?? "";
        if (spent.has(code)) {
          return Response.json({ error: "bad_verification_code" });
        }
        spent.add(code);
        return Response.json({ access_token: stub.accessToken, token_type: "bearer", scope: "" });
      }
      if (url === "https://api.github.com/user") {
        stub.profileReads += 1;
        return Response.json({ id: profile.id, login: profile.login, name: "The Octocat" });
      }
      throw new Error(`unexpected outbound request: ${url}`);
    },
  };
  return stub;
}

function harness(github: GitHubStub, clock: () => Date = () => now) {
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const handoff = new SignInHandoff(hasher);
  const webSessions = new WebSessions({
    state,
    hasher,
    handoff,
    identitySubjectKey: secret,
    providers: [
      new GitHubIdentityProvider({
        handoff,
        clientId: "github-client",
        clientSecret: "github-secret",
        callbackUrl: `${origin}/api/auth/github/callback`,
        fetch: github.fetch,
      }),
    ],
  });
  return {
    app: createRelayApp({
      state,
      usageState: new D1UsageState(env.DB),
      accountService: new AccountService(state, hasher, secret),
      webSessions,
      hasher,
      now: clock,
    }),
    document: createWebDocumentPort({ state, webSessions, now: clock }),
  };
}

/** A handoff cookie value Relay itself would accept, whatever it carries. */
async function sealedHandoff(payload: {
  provider: string;
  intent: { kind: string; account_id?: string };
  state: string;
  verifier: string;
  return_to: string;
  expires_at: string;
}): Promise<string> {
  const encoded = encodeBase64UrlJSON(payload);
  return `${encoded}.${await new SecretHasher(secret).hash("oauth-handoff", encoded)}`;
}

async function signIn(relay: ReturnType<typeof harness>, code: string): Promise<Response> {
  const started = await relay.app.request(`${origin}/api/auth/github/start`);
  const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
  const handoff = onlyCookie(started);
  return relay.app.request(
    `${origin}/api/auth/github/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`,
    { headers: { Cookie: `${handoff.name}=${handoff.value}` } },
  );
}

async function seedDeviceData(accountId: string): Promise<void> {
  const stamp = now.toISOString();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO devices (id, account_id, installation_id_hash, generation, created_at, last_login_at)
       VALUES ('device_delete', ?1, 'installation_delete', 1, ?2, ?2)`,
    ).bind(accountId, stamp),
    env.DB.prepare(
      `INSERT INTO sessions (
         id, family_id, account_id, device_id, device_generation, client_kind,
         access_token_hash, refresh_token_hash, scopes_json,
         authenticated_at, expires_at, refresh_expires_at, last_used_at, created_at
       ) VALUES ('session_quotabar', 'family_quotabar', ?1, 'device_delete', 1, 'quotabar',
         'access_quotabar', 'refresh_quotabar', '["account:read","device:write"]',
         ?2, ?2, ?2, ?2, ?2)`,
    ).bind(accountId, stamp),
    env.DB.prepare(
      `INSERT INTO quota_snapshots (device_id, provider, account_fingerprint, observed_at, snapshot_json, updated_at)
       VALUES ('device_delete', 'codex', 'fingerprint', ?1, '{}', ?1)`,
    ).bind(stamp),
    env.DB.prepare(
      `INSERT INTO usage_hourly (
         device_id, agent, bucket_start_utc, scan_version, partial, billing_channel, channel_source,
         model, context_bucket, service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens, output_tokens,
         reasoning_tokens, requests, web_search_requests, web_fetch_requests,
         source_cost_microusd, source_cost_covered_requests
       ) VALUES ('device_delete', 'codex', '2026-08-10T00:00:00Z', 1, 0, 'openai_direct', 'explicit',
         'gpt-5', 'standard', 'default', 'default', 'global', 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, NULL, 0)`,
    ),
    env.DB.prepare(
      `INSERT INTO usage_hour_scans (device_id, agent, bucket_start_utc, scan_version)
       VALUES ('device_delete', 'codex', '2026-08-10T00:00:00Z', 1)`,
    ),
    env.DB.prepare(
      `INSERT INTO usage_daily (
         device_id, utc_date, agent, billing_channel, channel_source, model, context_bucket,
         service_tier, speed, inference_geo, input_tokens, cache_read_tokens, cache_write_5m_tokens,
         cache_write_1h_tokens, cache_write_inferred_tokens, output_tokens, reasoning_tokens,
         requests, web_search_requests, web_fetch_requests, source_cost_microusd,
         source_cost_covered_requests, partial_hours
       ) VALUES ('device_delete', '2026-08-10', 'codex', 'openai_direct', 'explicit', 'gpt-5',
         'standard', 'default', 'default', 'global', 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, NULL, 0, 0)`,
    ),
    env.DB.prepare(
      `INSERT INTO login_grants (id, client_id, account_id, expires_at, created_at)
       VALUES ('grant_delete', 'quotabar', ?1, ?2, ?2)`,
    ).bind(accountId, stamp),
  ]);
}

interface ParsedCookie {
  name: string;
  value: string;
  attributes: string;
}

function setCookies(response: Response): Map<string, ParsedCookie> {
  const jar = new Map<string, ParsedCookie>();
  for (const raw of response.headers.getSetCookie()) {
    const separator = raw.indexOf(";");
    const pair = separator < 0 ? raw : raw.slice(0, separator);
    const equals = pair.indexOf("=");
    const name = pair.slice(0, equals).trim();
    jar.set(name, {
      name,
      value: pair.slice(equals + 1).trim(),
      attributes: separator < 0 ? "" : raw.slice(separator + 1),
    });
  }
  return jar;
}

function onlyCookie(response: Response): ParsedCookie {
  const cookies = [...setCookies(response).values()];
  expect(cookies).toHaveLength(1);
  const cookie = cookies[0];
  if (!cookie) throw new Error("response set no cookie");
  return cookie;
}
