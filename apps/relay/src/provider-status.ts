import {
  type ProviderId,
  ProviderIdSchema,
  type ProviderStatusEntry,
  type ProviderStatusResponse,
  ProviderStatusResponseSchema,
} from "@gotry-io/quota-protocol";
import catalog from "../../../packages/provider/catalog.json" with { type: "json" };
import { readBoundedJSON } from "./account/bounded-json.ts";
import { CANONICAL_ORIGIN } from "./config.ts";

export const PROVIDER_STATUS_CACHE_MILLISECONDS = 10 * 60 * 1000;
export const PROVIDER_STATUS_TIMEOUT_MILLISECONDS = 5_000;
export const PROVIDER_STATUS_BODY_LIMIT = 64 * 1024;

const INDICATORS = new Set(["none", "minor", "major", "critical"]);

type CatalogProvider = {
  id: string;
  status_page?: { kind: string; url: string | null } | null;
};

const STATUSPAGE_V2_ENDPOINTS = (catalog.providers as CatalogProvider[]).flatMap((provider) => {
  const id = ProviderIdSchema.safeParse(provider.id);
  const page = provider.status_page;
  if (!id.success || page?.kind !== "statuspage_v2" || typeof page.url !== "string") return [];
  return [{ id: id.data, url: page.url }];
});

export function statuspageV2Endpoints(): ReadonlyArray<{ id: ProviderId; url: string }> {
  return STATUSPAGE_V2_ENDPOINTS;
}

export interface ProviderStatusPorts {
  fetch: typeof fetch;
  cache: Cache;
  now: Date;
}

type CachedReading = {
  indicator: "none" | "minor" | "major" | "critical";
  description: string;
  checked_at: string;
};

/**
 * Poll every catalog `statuspage_v2` feed, serving a cached reading for ten minutes and the
 * last good one when a poll fails. A provider with nothing cached answers `unknown`.
 */
export async function readProviderStatus(
  ports: ProviderStatusPorts,
): Promise<ProviderStatusResponse> {
  const checkedAt = ports.now.toISOString();
  const providers = await Promise.all(
    STATUSPAGE_V2_ENDPOINTS.map((endpoint) => readOne(endpoint, ports, checkedAt)),
  );
  return ProviderStatusResponseSchema.parse({ providers });
}

async function readOne(
  endpoint: { id: ProviderId; url: string },
  ports: ProviderStatusPorts,
  checkedAt: string,
): Promise<ProviderStatusEntry> {
  const cached = await readCached(ports.cache, endpoint.id);
  const cachedAge = cached ? ports.now.getTime() - Date.parse(cached.checked_at) : Number.NaN;
  if (cached && cachedAge < PROVIDER_STATUS_CACHE_MILLISECONDS) {
    return { id: endpoint.id, ...cached };
  }
  const fresh = await pollStatuspage(endpoint.url, ports.fetch);
  if (fresh) {
    const reading: CachedReading = {
      indicator: fresh.indicator,
      description: fresh.description,
      checked_at: checkedAt,
    };
    await writeCached(ports.cache, endpoint.id, reading);
    return { id: endpoint.id, ...reading };
  }
  if (cached) return { id: endpoint.id, ...cached };
  return { id: endpoint.id, indicator: "unknown", description: "", checked_at: checkedAt };
}

function cacheRequest(id: string): Request {
  return new Request(`${CANONICAL_ORIGIN}/api/v2/providers/status/upstream/${id}`);
}

async function readCached(cache: Cache, id: string): Promise<CachedReading | null> {
  const response = await cache.match(cacheRequest(id));
  if (!response) return null;
  try {
    const body = (await response.json()) as CachedReading;
    if (
      !INDICATORS.has(body.indicator) ||
      typeof body.description !== "string" ||
      typeof body.checked_at !== "string"
    ) {
      return null;
    }
    return {
      indicator: body.indicator,
      description: body.description,
      checked_at: body.checked_at,
    };
  } catch {
    return null;
  }
}

async function writeCached(cache: Cache, id: string, reading: CachedReading): Promise<void> {
  await cache.put(
    cacheRequest(id),
    new Response(JSON.stringify(reading), {
      headers: { "Content-Type": "application/json" },
    }),
  );
}

async function pollStatuspage(
  url: string,
  fetchFn: typeof fetch,
): Promise<{ indicator: CachedReading["indicator"]; description: string } | null> {
  try {
    const response = await fetchFn(url, {
      method: "GET",
      headers: { Accept: "application/json", "User-Agent": "QuotaRelay" },
      redirect: "manual",
      signal: AbortSignal.timeout(PROVIDER_STATUS_TIMEOUT_MILLISECONDS),
    });
    if (!response.ok) return null;
    const body = await readBoundedJSON(response, PROVIDER_STATUS_BODY_LIMIT);
    return parseStatuspageV2(body);
  } catch {
    return null;
  }
}

export function parseStatuspageV2(
  body: Record<string, unknown>,
): { indicator: CachedReading["indicator"]; description: string } | null {
  const status = body.status;
  if (status === null || typeof status !== "object" || Array.isArray(status)) return null;
  const record = status as Record<string, unknown>;
  const indicator = record.indicator;
  const description = record.description;
  if (typeof indicator !== "string" || !INDICATORS.has(indicator)) return null;
  if (typeof description !== "string" || description.length > 512) return null;
  return { indicator: indicator as CachedReading["indicator"], description };
}
