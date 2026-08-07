import { ProviderCollectionError } from "../../contracts.ts";
import {
  type ApiKeyCollectContext,
  type ApiKeyHttpCollectorSpec,
  buildApiKeySnapshot,
  fetchBearerJson,
} from "../../api-key/index.ts";
import { mapKimiUsagesResponse, mapKimiWindows } from "./map.ts";

export const KIMI_SOURCE_API = "kimi_code_usages_api";

export const kimiSpec: ApiKeyHttpCollectorSpec = {
  provider: "kimi",
  source: KIMI_SOURCE_API,
  envKeys: ["KIMI_CODE_API_KEY", "KIMI_API_KEY"],
  urlEnvKey: "KIMI_CODE_BASE_URL",
  defaultBaseUrl: "https://api.kimi.com",
  maskLabel: "Kimi",
  collect: collectKimi,
};

async function collectKimi(ctx: ApiKeyCollectContext) {
  const { credentials, transport, clientVersion, signal, now } = ctx;
  const json = await fetchBearerJson({
    transport,
    url: `${credentials.baseUrl}/coding/v1/usages`,
    apiKey: credentials.apiKey,
    source: KIMI_SOURCE_API,
    providerLabel: "Kimi",
    clientVersion,
    ...(signal ? { signal } : {}),
  });
  const data = mapKimiUsagesResponse(json);
  if (!data) {
    throw new ProviderCollectionError(
      "error",
      "Kimi usages response was malformed.",
      KIMI_SOURCE_API,
    );
  }
  const windows = mapKimiWindows(data);
  if (windows.length === 0) {
    throw new ProviderCollectionError(
      "error",
      "Kimi returned no usable quota windows.",
      KIMI_SOURCE_API,
    );
  }
  return buildApiKeySnapshot({
    provider: "kimi",
    source: KIMI_SOURCE_API,
    credentials,
    windows,
    plan: "Kimi Code",
    ...(now ? { now } : {}),
  });
}
