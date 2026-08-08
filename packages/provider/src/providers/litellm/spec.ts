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

  const userId = keyInfo.userId;
  const teamId = keyInfo.teamId;
  const [personal, team] = await Promise.all([
    userId
      ? fetchBearerJson({
          ...common,
          url: `${root}/user/info?user_id=${encodeURIComponent(userId)}`,
        }).then(mapLiteLLMUserInfo)
      : undefined,
    teamId
      ? fetchBearerJson({
          ...common,
          url: `${root}/team/info?team_id=${encodeURIComponent(teamId)}`,
          required: !userId,
        }).then((json) => (json === undefined ? undefined : mapLiteLLMTeamInfo(json, teamId)))
      : undefined,
  ]);

  const windows = mapLiteLLMWindows({
    ...(personal ? { personal } : {}),
    ...(team ? { team } : {}),
  });
  if (windows.length === 0) {
    throw new ProviderCollectionError(
      "error",
      "LiteLLM returned no usable budget windows.",
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
