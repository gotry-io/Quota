import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import PublicProfileSettings from "./PublicProfileSettings.svelte";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function profileResponse(
  overrides: Partial<{
    handle: string | null;
    enabled: boolean;
    show_models: boolean;
    show_cost: boolean;
    on_leaderboard: boolean;
  }> = {},
) {
  return {
    protocol_version: 2,
    profile: {
      handle: null,
      enabled: false,
      show_models: true,
      show_cost: false,
      on_leaderboard: false,
      ...overrides,
    },
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

it("fills the form from the Account's own profile and writes all four values back", async () => {
  const requests: Array<{ url: string; method: string; body: unknown }> = [];
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    requests.push({
      url: String(input),
      method: init?.method ?? "GET",
      body: init?.body ? JSON.parse(String(init.body)) : null,
    });
    if (init?.method === "PUT") {
      return jsonResponse(profileResponse({ handle: "kyle", enabled: true, show_cost: true }));
    }
    return jsonResponse(profileResponse({ handle: "kyle", enabled: true }));
  });
  vi.stubGlobal("fetch", fetchMock);

  render(PublicProfileSettings);

  const handle = await screen.findByLabelText<HTMLInputElement>("Handle");
  expect(handle.value).toBe("kyle");
  expect(screen.getByLabelText<HTMLInputElement>("Publish this page").checked).toBe(true);
  expect(screen.getByLabelText<HTMLInputElement>("Show API-equivalent cost").checked).toBe(false);

  await fireEvent.click(screen.getByLabelText("Show API-equivalent cost"));
  await fireEvent.click(screen.getByRole("button", { name: "Save" }));

  await waitFor(() => expect(requests).toHaveLength(2));
  expect(requests[1]).toEqual({
    url: "/api/v2/account/profile",
    method: "PUT",
    body: {
      protocol_version: 2,
      profile: {
        handle: "kyle",
        enabled: true,
        show_models: true,
        show_cost: true,
        on_leaderboard: false,
      },
    },
  });
  expect(await screen.findByText(/Published at https:\/\/quota.gotry.io\/u\/kyle/)).toBeTruthy();
});

it("names a handle the contract refuses without asking Relay, and one Relay refuses after it", async () => {
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) =>
    init?.method === "PUT" ? jsonResponse({}, 409) : jsonResponse(profileResponse()),
  );
  vi.stubGlobal("fetch", fetchMock);

  render(PublicProfileSettings);
  const handle = await screen.findByLabelText<HTMLInputElement>("Handle");

  await fireEvent.input(handle, { target: { value: "my" } });
  await fireEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(await screen.findByText("That handle is reserved.")).toBeTruthy();
  expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")).toHaveLength(0);

  await fireEvent.input(handle, { target: { value: "kyle" } });
  await fireEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(await screen.findByText("That handle is already taken.")).toBeTruthy();
});

it("shows the shared retry notice when the read fails", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({}, 500)),
  );

  render(PublicProfileSettings);

  expect(await screen.findByText("Quota couldn't load this. Retry.")).toBeTruthy();
});
