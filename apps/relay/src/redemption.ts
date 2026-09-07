export const REDEMPTION_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const REDEMPTION_CODE_BODY_LENGTH = 16;
const REDEMPTION_CODE_PREFIX = "QUOTA";

export function normalizeRedemptionCode(input: string): string {
  const compact = input.toUpperCase().replace(/[-\s]/g, "");
  return compact.startsWith(REDEMPTION_CODE_PREFIX)
    ? compact.slice(REDEMPTION_CODE_PREFIX.length)
    : compact;
}

export function formatRedemptionCode(body: string): string {
  return `${REDEMPTION_CODE_PREFIX}-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12, 16)}`;
}

export function generateRedemptionCodeBodies(count: number): string[] {
  const bodies: string[] = [];
  const seen = new Set<string>();
  while (bodies.length < count) {
    const bytes = new Uint8Array(REDEMPTION_CODE_BODY_LENGTH);
    crypto.getRandomValues(bytes);
    const body = Array.from(bytes, (byte) => REDEMPTION_CODE_ALPHABET.charAt(byte & 31)).join("");
    if (seen.has(body)) continue;
    seen.add(body);
    bodies.push(body);
  }
  return bodies;
}
