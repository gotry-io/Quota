export function toIsoOffset(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function unixSecondsToIso(seconds: number | undefined): string | undefined {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) {
    return undefined;
  }
  return toIsoOffset(new Date(seconds * 1000));
}

export function parseFlexibleDate(value: unknown): Date | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    // Heuristic: values larger than year 2100 in seconds are milliseconds.
    const millis = value > 10_000_000_000 ? value : value * 1000;
    const date = new Date(millis);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return undefined;
  }
  const asNumber = Number(trimmed);
  if (Number.isFinite(asNumber) && /^\d+(\.\d+)?$/.test(trimmed)) {
    return parseFlexibleDate(asNumber);
  }
  const date = new Date(trimmed);
  return Number.isNaN(date.getTime()) ? undefined : date;
}

export function dateToIso(value: Date | undefined): string | undefined {
  if (!value || Number.isNaN(value.getTime())) {
    return undefined;
  }
  return toIsoOffset(value);
}

export function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.min(100, value));
}

export function durationSecondsFromDates(start?: Date, end?: Date): number | undefined {
  if (!start || !end) {
    return undefined;
  }
  const seconds = Math.floor((end.getTime() - start.getTime()) / 1000);
  return seconds >= 0 ? seconds : undefined;
}
