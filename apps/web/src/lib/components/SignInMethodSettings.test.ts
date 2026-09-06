import type { AccountIdentity } from "@gotry-io/quota-protocol";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { KEEP_ONE_SIGN_IN_COPY } from "$lib/account-errors";
import SignInMethodSettings from "./SignInMethodSettings.svelte";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function identity(
  provider: AccountIdentity["provider"],
  label: string,
  linkedAt = "2026-01-04T12:00:00Z",
): AccountIdentity {
  return { provider, label, linked_at: linkedAt };
}

function jsonResponse(status: number, body: unknown = {}): Response {
  if (status === 204) return new Response(null, { status });
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

it("lists Apple, GitHub, and Email, and disables Unlink on the last channel", () => {
  render(SignInMethodSettings, {
    identities: [identity("github", "octocat")],
    onChanged: async () => {},
    onError: () => {},
  });

  const rows = [...document.querySelectorAll("[data-provider]")].map((row) =>
    row.getAttribute("data-provider"),
  );
  expect(rows).toEqual(["apple", "github", "email"]);
  expect(screen.getByText("octocat")).toBeDefined();
  expect(screen.getByRole("button", { name: "Unlink" })).toHaveProperty("disabled", true);
  expect(screen.getByText(KEEP_ONE_SIGN_IN_COPY)).toBeDefined();
  expect(document.querySelector('[data-provider="apple"] a')?.getAttribute("href")).toBe(
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
  expect(document.querySelector('[data-provider="github"] a')).toBeNull();
  expect(document.querySelector('[data-provider="email"] a')).toBeNull();
  expect(screen.getByRole("button", { name: "Link" })).toBeDefined();
});

it("unlinks a channel that is not the last, after confirmation", async () => {
  vi.stubGlobal(
    "confirm",
    vi.fn(() => true),
  );
  const requests: Array<{ url: string; method: string }> = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({ url: String(input), method: init?.method ?? "GET" });
      return jsonResponse(204);
    }),
  );
  const onChanged = vi.fn(async () => {});
  const onError = vi.fn();
  render(SignInMethodSettings, {
    identities: [identity("github", "octocat"), identity("apple", "kyle@example.test")],
    onChanged,
    onError,
  });

  const unlinkButtons = screen.getAllByRole("button", { name: "Unlink" });
  expect(unlinkButtons).toHaveLength(2);
  for (const button of unlinkButtons) expect(button).toHaveProperty("disabled", false);
  expect(screen.queryByText(KEEP_ONE_SIGN_IN_COPY)).toBeNull();

  const appleUnlink = unlinkButtons[0];
  if (!appleUnlink) throw new Error("expected Apple Unlink");
  await fireEvent.click(appleUnlink);
  await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1));
  expect(requests).toEqual([{ url: "/api/v2/account/identities/apple", method: "DELETE" }]);
  expect(onError).not.toHaveBeenCalled();
});

it("mails a link for Email and then shows Check your email", async () => {
  const bodies: string[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body ?? ""));
      return jsonResponse(202, { status: "accepted" });
    }),
  );
  render(SignInMethodSettings, {
    identities: [identity("github", "octocat")],
    onChanged: async () => {},
    onError: () => {},
  });

  await fireEvent.click(screen.getByRole("button", { name: "Link" }));
  await fireEvent.input(screen.getByLabelText("Email"), {
    target: { value: "person@example.test" },
  });
  await fireEvent.click(screen.getByRole("button", { name: "Send sign-in link" }));
  expect(JSON.parse(bodies[0] ?? "{}")).toEqual({
    email: "person@example.test",
    return_to: "/my/settings",
    intent: "link",
  });
  expect(screen.getByRole("status").textContent).toContain("Check your email");
});
