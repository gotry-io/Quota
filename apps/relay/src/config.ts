import type { RelayInfo } from "@gotry-io/quota-protocol";
import packageMetadata from "../package.json" with { type: "json" };

export const QUOTA_RELAY_VERSION = packageMetadata.version;

export function managedRelayInfo(instanceId: string): RelayInfo {
  return relayInfo(instanceId, "managed", true);
}

export function selfHostedRelayInfo(instanceId: string): RelayInfo {
  // multi_tenant advertises isolated owner groups on one instance, not user accounts.
  return relayInfo(instanceId, "self_hosted", true);
}

function relayInfo(instanceId: string, mode: RelayInfo["mode"], multiTenant: boolean): RelayInfo {
  return {
    instance_id: instanceId,
    mode,
    version: QUOTA_RELAY_VERSION,
    api_versions: [1],
    auth_methods: ["bearer"],
    capabilities: {
      realtime: false,
      persistent_snapshots: true,
      instant_device_revocation: true,
      history: false,
      multi_tenant: multiTenant,
    },
  };
}
