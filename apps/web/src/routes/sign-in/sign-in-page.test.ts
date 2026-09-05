import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import SignInPage from "./+page.svelte";
import { load } from "./+page.server.ts";

afterEach(cleanup);

const loadPage = load as unknown as (event: { url: URL }) => { returnTo: string };

function loadFor(search: string): { returnTo: string } {
  return loadPage({ url: new URL(`https://quota.gotry.io/sign-in${search}`) });
}

it("returns to the dashboard by default and refuses a target off this origin", () => {
  expect(loadFor("").returnTo).toBe("/my");
  expect(loadFor("?return_to=%2Foauth%2Fv2%2Fcomplete%3Flogin_token%3Dabc").returnTo).toBe(
    "/oauth/v2/complete?login_token=abc",
  );
  for (const refused of ["https://attacker.invalid/", "//attacker.invalid/", "my"]) {
    expect(() => loadFor(`?return_to=${encodeURIComponent(refused)}`), refused).toThrowError(
      expect.objectContaining({ status: 400 }),
    );
  }
});

it("offers the channels this build signs in through when nobody is signed in", () => {
  render(SignInPage, { data: { returnTo: "/my", viewer: null } });

  expect(screen.getByRole("heading", { name: "Sign in to Quota" })).toBeDefined();
  const github = screen.getByRole("link", { name: "Continue with GitHub" });
  expect(github.getAttribute("href")).toBe("/api/auth/github/start?return_to=%2Fmy");
  expect(screen.getByLabelText("Email")).toBeDefined();
  expect(screen.getByRole("button", { name: "Send sign-in link" })).toBeDefined();
  expect(screen.queryByRole("link", { name: /Continue with Apple/ })).toBeNull();
  expect(screen.queryByRole("button", { name: "Use a different account" })).toBeNull();
});

it("asks a signed-in browser to confirm the Account before it continues", () => {
  render(SignInPage, {
    data: { returnTo: "/oauth/v2/complete?login_token=abc", viewer: { displayLabel: "octocat" } },
  });

  expect(screen.getByRole("link", { name: "Continue as octocat" }).getAttribute("href")).toBe(
    "/oauth/v2/complete?login_token=abc",
  );
  expect(screen.getByRole("button", { name: "Use a different account" })).toBeDefined();
  expect(screen.queryByRole("link", { name: "Continue with GitHub" })).toBeNull();
  expect(screen.queryByLabelText("Email")).toBeNull();
});

it("shows Check your email after a sign-in link is accepted, and can go back", async () => {
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = (async (input, init) => {
    requests.push(`${init?.method ?? "GET"} ${String(input)}`);
    return new Response(JSON.stringify({ status: "accepted" }), { status: 202 });
  }) as typeof fetch;
  try {
    render(SignInPage, { data: { returnTo: "/my", viewer: null } });
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
