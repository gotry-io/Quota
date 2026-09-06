import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import { beforeEach, describe, expect, inject, it, vi } from "vitest";
import { normalizeEmailAddress } from "../src/account/email-identity.ts";
import { ResendEmailSender } from "../src/account/email-sender.ts";
import { GitHubIdentityProvider } from "../src/account/github-identity.ts";
import { SignInHandoff } from "../src/account/identity.ts";
import { AccountService } from "../src/account/service.ts";
import { WebSessions } from "../src/account/web-session.ts";
import { accountMaintenanceInput, createRelayApp } from "../src/app.ts";
import { hmacSha256Hex, SecretHasher } from "../src/security.ts";
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

beforeEach(async () => {
  await applyD1Migrations(env.DB, inject("TEST_MIGRATIONS"));
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

describe("normalizeEmailAddress", () => {
  it("trims, lowercases, and refuses a value that is not a mailbox", () => {
    expect(normalizeEmailAddress("  Foo.Bar+tag@Example.COM  ")).toBe("foo.bar+tag@example.com");
    expect(normalizeEmailAddress("person@example.test")).toBe("person@example.test");
    for (const refused of [
      "",
      "   ",
      "not-an-email",
      "missing-domain@",
      "@missing-local.test",
      "two@@example.test",
      "no space@example.test",
      "person@localhost",
      `${"a".repeat(64)}@${"b".repeat(190)}.test`,
    ]) {
      expect(normalizeEmailAddress(refused), refused).toBeNull();
    }
  });
});

describe("browser sign-in through email", () => {
  it("mails a link, always answers 202, and opens a session when the link is spent", async () => {
    const mailbox = fakeMailbox();
    const relay = harness(mailbox);

    const started = await startEmail(relay, "  Person@Example.TEST  ");
    expect(started.status).toBe(202);
    expect(await started.json()).toEqual({ status: "accepted" });
    expect(started.headers.get("cache-control")).toBe("no-store");
    expect(started.headers.getSetCookie()).toEqual([]);
    expect(mailbox.sent).toHaveLength(1);
    expect(mailbox.sent[0]?.to).toBe("person@example.test");
    expect(mailbox.sent[0]?.subject).toBe("Sign in to Quota");
    expect(mailbox.sent[0]?.text).toContain("15 minutes");
    expect(mailbox.sent[0]?.text).toContain("If you didn't ask for it, you can ignore this email.");
    expect(mailbox.sent[0]?.html).toContain("15 minutes");
    const token = tokenFrom(mailbox.sent[0]?.text ?? "");
    expect(mailbox.sent[0]?.text).toContain(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`,
    );

    const stored = await env.DB.prepare(
      "SELECT email_hash, token_hash, intent_json, return_to, consumed_at FROM email_challenges",
    ).first<{
      email_hash: string;
      token_hash: string;
      intent_json: string;
      return_to: string;
      consumed_at: string | null;
    }>();
    expect(stored?.email_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(stored?.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(stored?.intent_json).toBe('{"kind":"sign_in"}');
    expect(stored?.return_to).toBe("/my");
    expect(stored?.consumed_at).toBeNull();
    expect(JSON.stringify(stored)).not.toContain("person@example.test");
    expect(JSON.stringify(stored)).not.toContain(token);

    const verified = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`,
    );
    expect(verified.status).toBe(302);
    expect(verified.headers.get("location")).toBe("/my");
    const session = setCookies(verified).get("__Host-quota_session");
    expect(session?.value).toMatch(/^qw_[A-Za-z0-9_-]{43}$/);
    expect(session?.attributes).toContain("HttpOnly");
    expect(session?.attributes).toContain("Secure");
    expect(session?.attributes).toContain("SameSite=Lax");

    const identity = await env.DB.prepare(
      "SELECT provider, label, subject FROM account_identities",
    ).first<{ provider: string; label: string; subject: string }>();
    expect(identity).toMatchObject({ provider: "email", label: "person@example.test" });
    expect(identity?.subject).toBe(await hmacSha256Hex(secret, "email:person@example.test"));
    expect(identity?.subject).not.toContain("person@example.test");

    const read = await relay.app.request(`${origin}/api/v2/account`, {
      headers: { Cookie: `__Host-quota_session=${session?.value}` },
    });
    expect(read.status).toBe(200);
    expect(await read.json()).toMatchObject({
      account: { display_label: "person@example.test" },
      identities: [{ provider: "email", label: "person@example.test" }],
    });
  });

  it("answers 202 for an address it already knows, and for one it does not", async () => {
    const mailbox = fakeMailbox();
    const relay = harness(mailbox);
    await seedEmailAccount("account_known", "known@example.test");

    for (const email of ["known@example.test", "unknown@example.test"]) {
      const response = await startEmail(relay, email);
      expect(response.status, email).toBe(202);
      expect(await response.json(), email).toEqual({ status: "accepted" });
    }
    expect(mailbox.sent.map((item) => item.to)).toEqual([
      "known@example.test",
      "unknown@example.test",
    ]);
  });

  it("rate-limits one address at a minute and an hour without changing the 202", async () => {
    const mailbox = fakeMailbox();
    let clock = now;
    const relay = harness(mailbox, () => clock);

    expect((await startEmail(relay, "limited@example.test")).status).toBe(202);
    expect((await startEmail(relay, "limited@example.test")).status).toBe(202);
    expect(mailbox.sent).toHaveLength(1);

    for (let index = 1; index < 5; index += 1) {
      clock = new Date(now.getTime() + index * 61_000);
      expect((await startEmail(relay, "limited@example.test")).status).toBe(202);
    }
    expect(mailbox.sent).toHaveLength(5);
    clock = new Date(now.getTime() + 5 * 61_000);
    expect((await startEmail(relay, "limited@example.test")).status).toBe(202);
    expect(mailbox.sent).toHaveLength(5);
  });

  it("shares the web-signin IP bucket and still 429s that way", async () => {
    const mailbox = fakeMailbox();
    const relay = harness(mailbox);
    const request = (path: string, init?: RequestInit) =>
      relay.app.request(`${origin}${path}`, {
        ...init,
        headers: { "CF-Connecting-IP": "203.0.113.9", ...headersOf(init) },
      });

    let limited: Response | null = null;
    for (let attempt = 0; attempt < 31 && limited === null; attempt += 1) {
      const response = await request("/api/auth/github/start");
      if (response.status === 429) limited = response;
    }
    expect(limited?.status).toBe(429);
    const blocked = await request("/api/auth/email/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "person@example.test" }),
    });
    expect(blocked.status).toBe(429);
    expect(mailbox.sent).toHaveLength(0);
  });

  it("still answers 202 when Resend refuses, and logs only the address hash", async () => {
    const mailbox = fakeMailbox();
    mailbox.fail = true;
    const relay = harness(mailbox);
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect((await startEmail(relay, "person@example.test")).status).toBe(202);
      expect(mailbox.sent).toHaveLength(0);
      expect(logged).toHaveBeenCalledWith(
        "email_send_failed",
        expect.objectContaining({ email_hash: expect.stringMatching(/^[0-9a-f]{8}$/) }),
      );
      expect(JSON.stringify(logged.mock.calls)).not.toContain("person@example.test");
    } finally {
      logged.mockRestore();
    }
  });

  it("refuses a spent or expired link", async () => {
    const mailbox = fakeMailbox();
    let clock = now;
    const relay = harness(mailbox, () => clock);

    await startEmail(relay, "once@example.test");
    const token = tokenFrom(mailbox.sent[0]?.text ?? "");
    expect(
      (
        await relay.app.request(
          `${origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`,
        )
      ).status,
    ).toBe(302);
    const reused = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`,
      { headers: { Accept: "text/html" } },
    );
    expect(reused.status).toBe(200);
    expect(await reused.text()).toContain("invalid_request");

    await startEmail(relay, "late@example.test");
    const late = tokenFrom(mailbox.sent[1]?.text ?? "");
    clock = new Date(now.getTime() + 16 * 60_000);
    const expired = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(late)}`,
      { headers: { Accept: "text/html" } },
    );
    expect(expired.status).toBe(200);
    expect(await expired.text()).toContain('data-reason="expired"');
  });

  it("binds an address to the signed-in Account and refuses one another Account already holds", async () => {
    const mailbox = fakeMailbox();
    let clock = now;
    const relay = harness(mailbox, () => clock);
    const session = setCookies(await signInGitHub(relay, "owner-code")).get(
      "__Host-quota_session",
    )?.value;
    const cookie = `__Host-quota_session=${session}`;

    const linked = await startEmail(relay, "new@example.test", {
      intent: "link",
      cookie,
    });
    expect(linked.status).toBe(202);
    const token = tokenFrom(mailbox.sent[0]?.text ?? "");
    const verified = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(token)}`,
      { headers: { Cookie: cookie } },
    );
    expect(verified.status).toBe(302);
    expect(setCookies(verified).get("__Host-quota_session")).toBeUndefined();
    const accountId = String(await env.DB.prepare("SELECT id FROM accounts").first("id"));
    expect(await identityProviders(accountId)).toEqual(["email", "github"]);

    await seedEmailAccount("account_taken", "taken@example.test");
    expect((await startEmail(relay, "taken@example.test", { intent: "link", cookie })).status).toBe(
      202,
    );
    const takenToken = tokenFrom(mailbox.sent[1]?.text ?? "");
    const refused = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(takenToken)}`,
      { headers: { Cookie: cookie, Accept: "application/json" } },
    );
    expect(refused.status).toBe(409);
    expect(await refused.json()).toMatchObject({ error: { code: "conflict" } });

    clock = new Date(now.getTime() + 61_000);
    expect((await startEmail(relay, "taken@example.test", { intent: "link", cookie })).status).toBe(
      202,
    );
    const asHtml = await relay.app.request(
      `${origin}/api/auth/email/verify?token=${encodeURIComponent(tokenFrom(mailbox.sent[2]?.text ?? ""))}`,
      { headers: { Cookie: cookie, Accept: "text/html" } },
    );
    expect(asHtml.status).toBe(200);
    expect(await asHtml.text()).toContain(
      "That Email account is already linked to another Quota account.",
    );
    expect(await identityProviders("account_taken")).toEqual(["email"]);
  });

  it("requires a session to start a link and does not leak a GET start", async () => {
    const mailbox = fakeMailbox();
    const relay = harness(mailbox);
    expect((await startEmail(relay, "person@example.test", { intent: "link" })).status).toBe(401);
    expect(mailbox.sent).toHaveLength(0);
    expect((await relay.app.request(`${origin}/api/auth/email/start`)).status).toBe(404);
    expect((await relay.app.request(`${origin}/api/auth/email/callback`)).status).toBe(404);
  });

  it("refuses a body that is not a mailbox or that names extra keys", async () => {
    const mailbox = fakeMailbox();
    const relay = harness(mailbox);
    for (const body of [
      { email: "not-an-email" },
      { email: "person@example.test", extra: true },
      { email: "person@example.test", return_to: "https://attacker.invalid/" },
      { email: "person@example.test", intent: "merge" },
    ]) {
      const response = await relay.app.request(`${origin}/api/auth/email/start`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      expect(response.status, JSON.stringify(body)).toBe(400);
    }
    expect(mailbox.sent).toHaveLength(0);
  });

  it("sweeps an expired challenge with the other grants", async () => {
    await env.DB.prepare(
      `INSERT INTO email_challenges (
         id, email_hash, token_hash, intent_json, return_to, created_at, expires_at
       ) VALUES ('email_old', 'hash', 'token', '{"kind":"sign_in"}', '/my', ?1, ?1)`,
    )
      .bind(now.toISOString())
      .run();
    await new D1AccountState(env.DB).performMaintenance(accountMaintenanceInput(now));
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS count FROM email_challenges").first("count"),
    ).toBe(0);
  });
});

