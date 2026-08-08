import { ProviderCollectionError } from "../../contracts.ts";
import {
  type ApiKeyCollectContext,
  type ApiKeyHttpCollectorSpec,
  fetchBearerJson,
} from "../../api-key/index.ts";
import {
  buildOpenRouterSnapshot,
  mapOpenRouterCreditsResponse,
  mapOpenRouterKeyResponse,
  mapOpenRouterWindows,
  OPENROUTER_SOURCE_API,
  type OpenRouterKeyData,
} from "./map.ts";

export { OPENROUTER_SOURCE_API };

export const openrouterSpec: ApiKeyHttpCollectorSpec = {
  provider: "openrouter",
  source: OPENROUTER_SOURCE_API,
  envKeys: ["OPENROUTER_API_KEY"],
  defaultBaseUrl: "https://openrouter.ai/api/v1",
  maskLabel: "OpenRouter",
  collect: collectOpenRouter,
};

async function collectOpenRouter(ctx: ApiKeyCollectContext) {
  const { credentials, transport, clientVersion, signal, now } = ctx;
  const request = (path: string) =>
    fetchBearerJson({
      transport,
      url: `${credentials.baseUrl}/${path}`,
      apiKey: credentials.apiKey,
      source: OPENROUTER_SOURCE_API,
      providerLabel: "OpenRouter",
      clientVersion,
      ...(signal ? { signal } : {}),
      extraHeaders: { "X-Title": clientVersion },
    });

  // Credits and /key are independent meters. Auth failures still surface; soft failures
  // leave that meter undefined so key-limit-only accounts can succeed.
  const [creditsResult, keyResult] = await Promise.all([
    collectMeter(() => request("credits"), mapOpenRouterCreditsResponse),
    collectMeter(() => request("key"), mapOpenRouterKeyResponse),
  ]);
  const credits = creditsResult.value;
  const keyData: OpenRouterKeyData | undefined = keyResult.value;

  const windows = mapOpenRouterWindows(credits, keyData);
  if (windows.length === 0) {
    const unavailable =
      creditsResult.unavailable &&
      keyResult.unavailable &&
      !creditsResult.malformed &&
      !keyResult.malformed;
    throw new ProviderCollectionError(
      unavailable ? "unavailable" : "error",
      unavailable
        ? "OpenRouter quota endpoints are temporarily unavailable."
        : "OpenRouter returned no usable credit or key-limit quota.",
      OPENROUTER_SOURCE_API,
    );
  }

  return buildOpenRouterSnapshot({
    windows,
    credentials,
    ...(now ? { now } : {}),
  });
}

async function collectMeter<T>(
  request: () => Promise<unknown>,
  map: (json: unknown) => T | undefined,
): Promise<{ value?: T; unavailable: boolean; malformed: boolean }> {
  try {
    const json = await request();
    const value = json === undefined ? undefined : map(json);
    return {
      ...(value === undefined ? {} : { value }),
      unavailable: false,
      malformed: json !== undefined && value === undefined,
    };
  } catch (error) {
    if (error instanceof ProviderCollectionError && error.category === "auth_required") {
      throw error;
    }
    return {
      unavailable: error instanceof ProviderCollectionError && error.category === "unavailable",
      malformed: false,
    };
  }
}
