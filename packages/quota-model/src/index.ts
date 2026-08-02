import type { QuotaSnapshot } from "@gotry-io/quota-protocol";

export function snapshotKey(snapshot: QuotaSnapshot): string {
  return `${snapshot.provider}:${snapshot.account.fingerprint}`;
}

export function remainingPercent(usedPercent: number): number {
  return Math.max(0, Math.min(100, 100 - usedPercent));
}

export function isSnapshotStale(snapshot: QuotaSnapshot, now = new Date()): boolean {
  if (snapshot.status === "stale") {
    return true;
  }

  if (!snapshot.valid_until) {
    return false;
  }

  return Date.parse(snapshot.valid_until) <= now.getTime();
}