describe("ResendEmailSender", () => {
  it("posts the message and treats a failing status as a failed send", async () => {
    const calls: Array<{ url: string; body: string }> = [];
    const ok = new ResendEmailSender({
      apiKey: "re_test",
      fetch: async (input, init) => {
        calls.push({ url: String(input), body: String(init?.body ?? "") });
        return Response.json({ id: "re_123" });
      },
    });
    expect(
      await ok.send({
        to: "person@example.test",
        subject: "Sign in to Quota",
        text: "link",
        html: "<p>link</p>",
      }),
    ).toEqual({ id: "re_123" });
    expect(calls[0]?.url).toBe("https://api.resend.com/emails");
    expect(JSON.parse(calls[0]?.body ?? "{}")).toMatchObject({
      from: "Quota <login@gotry.io>",
      to: ["person@example.test"],
    });

    const failing = new ResendEmailSender({
      apiKey: "re_test",
      fetch: async () => new Response("nope", { status: 500 }),
    });
    expect(
      await failing.send({
        to: "person@example.test",
        subject: "Sign in to Quota",
        text: "link",
        html: "<p>link</p>",
      }),
    ).toEqual({ failed: true });
  });
});

interface Mailbox {
  sent: Array<{ to: string; subject: string; text: string; html: string }>;
  fail: boolean;
  send(message: {
    to: string;
    subject: string;
    text: string;
    html: string;
  }): Promise<{ id: string } | { failed: true }>;
}

