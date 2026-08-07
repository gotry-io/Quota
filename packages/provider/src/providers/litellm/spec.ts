import { ProviderCollectionError } from "../../contracts.ts";
import {
  type ApiKeyCollectContext,
  type ApiKeyHttpCollectorSpec,
  buildApiKeySnapshot,
  fetchBearerJson,
  stripTrailingV1,
} from "../../api-key/index.ts";
import {
  mapLiteLLMKeyInfo,
  mapLiteLLMTeamInfo,
  mapLiteLLMUserInfo,
  mapLiteLLMWindows,
} from "./map.ts";

export const LITELLM_SOURCE_API = "litellm_budget_api";

export const litellmSpec: ApiKeyHttpCollectorSpec = {
  provider: "litellm",
  source: LITELLM_SOURCE_API,
  envKeys: ["LITELLM_API_KEY"],
  urlEnvKey: "LITELLM_BASE_URL",
  requireBaseUrl: true,
  allowPrivateHttp: true,
  maskLabel: "LiteLLM",
  collect: collectLiteLLM,
};

async function collectLiteLLM(ctx: ApiKeyCollectContext) {
  const { credentials, transport, clientVersion, signal, now } = ctx;
  const root = stripTrailingV1(credentials.baseUrl);
  const common = {
    transport,
    apiKey: credentials.apiKey,
    source: LITELLM_SOURCE_API,
    providerLabel: "LiteLLM",
    clientVersion,
    ...(signal ? { signal } : {}),
  } as const;

  const keyJson = await fetchBearerJson({
    ...common,
    url: `${root}/key/info`,
  });
  const keyInfo = mapLiteLLMKeyInfo(keyJson);
  if (!keyInfo || (!keyInfo.userId && !keyInfo.teamId)) {
    throw new ProviderCollectionError(
      "error",
      "LiteLLM key info did not include a user_id or team_id.",
      LITELLM_SOURCE_API,
    );
  }

  let personal = undefined;
  let team = undefined;

  if (keyInfo.userId) {
    const userJson = await fetchBearerJson({
      ...common,
      url: `${root}/user/info?user_id=${encodeURIComponent(keyInfo.userId)}`,
    });
    personal = mapLiteLLMUserInfo(userJson);
  }

  if (keyInfo.teamId) {
    const teamJson = await fetchBearerJson({
      ...common,
      url: `${root}/team/info?team_id=${encodeURIComponent(keyInfo.teamId)}`,
      required: !keyInfo.userId,
    });
    if (teamJson !== undefined) {
      team = mapLiteLLMTeamInfo(teamJson, keyInfo.teamId);
    }
  }

  const windows = mapLiteLLMWindows({
    ...(personal ? { personal } : {}),
    ...(team ? { team } : {}),
  });
  if (windows.length === 0) {
    throw new ProviderCollectionError(
      "error",
      "LiteLLM returned no usable budget or spend windows.",
      LITELLM_SOURCE_API,
    );
  }

  return buildApiKeySnapshot({
    provider: "litellm",
    source: LITELLM_SOURCE_API,
    credentials,
    windows,
    plan: keyInfo.keyName ?? "LiteLLM",
    ...(now ? { now } : {}),
  });
}
