import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it } from "vitest";
import { AccountService } from "../src/account/service.ts";
import { createWebDocumentPort } from "../src/account/web-document-port.ts";
import { GitHubWebSessions } from "../src/account/web-session.ts";
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
    env.DB.prepare("DELETE FROM quota_snapshots"),
    env.DB.prepare("DELETE FROM sessions"),
    env.DB.prepare("DELETE FROM login_grants"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM accounts"),
    env.DB.prepare("DELETE FROM rate_limit_counters"),
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

    const account = await env.DB.prepare(
      "SELECT id, identity_subject, display_label FROM accounts",
    ).first<{ id: string; identity_subject: string; display_label: string }>();
    expect(account?.display_label).toBe("octocat");
    expect(account?.id).toBe(account?.identity_subject);
    expect(account?.id).toMatch(/^[0-9a-f]{64}$/);

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
      "sessions",
      "devices",
      "quota_snapshots",
      "usage_hourly",
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
function fakeGitHub(): GitHubStub {
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
        return Response.json({ id: githubProfileId, login: "octocat", name: "The Octocat" });
      }
      throw new Error(`unexpected outbound request: ${url}`);
    },
  };
  return stub;
}

function harness(github: GitHubStub, clock: () => Date = () => now) {
  const state = new D1AccountState(env.DB);
  const hasher = new SecretHasher(secret);
  const webSessions = new GitHubWebSessions({
    state,
    hasher,
    githubClientId: "github-client",
    githubClientSecret: "github-secret",
    githubSubjectKey: secret,
    origin,
    fetch: github.fetch,
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
