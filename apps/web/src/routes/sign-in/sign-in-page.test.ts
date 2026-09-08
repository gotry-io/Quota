import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { load } from "./+page.server.ts";
import SignInPage from "./+page.svelte";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const loadPage = load as unknown as (event: { url: URL }) => {
  returnTo: string;
  linking: boolean;
};

function loadFor(search: string): { returnTo: string; linking: boolean } {
  return loadPage({ url: new URL(`https://quota.gotry.io/sign-in${search}`) });
}

it("returns to the dashboard by default and refuses a target off this origin", () => {
  expect(loadFor("").returnTo).toBe("/my");
  expect(loadFor("").linking).toBe(false);
  expect(loadFor("?return_to=%2Foauth%2Fv2%2Fcomplete%3Flogin_token%3Dabc").returnTo).toBe(
    "/oauth/v2/complete?login_token=abc",
  );
  expect(loadFor("?intent=link").returnTo).toBe("/my/settings");
  expect(loadFor("?intent=link").linking).toBe(true);
  for (const refused of ["https://attacker.invalid/", "//attacker.invalid/", "my"]) {
    expect(() => loadFor(`?return_to=${encodeURIComponent(refused)}`), refused).toThrowError(
      expect.objectContaining({ status: 400 }),
    );
  }
});

it("offers the channels this build signs in through when nobody is signed in", () => {
  render(SignInPage, { data: { returnTo: "/my", linking: false, viewer: null } });

  expect(screen.getByRole("heading", { name: "Sign in to Quota" })).toBeDefined();
  const apple = screen.getByRole("link", { name: "Continue with Apple" });
  const github = screen.getByRole("link", { name: "Continue with GitHub" });
  expect(apple.getAttribute("href")).toBe("/api/auth/apple/start?return_to=%2Fmy");
  expect(github.getAttribute("href")).toBe("/api/auth/github/start?return_to=%2Fmy");
  expect(apple.compareDocumentPosition(github) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  // Apple's mark is drawn on its button and named nowhere: the link already says Apple.
  expect(apple.querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
  expect(screen.queryByRole("link", { name: /Continue with Email/ })).toBeNull();
  expect(screen.getByLabelText("Email")).toBeDefined();
  expect(screen.getByRole("button", { name: "Send sign-in link" })).toBeDefined();
  expect(screen.queryByRole("button", { name: "Use a different account" })).toBeNull();
});

it("asks a signed-in browser to confirm the Account before it continues", () => {
  render(SignInPage, {
    data: {
      returnTo: "/oauth/v2/complete?login_token=abc",
      linking: false,
      viewer: { displayLabel: "octocat" },
    },
  });

  expect(screen.getByRole("link", { name: "Continue as octocat" }).getAttribute("href")).toBe(
    "/oauth/v2/complete?login_token=abc",
  );
  expect(screen.getByRole("button", { name: "Use a different account" })).toBeDefined();
  expect(screen.queryByRole("link", { name: "Continue with GitHub" })).toBeNull();
  expect(screen.queryByRole("link", { name: "Continue with Apple" })).toBeNull();
  expect(screen.queryByLabelText("Email")).toBeNull();
});

it("asks to sign in again when Delete Account needs a fresh session", () => {
  render(SignInPage, {
    data: {
      returnTo: "/my/settings?delete=account",
      linking: false,
      viewer: { displayLabel: "octocat" },
    },
  });

  expect(
    screen.getByRole("heading", { name: "Sign in again to delete your account" }),
  ).toBeDefined();
  expect(screen.queryByRole("link", { name: /Continue as/ })).toBeNull();
  expect(screen.getByRole("link", { name: "Continue with Apple" })).toBeDefined();
  expect(screen.getByRole("link", { name: "Continue with GitHub" })).toBeDefined();
  expect(screen.getByLabelText("Email")).toBeDefined();
});

it("shows Check your email after a sign-in link is accepted, and can go back", async () => {
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = (async (input, init) => {
    requests.push(`${init?.method ?? "GET"} ${String(input)}`);
    return new Response(JSON.stringify({ status: "accepted" }), { status: 202 });
  }) as typeof fetch;
  try {
    render(SignInPage, { data: { returnTo: "/my", linking: false, viewer: null } });
    await fireEvent.input(screen.getByLabelText("Email"), {
      target: { value: "person@example.test" },
    });
    await fireEvent.click(screen.getByRole("button", { name: "Send sign-in link" }));
    expect(requests).toEqual(["POST /api/auth/email/start"]);
    expect(screen.getByRole("status").textContent).toContain("Check your email");
    expect(screen.queryByRole("link", { name: "Continue with GitHub" })).toBeNull();
    await fireEvent.click(screen.getByRole("button", { name: "Use another way" }));
    expect(screen.getByRole("link", { name: "Continue with GitHub" })).toBeDefined();
    expect(screen.getByRole("button", { name: "Send sign-in link" })).toBeDefined();
  } finally {
    globalThis.fetch = originalFetch;
  }
});

it("asks a signed-out visitor with intent=link to sign in the usual way, then Settings", () => {
  render(SignInPage, { data: { returnTo: "/my/settings", linking: true, viewer: null } });

  expect(screen.getByRole("heading", { name: "Link a sign-in method" })).toBeDefined();
  expect(
    screen.getByText(/Linking adds a way to sign in to the account you're already using/),
  ).toBeDefined();
  const apple = screen.getByRole("link", { name: "Continue with Apple" });
  const github = screen.getByRole("link", { name: "Continue with GitHub" });
  expect(apple.getAttribute("href")).toBe("/api/auth/apple/start?return_to=%2Fmy%2Fsettings");
  expect(github.getAttribute("href")).toBe("/api/auth/github/start?return_to=%2Fmy%2Fsettings");
});

it("lists bindable channels when a signed-in visitor arrives with intent=link", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toBe("/api/v2/account");
      return new Response(
        JSON.stringify({
          protocol_version: 2,
          account: {
            account_id: "account_01",
            display_label: "octocat",
            created_at: "2026-01-04T12:00:00Z",
          },
          identities: [{ provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" }],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }),
  );
  render(SignInPage, {
    data: { returnTo: "/my/settings", linking: true, viewer: { displayLabel: "octocat" } },
  });

  expect(screen.getByRole("heading", { name: "Link a sign-in method" })).toBeDefined();
  await waitFor(() => {
    expect(screen.getByRole("heading", { name: "Sign-in methods" })).toBeDefined();
  });
  expect(screen.queryByRole("link", { name: /Continue as/ })).toBeNull();
  expect(document.querySelector('[data-provider="apple"] a')?.getAttribute("href")).toBe(
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
});
