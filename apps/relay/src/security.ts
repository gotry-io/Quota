const textEncoder = new TextEncoder();
const userCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export class SecretHasher {
  constructor(private readonly key: string) {
    if (key.length < 32) {
      throw new Error("Credential hashing key must contain at least 32 characters");
    }
  }

  hash(kind: string, value: string): Promise<string> {
    return hmacSha256Hex(this.key, `${kind}:${value}`);
  }
}

export async function hmacSha256Hex(key: string, value: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", cryptoKey, textEncoder.encode(value));
  return bytesToHex(new Uint8Array(digest));
}

export async function sha256Base64Url(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(value));
  return bytesToBase64Url(new Uint8Array(digest));
}

export async function canonicalRequestDigest(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(canonicalJSON(value)));
  return bytesToHex(new Uint8Array(digest));
}

export function randomOpaqueSecret(prefix = ""): string {
  return `${prefix}${bytesToBase64Url(crypto.getRandomValues(new Uint8Array(32)))}`;
}

export function randomUserCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const characters = Array.from(
    bytes,
    (byte) => userCodeAlphabet[byte % userCodeAlphabet.length] ?? "",
  );
  return `${characters.slice(0, 4).join("")}-${characters.slice(4).join("")}`;
}

export function bearerToken(authorization: string | undefined): string | undefined {
  return authorization ? /^Bearer ([^\s]+)$/.exec(authorization)?.[1] : undefined;
}

export function normalizeUserCode(value: string): string {
  return value.trim().toUpperCase();
}

export function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = textEncoder.encode(left);
  const rightBytes = textEncoder.encode(right);
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

export function encodeBase64UrlJSON(value: unknown): string {
  return bytesToBase64Url(textEncoder.encode(JSON.stringify(value)));
}

export function decodeBase64UrlJSON(value: string): unknown {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(`${normalized}${padding}`);
  return JSON.parse(
    new TextDecoder().decode(Uint8Array.from(binary, (character) => character.charCodeAt(0))),
  );
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function canonicalJSON(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(",")}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value)
      .filter(([, item]) => item !== undefined)
      .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
    return `{${entries
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJSON(item)}`)
      .join(",")}}`;
  }
  throw new Error("Request contains a non-JSON value");
}
