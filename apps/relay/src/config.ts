import type { RelayInfo } from "@gotry-io/quota-protocol";
import packageMetadata from "../package.json" with { type: "json" };

export const QUOTA_RELAY_VERSION = packageMetadata.version;

export function managedRelayInfo(instanceId: string): RelayInfo {
  return relayInfo(instanceId, "managed", false);
}

export function selfHostedRelayInfo(instanceId: string): RelayInfo {
  return relayInfo(instanceId, "self_hosted", true);
}

function relayInfo(
  instanceId: string,
  mode: RelayInfo["mode"],
  ownerBootstrapEnabled: boolean,
): RelayInfo {
  return {
    instance_id: instanceId,
    mode,
    version: QUOTA_RELAY_VERSION,
    api_versions: [1],
    auth_methods: ownerBootstrapEnabled ? ["bearer"] : [],
    capabilities: {
      realtime: false,
      persistent_snapshots: ownerBootstrapEnabled,
      instant_device_revocation: ownerBootstrapEnabled,
      history: false,
      multi_tenant: false,
    },
  };
}
