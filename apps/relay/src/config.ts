import type { RelayInfo } from "@gotry-io/quota-protocol";
import packageMetadata from "../package.json" with { type: "json" };

export const QUOTA_RELAY_VERSION = packageMetadata.version;

export function managedRelayInfo(instanceId: string): RelayInfo {
  return bootstrapRelayInfo(instanceId, "managed");
}

export function selfHostedRelayInfo(instanceId: string): RelayInfo {
  return bootstrapRelayInfo(instanceId, "self_hosted");
}

function bootstrapRelayInfo(instanceId: string, mode: RelayInfo["mode"]): RelayInfo {
  return {
    instance_id: instanceId,
    mode,
    version: QUOTA_RELAY_VERSION,
    api_versions: [1],
    auth_methods: [],
    capabilities: {
      realtime: false,
      persistent_snapshots: false,
      instant_device_revocation: false,
      history: false,
      multi_tenant: false,
    },
  };
}
