import packageMetadata from "../package.json" with { type: "json" };

export const QUOTA_RELAY_VERSION = packageMetadata.version;
export const CANONICAL_ORIGIN = "https://quota.gotry.io";

export function managedServiceInfo() {
  return {
    service: "QuotaRelay",
    version: QUOTA_RELAY_VERSION,
    protocol_version: 2 as const,
    mode: "managed" as const,
  };
}
