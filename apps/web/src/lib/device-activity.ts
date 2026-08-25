import type { AccountDeviceRead } from "@gotry-io/quota-protocol";

export type DeviceActivityPresentation = {
  label: string;
  tone: "available" | "offline" | "unavailable";
};

const activeWithinMilliseconds = 30 * 60 * 1000;
const idleWithinMilliseconds = 24 * 60 * 60 * 1000;

/**
 * How recently a device spoke, from the two things Relay actually witnessed: when the device
 * last called, and when the newest reading it sent was taken. A device that is asleep or closed
 * is quiet, not broken, so nothing here claims a device is unhealthy.
 */
export function deviceActivity(
  device: Pick<AccountDeviceRead, "last_seen_at" | "last_observed_at">,
  now: Date = new Date(),
): DeviceActivityPresentation {
  const instants = [device.last_seen_at, device.last_observed_at]
    .filter((value): value is string => value !== null)
    .map((value) => Date.parse(value))
    .filter((value) => Number.isFinite(value));
  if (instants.length === 0) {
    return { label: "Not reporting", tone: "unavailable" };
  }
  const age = now.getTime() - Math.max(...instants);
  if (age < activeWithinMilliseconds) {
    return { label: "Active", tone: "available" };
  }
  if (age < idleWithinMilliseconds) {
    return { label: "Idle", tone: "offline" };
  }
  return { label: "Not reporting", tone: "unavailable" };
}
