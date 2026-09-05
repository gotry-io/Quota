import type { AccountDeviceRead } from "@gotry-io/quota-protocol";

type DeviceActivityPresentation = {
  label: string;
  tone: "available" | "offline" | "unavailable";
  /** The instant the label is derived from, so the row states one age rather than a list. */
  since: string | null;
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
    .filter((value) => Number.isFinite(Date.parse(value)));
  if (instants.length === 0) {
    return { label: "Not reporting", tone: "unavailable", since: null };
  }
  const since = instants.reduce((newest, value) =>
    Date.parse(value) > Date.parse(newest) ? value : newest,
  );
  const age = now.getTime() - Date.parse(since);
  if (age < activeWithinMilliseconds) {
    return { label: "Active", tone: "available", since };
  }
  if (age < idleWithinMilliseconds) {
    return { label: "Idle", tone: "offline", since };
  }
  return { label: "Not reporting", tone: "unavailable", since };
}

/** macOS glyph, or a generic device for every other platform value. */
export function platformIconKind(platform: string): "mac" | "generic" {
  return platform === "macos" ? "mac" : "generic";
}

/** Last-seen descending. A Device that has never called sorts last. */
export function sortDevicesByLastSeen<T extends { last_seen_at: string | null }>(
  devices: readonly T[],
): T[] {
  return devices.slice().sort((left, right) => {
    const leftMs = left.last_seen_at ? Date.parse(left.last_seen_at) : Number.NEGATIVE_INFINITY;
    const rightMs = right.last_seen_at ? Date.parse(right.last_seen_at) : Number.NEGATIVE_INFINITY;
    return rightMs - leftMs;
  });
}
