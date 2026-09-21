import { afterEach, expect, it, vi } from "vitest";
import { FORBIDDEN_COPY, SESSION_ENDED_COPY } from "./account-errors.ts";
import {
  ACCOUNT_SETTINGS_PATH,
  clearStoredAccountSettings,
  defaultAccountSettingsResponse,
  fetchAccountSettings,
  SETTINGS_CHANGED_ELSEWHERE_COPY,
  saveBudget,
  storedAccountSettingsETag,
} from "./account-settings-client.ts";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  clearStoredAccountSettings();
});

const defaultDocument = defaultAccountSettingsResponse();

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function settingsDocument(
  overrides: {
    revision?: number;
    updated_at?: string;
    alerts?: (typeof defaultDocument)["alerts"];
    budget?: (typeof defaultDocument)["budget"];
  } = {},
) {
  return {
    protocol_version: 2 as const,
    revision: overrides.revision ?? 0,
    updated_at: overrides.updated_at ?? defaultDocument.updated_at,
    alerts: overrides.alerts ?? defaultDocument.alerts,
    budget: overrides.budget ?? defaultDocument.budget,
  };
}

it("reads the Account settings document and keeps the ETag", async () => {
  const body = settingsDocument({
    revision: 1,
    updated_at: "2026-09-21T10:00:00.000Z",
    budget: { amount_usd: "250.00", alerts: true },
  });
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
    jsonResponse(body, 200, { ETag: '"1"' }),
  );
  vi.stubGlobal("fetch", fetchMock);

  const result = await fetchAccountSettings();
  expect(result.status).toBe("ok");
  if (result.status !== "ok") return;
  expect(result.etag).toBe('"1"');
  expect(result.settings.budget.amount_usd).toBe("250.00");
  expect(fetchMock.mock.calls[0]?.[0]).toBe(ACCOUNT_SETTINGS_PATH);
  const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
  expect(init.credentials).toBe("same-origin");
  expect(new Headers(init.headers).get("If-None-Match")).toBeNull();
  expect(storedAccountSettingsETag()).toBe('"1"');
});

it("sends If-None-Match and keeps the last document on 304", async () => {
  const body = settingsDocument({ revision: 1, budget: { amount_usd: "50.00", alerts: true } });
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (new Headers(init?.headers).get("If-None-Match") === '"1"') {
      return new Response(null, { status: 304, headers: { ETag: '"1"' } });
    }
    return jsonResponse(body, 200, { ETag: '"1"' });
  });
  vi.stubGlobal("fetch", fetchMock);

  expect((await fetchAccountSettings()).status).toBe("ok");
  const again = await fetchAccountSettings();
  expect(again.status).toBe("not_modified");
  if (again.status !== "not_modified") return;
  expect(again.settings.budget.amount_usd).toBe("50.00");
  expect(again.etag).toBe('"1"');
  expect(new Headers(fetchMock.mock.calls[1]?.[1]?.headers).get("If-None-Match")).toBe('"1"');
});

it("replays one budget edit onto a 412 document and succeeds on the retry", async () => {
  const fresh = settingsDocument({
    revision: 1,
    updated_at: "2026-09-21T10:00:00.000Z",
    alerts: {
      reset_reminders: true,
      pace_alerts: true,
      thresholds: { aabbccddeeff: [20, 10] },
    },
    budget: { amount_usd: "250.00", alerts: false },
  });
  const written = settingsDocument({
    revision: 2,
    updated_at: "2026-09-21T10:00:01.000Z",
    alerts: fresh.alerts,
    budget: { amount_usd: "75.50", alerts: false },
  });
  const puts: Array<{ match: string | null; body: unknown }> = [];
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    if ((init?.method ?? "GET") === "GET") {
      return jsonResponse(defaultDocument, 200, { ETag: '"0"' });
    }
    const match = new Headers(init?.headers).get("If-Match");
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    puts.push({ match, body });
    if (match === '"0"') return jsonResponse(fresh, 412, { ETag: '"1"' });
    return jsonResponse(written, 200, { ETag: '"2"' });
  });
  vi.stubGlobal("fetch", fetchMock);

  expect((await fetchAccountSettings()).status).toBe("ok");
  const result = await saveBudget({ kind: "set_budget_amount", value: "75.50" });
  expect(result.status).toBe("ok");
  if (result.status !== "ok") return;
  expect(result.settings.budget.amount_usd).toBe("75.50");
  expect(puts).toHaveLength(2);
  expect(puts[0]?.match).toBe('"0"');
  expect(puts[1]).toEqual({
    match: '"1"',
    body: {
      protocol_version: 2,
      alerts: fresh.alerts,
      budget: { amount_usd: "75.50", alerts: false },
    },
  });
});

it("names a second 412 as changed elsewhere, try again", async () => {
  const first = settingsDocument({
    revision: 1,
    budget: { amount_usd: "100.00", alerts: true },
  });
  const second = settingsDocument({
    revision: 2,
    budget: { amount_usd: "200.00", alerts: true },
  });
  let puts = 0;
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if ((init?.method ?? "GET") === "GET") {
        return jsonResponse(defaultDocument, 200, { ETag: '"0"' });
      }
      puts += 1;
      return jsonResponse(puts === 1 ? first : second, 412, { ETag: `"${puts}"` });
    }),
  );

  expect((await fetchAccountSettings()).status).toBe("ok");
  const result = await saveBudget({ kind: "set_budget_amount", value: "50.00" });
  expect(result).toEqual({
    status: "conflict",
    message: SETTINGS_CHANGED_ELSEWHERE_COPY,
    settings: second,
    etag: '"2"',
  });
  expect(puts).toBe(2);
});

it("treats 401 as a session that ended", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(null, { status: 401 })),
  );
  const result = await fetchAccountSettings();
  expect(result.status).toBe("error");
  if (result.status !== "error") return;
  expect(result.error.status).toBe("session_ended");
  expect(result.error.message).toBe(SESSION_ENDED_COPY);
});

it("treats a 401 write as a session that ended", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if ((init?.method ?? "GET") === "GET") {
        return jsonResponse(defaultDocument, 200, { ETag: '"0"' });
      }
      return new Response(null, { status: 401 });
    }),
  );
  expect((await fetchAccountSettings()).status).toBe("ok");
  const result = await saveBudget({ kind: "set_budget_alerts", value: false });
  expect(result.status).toBe("error");
  if (result.status !== "error") return;
  expect(result.error.status).toBe("session_ended");
});

it("does not treat a 403 read as a session that ended", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(null, { status: 403 })),
  );
  const result = await fetchAccountSettings();
  expect(result.status).toBe("error");
  if (result.status !== "error") return;
  expect(result.error.status).toBe("forbidden");
  expect(result.error.message).toBe(FORBIDDEN_COPY);
});
