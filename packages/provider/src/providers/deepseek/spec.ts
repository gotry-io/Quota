import { ProviderCollectionError } from "../../contracts.ts";
import {
  type ApiKeyCollectContext,
  type ApiKeyHttpCollectorSpec,
  fetchBearerJson,
} from "../../api-key/index.ts";
import {
  buildDeepSeekSnapshot,
  DEEPSEEK_SOURCE_API,
  mapDeepSeekBalanceResponse,
  mapDeepSeekWindows,
} from "./map.ts";

export { DEEPSEEK_SOURCE_API };

export const deepseekSpec: ApiKeyHttpCollectorSpec = {
  provider: "deepseek",
  source: DEEPSEEK_SOURCE_API,
  envKeys: ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"],
  defaultBaseUrl: "https://api.deepseek.com",
  maskLabel: "DeepSeek",
  collect: collectDeepSeek,
};

async function collectDeepSeek(ctx: ApiKeyCollectContext) {
  const { credentials, transport, clientVersion, signal, now } = ctx;
  const json = await fetchBearerJson({
    transport,
    url: `${credentials.baseUrl}/user/balance`,
    apiKey: credentials.apiKey,
    source: DEEPSEEK_SOURCE_API,
    providerLabel: "DeepSeek",
    clientVersion,
    ...(signal ? { signal } : {}),
  });
  const balances = mapDeepSeekBalanceResponse(json);
  if (!balances) {
    throw new ProviderCollectionError(
      "error",
      "DeepSeek balance response was malformed.",
      DEEPSEEK_SOURCE_API,
    );
  }
  const windows = mapDeepSeekWindows(balances);
  if (windows.length === 0) {
    throw new ProviderCollectionError(
      "error",
      "DeepSeek returned no usable balance windows.",
      DEEPSEEK_SOURCE_API,
    );
  }
  return buildDeepSeekSnapshot({
    windows,
    credentials,
    ...(now ? { now } : {}),
  });
}
