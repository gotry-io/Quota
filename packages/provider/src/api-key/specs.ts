import type { ProviderId } from "@gotry-io/quota-protocol";
import { deepseekSpec } from "../providers/deepseek/spec.ts";
import { kimiSpec } from "../providers/kimi/spec.ts";
import { litellmSpec } from "../providers/litellm/spec.ts";
import { openrouterSpec } from "../providers/openrouter/spec.ts";
import type { ApiKeyHttpCollectorSpec } from "./collector.ts";

/** All API-key HTTPS collectors. Ambient OAuth providers are registered separately. */
export const API_KEY_SPECS = {
  openrouter: openrouterSpec,
  deepseek: deepseekSpec,
  kimi: kimiSpec,
  litellm: litellmSpec,
} as const satisfies Record<string, ApiKeyHttpCollectorSpec>;

export type ApiKeyProviderId = keyof typeof API_KEY_SPECS;

export function isApiKeyProviderId(id: string): id is ApiKeyProviderId {
  return Object.hasOwn(API_KEY_SPECS, id);
}

export function apiKeySpec(id: ApiKeyProviderId): ApiKeyHttpCollectorSpec {
  return API_KEY_SPECS[id];
}

export function apiKeyProviderIds(): ProviderId[] {
  return Object.keys(API_KEY_SPECS) as ProviderId[];
}
