import type { AccountDeviceRead, AccountQuotaObservationRead } from "@gotry-io/quota-protocol";

export type DeviceActivityPresentation = {
  label: string;
  tone: "available" | "offline" | "unavailable";
  lastReadingAt: string | null;
};

const activeWithinMilliseconds = 30 * 60 * 1000;
const idleWithinMilliseconds = 24 * 60 * 60 * 1000;

/**
 * How recently a device spoke, from the two things Relay actually witnessed: when the device
 * last called, and when the newest reading it sent was taken. A device that is asleep or closed
 * is quiet, not broken, so nothing here claims a device is unhealthy.
 */
export function deviceActivity(
  device: AccountDeviceRead,
  observations: readonly AccountQuotaObservationRead[],
  now: Date = new Date(),
): DeviceActivityPresentation {
  const readings = observations
    .filter((observation) => observation.device_id === device.device_id)
    .map((observation) => observation.snapshot.observed_at);
  const lastReadingAt = readings.length > 0 ? readings.reduce((a, b) => (a > b ? a : b)) : null;
  if (device.status === "signed_out") {
    return { label: "Signed out", tone: "offline", lastReadingAt };
  }
  const instants = [device.last_seen_at, lastReadingAt]
    .filter((value): value is string => value !== null)
    .map((value) => Date.parse(value))
    .filter((value) => Number.isFinite(value));
  if (instants.length === 0) {
    return { label: "Not reporting", tone: "unavailable", lastReadingAt };
  }
  const age = now.getTime() - Math.max(...instants);
  if (age < activeWithinMilliseconds) {
    return { label: "Active", tone: "available", lastReadingAt };
  }
  if (age < idleWithinMilliseconds) {
    return { label: "Idle", tone: "offline", lastReadingAt };
  }
  return { label: "Not reporting", tone: "unavailable", lastReadingAt };
}