function fakeMailbox(): Mailbox {
  const mailbox: Mailbox = {
    sent: [],
    fail: false,
    async send(message) {
      if (mailbox.fail) return { failed: true };
      mailbox.sent.push(message);
      return { id: `re_${mailbox.sent.length}` };
    },
  };
  return mailbox;
}

function harness(mailbox: Mailbox, clock: () => Date = () => now) {
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
        fetch: fakeGitHubFetch(),
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
      emailSender: mailbox,
      now: clock,
    }),
  };
}

function fakeGitHubFetch(): typeof fetch {
  const spent = new Set<string>();
  return async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url === "https://github.com/login/oauth/access_token") {
      const code = new URLSearchParams(String(init?.body ?? "")).get("code") ?? "";
      if (spent.has(code)) return Response.json({ error: "bad_verification_code" });
      spent.add(code);
      return Response.json({ access_token: "gho_fake", token_type: "bearer", scope: "" });
    }
    if (url === "https://api.github.com/user") {
      return Response.json({ id: 583_231, login: "octocat" });
    }
    throw new Error(`unexpected outbound request: ${url}`);
  };
}

async function startEmail(
  relay: ReturnType<typeof harness>,
  email: string,
  options: { intent?: "sign_in" | "link"; cookie?: string } = {},
): Promise<Response> {
  return await relay.app.request(`${origin}/api/auth/email/start`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(options.cookie === undefined ? {} : { Cookie: options.cookie }),
    },
    body: JSON.stringify({
      email,
      ...(options.intent === undefined ? {} : { intent: options.intent }),
    }),
  });
}

