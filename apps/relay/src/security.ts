const textEncoder = new TextEncoder();
const userCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function randomOpaqueSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return bytesToBase64Url(bytes);
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
  if (!authorization) {
    return undefined;
  }
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  return match?.[1];
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
