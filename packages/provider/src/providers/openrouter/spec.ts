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
  urlEnvKey: "OPENROUTER_API_URL",
  defaultBaseUrl: "https://openrouter.ai/api/v1",
  maskLabel: "OpenRouter",
  collect: collectOpenRouter,
};

async function collectOpenRouter(ctx: ApiKeyCollectContext) {
  const { credentials, transport, clientVersion, signal, now } = ctx;

  // Credits and /key are independent meters. Auth failures still surface; soft failures
  // leave that meter undefined so key-limit-only accounts can succeed.
  let credits = undefined as ReturnType<typeof mapOpenRouterCreditsResponse>;
  try {
    const creditsJson = await fetchBearerJson({
      transport,
      url: `${credentials.baseUrl}/credits`,
      apiKey: credentials.apiKey,
      source: OPENROUTER_SOURCE_API,
      providerLabel: "OpenRouter",
      clientVersion,
      required: false,
      ...(signal ? { signal } : {}),
      extraHeaders: { "X-Title": clientVersion },
    });
    credits = creditsJson !== undefined ? mapOpenRouterCreditsResponse(creditsJson) : undefined;
  } catch (error) {
    if (error instanceof ProviderCollectionError && error.category === "auth_required") {
      throw error;
    }
    credits = undefined;
  }

  let keyData: OpenRouterKeyData | undefined;
  try {
    const keyJson = await fetchBearerJson({
      transport,
      url: `${credentials.baseUrl}/key`,
      apiKey: credentials.apiKey,
      source: OPENROUTER_SOURCE_API,
      providerLabel: "OpenRouter",
      clientVersion,
      required: false,
      ...(signal ? { signal } : {}),
      extraHeaders: { "X-Title": clientVersion },
    });
    keyData = keyJson !== undefined ? mapOpenRouterKeyResponse(keyJson) : undefined;
  } catch (error) {
    if (error instanceof ProviderCollectionError && error.category === "auth_required") {
      throw error;
    }
    keyData = undefined;
  }

  const windows = mapOpenRouterWindows(credits, keyData);
  if (windows.length === 0) {
    throw new ProviderCollectionError(
      "error",
      "OpenRouter returned no usable credit or key-limit quota.",
      OPENROUTER_SOURCE_API,
    );
  }

  return buildOpenRouterSnapshot({
    windows,
    credentials,
    ...(now ? { now } : {}),
  });
}
