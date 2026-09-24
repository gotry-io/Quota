import { cleanup, render, screen } from "@testing-library/svelte";
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
