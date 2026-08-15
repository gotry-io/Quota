import type { AccountDeviceWithHealth } from "@gotry-io/quota-protocol";

export type DeviceHealthPresentation = {
  label: string;
  tone: "available" | "offline" | "unavailable";
  needsDeviceReview: boolean;
};

export function deviceHealthStatus(
  device: AccountDeviceWithHealth,
  now: Date = new Date(),
): DeviceHealthPresentation {
  if (device.status === "signed_out") {
    return { label: "Signed out", tone: "offline", needsDeviceReview: false };
  }
  const health = device.health;
  if (!health) return { label: "Unknown", tone: "offline", needsDeviceReview: false };
  if (now.getTime() > Date.parse(health.fresh_until)) {
    return { label: "Not recently active", tone: "offline", needsDeviceReview: false };
  }
  const healthyData = health.summary.data === "current" || health.summary.data === "empty";
  if (health.summary.operation !== "healthy" || !healthyData) {
    return { label: "Needs attention", tone: "unavailable", needsDeviceReview: true };
  }
  if (health.summary.attention === "required") {
    return { label: "Needs attention", tone: "unavailable", needsDeviceReview: true };
  }
  if (health.summary.attention === "optional") {
    return { label: "Check device", tone: "offline", needsDeviceReview: true };
  }
  return { label: "Healthy", tone: "available", needsDeviceReview: false };
}