async function signInGitHub(relay: ReturnType<typeof harness>, code: string): Promise<Response> {
  const started = await relay.app.request(`${origin}/api/auth/github/start`);
  const state = new URL(started.headers.get("location") ?? "").searchParams.get("state") ?? "";
  const handoff = onlyCookie(started);
  return relay.app.request(
    `${origin}/api/auth/github/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`,
    { headers: { Cookie: `${handoff.name}=${handoff.value}` } },
  );
}

async function seedEmailAccount(accountId: string, email: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO accounts (id, display_label, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
    ).bind(accountId, email, now.toISOString()),
    env.DB.prepare(
      `INSERT INTO account_identities (account_id, provider, subject, label, created_at)
       VALUES (?1, 'email', ?2, ?3, ?4)`,
    ).bind(accountId, await hmacSha256Hex(secret, `email:${email}`), email, now.toISOString()),
  ]);
}

async function identityProviders(accountId: string): Promise<string[]> {
  const rows = await env.DB.prepare(
    "SELECT provider FROM account_identities WHERE account_id = ?1 ORDER BY provider",
  )
    .bind(accountId)
    .all<{ provider: string }>();
  return rows.results.map((row) => row.provider);
}

function tokenFrom(text: string): string {
  const match = /[?&]token=([A-Za-z0-9._~-]+)/.exec(text);
  return decodeURIComponent(match?.[1] ?? "");
}

function headersOf(init: RequestInit | undefined): HeadersInit {
  return init?.headers ?? {};
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
