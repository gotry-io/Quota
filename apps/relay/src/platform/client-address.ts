/**
 * Who is calling, as far as the deployment can tell.
 *
 * Rate limits and the anonymous read budget are counted per address. Each entry sanitises the
 * headers before the app reads them: Node honours only `RELAY_CLIENT_ADDRESS_HEADER` from
 * `RELAY_TRUSTED_PROXIES` peers and otherwise writes the socket peer; Workers keeps
 * `CF-Connecting-IP` (the platform sets it; clients cannot forge it there) and drops
 * `X-Forwarded-For`. This function is runtime-neutral: it only reads those headers.
 */

export const DEFAULT_TRUSTED_PROXIES =
  "127.0.0.0/8, ::1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7";

export const CLIENT_ADDRESS_HEADERS = ["x-forwarded-for", "cf-connecting-ip"] as const;
export type ClientAddressHeader = (typeof CLIENT_ADDRESS_HEADERS)[number];
export const DEFAULT_CLIENT_ADDRESS_HEADER: ClientAddressHeader = "x-forwarded-for";

const FORGED_ADDRESS_HEADERS = [
  "CF-Connecting-IP",
  "X-Forwarded-For",
  "X-Real-IP",
  "Forwarded",
] as const;

export type TrustedRange =
  | { version: 4; network: number; prefix: number }
  | { version: 6; network: Uint8Array; prefix: number };

export type TrustedProxies = readonly TrustedRange[];

let boundTrustedProxies: TrustedProxies = [];

/**
 * The Node entry binds the parsed `RELAY_TRUSTED_PROXIES` list so `clientAddress` can walk an
 * `X-Forwarded-For` chain that a trusted peer was allowed to keep. Workers never binds, so the
 * list stays empty and `X-Forwarded-For` is ignored after the Workers entry drops it.
 */
export function bindTrustedProxies(proxies: TrustedProxies): void {
  boundTrustedProxies = proxies;
}

/**
 * Parse `RELAY_TRUSTED_PROXIES`. Unset or empty uses loopback, RFC1918, and unique-local IPv6
 * (the Docker-bridge default). A token that is not a CIDR or address refuses to start: there is
 * no silent fallback onto the default once the operator has named a list.
 */
export function parseTrustedProxies(source: string | undefined): TrustedProxies {
  const trimmed = source?.trim();
  const text = trimmed ? trimmed : DEFAULT_TRUSTED_PROXIES;
  const ranges: TrustedRange[] = [];
  for (const raw of text.split(",")) {
    const token = raw.trim();
    if (token.length === 0) {
      throw invalidTrustedProxies(raw);
    }
    const range = parseRange(token);
    if (range === null) {
      throw invalidTrustedProxies(token);
    }
    ranges.push(range);
  }
  return ranges;
}

/**
 * Parse `RELAY_CLIENT_ADDRESS_HEADER`. Unset or empty is `x-forwarded-for`. Only
 * `x-forwarded-for` and `cf-connecting-ip` are accepted; anything else refuses to start.
 */
export function parseClientAddressHeader(source: string | undefined): ClientAddressHeader {
  const trimmed = source?.trim();
  if (!trimmed) return DEFAULT_CLIENT_ADDRESS_HEADER;
  const normalised = trimmed.toLowerCase();
  if (normalised === "x-forwarded-for" || normalised === "cf-connecting-ip") {
    return normalised;
  }
  throw new Error(
    `QuotaRelay has invalid RELAY_CLIENT_ADDRESS_HEADER: ${JSON.stringify(source)} ` +
      "(want x-forwarded-for or cf-connecting-ip)",
  );
}

export function clientAddress(
  headers: Headers,
  trusted: TrustedProxies = boundTrustedProxies,
): string | null {
  const connecting = headers.get("CF-Connecting-IP")?.trim();
  if (connecting) return displayAddress(connecting);
  return forwardedClient(headers.get("X-Forwarded-For"), trusted);
}

/**
 * Decide, from the socket peer, whether this request's forwarding headers are from a proxy
 * Relay was told about. Only the Node entry sees the peer.
 *
 * An untrusted peer can send `CF-Connecting-IP` itself, so those headers are stripped and the
 * peer is recorded as `X-Forwarded-For`. A trusted peer may keep only the header
 * `RELAY_CLIENT_ADDRESS_HEADER` names; the other of `CF-Connecting-IP` / `X-Forwarded-For` is
 * stripped so a client-supplied `CF-Connecting-IP` is not believed just because Caddy forwarded
 * it. `clientAddress` then takes `CF-Connecting-IP` if it remains, else the right-most
 * `X-Forwarded-For` hop that is not itself a trusted proxy. Mutating the headers rather than
 * rebuilding the request keeps the body a stream the handler can still read.
 */
export function applyNodeForwardedTrust(
  request: Request,
  peer: string | undefined,
  trusted: TrustedProxies,
  header: ClientAddressHeader = DEFAULT_CLIENT_ADDRESS_HEADER,
): void {
  const address = peer?.trim();
  if (address && addressIsTrusted(address, trusted)) {
    keepChosenClientAddressHeader(request.headers, header);
    return;
  }
  stripForgedAddressHeaders(request.headers);
  if (address) {
    request.headers.set("X-Forwarded-For", displayAddress(address));
  }
}

/**
 * Cloudflare states the client in `CF-Connecting-IP` and clients cannot forge it on this
 * runtime, so that header is kept. `X-Forwarded-For` and the other forwarding headers are
 * dropped. Incoming Workers requests have immutable headers, so a request that still carries
 * them is rebuilt.
 */
export function applyWorkersForwardedTrust(request: Request): Request {
  if (
    !request.headers.has("X-Forwarded-For") &&
    !request.headers.has("X-Real-IP") &&
    !request.headers.has("Forwarded")
  ) {
    return request;
  }
  const headers = new Headers(request.headers);
  headers.delete("X-Forwarded-For");
  headers.delete("X-Real-IP");
  headers.delete("Forwarded");
  return new Request(request, { headers });
}

export function addressIsTrusted(address: string, trusted: TrustedProxies): boolean {
  const parsed = parseAddress(address);
  if (parsed === null) return false;
  for (const range of trusted) {
    if (range.version === 4) {
      if (parsed.version === 4 || parsed.mapped) {
        if (ipv4InCidr(parsed.v4, range.network, range.prefix)) return true;
      }
    } else if (parsed.v6 !== undefined && ipv6InCidr(parsed.v6, range.network, range.prefix)) {
      return true;
    }
  }
  return false;
}

function forwardedClient(header: string | null, trusted: TrustedProxies): string | null {
  if (!header) return null;
  const hops = header.split(",");
  let leftMost: string | null = null;
  for (let index = hops.length - 1; index >= 0; index -= 1) {
    const hop = hops[index]?.trim();
    if (!hop || parseAddress(hop) === null) continue;
    const displayed = displayAddress(hop);
    leftMost = displayed;
    if (!addressIsTrusted(hop, trusted)) return displayed;
  }
  return leftMost;
}

function keepChosenClientAddressHeader(headers: Headers, header: ClientAddressHeader): void {
  headers.delete("X-Real-IP");
  headers.delete("Forwarded");
  if (header === "x-forwarded-for") {
    headers.delete("CF-Connecting-IP");
  } else {
    headers.delete("X-Forwarded-For");
  }
}

function stripForgedAddressHeaders(headers: Headers): void {
  for (const name of FORGED_ADDRESS_HEADERS) {
    headers.delete(name);
  }
}

function invalidTrustedProxies(token: string): Error {
  return new Error(
    `QuotaRelay has invalid RELAY_TRUSTED_PROXIES: ${JSON.stringify(token)} is not a CIDR or address`,
  );
}

function parseRange(token: string): TrustedRange | null {
  const slash = token.lastIndexOf("/");
  if (slash === -1) {
    const address = parseAddress(token);
    if (address === null) return null;
    if (address.version === 4 && !address.mapped) {
      return { version: 4, network: address.v4, prefix: 32 };
    }
    if (address.mapped) {
      return { version: 4, network: address.v4, prefix: 32 };
    }
    return { version: 6, network: address.v6, prefix: 128 };
  }
  const prefixText = token.slice(slash + 1);
  if (!/^\d{1,3}$/.test(prefixText)) return null;
  const prefix = Number(prefixText);
  const address = parseAddress(token.slice(0, slash));
  if (address === null) return null;
  if (address.version === 4 && !address.mapped) {
    return prefix <= 32 ? { version: 4, network: address.v4, prefix } : null;
  }
  return prefix <= 128 ? { version: 6, network: address.v6, prefix } : null;
}

type ParsedAddress =
  | { version: 4; v4: number; mapped: false; v6?: undefined }
  | { version: 4; v4: number; mapped: true; v6: Uint8Array }
  | { version: 6; v4?: undefined; mapped: false; v6: Uint8Array };

function parseAddress(text: string): ParsedAddress | null {
  const trimmed = text.trim();
  const v4 = parseIPv4(trimmed);
  if (v4 !== null) return { version: 4, v4, mapped: false };
  const v6 = parseIPv6(trimmed);
  if (v6 === null) return null;
  const mapped = ipv4Mapped(v6);
  if (mapped !== null) return { version: 4, v4: mapped, mapped: true, v6 };
  return { version: 6, mapped: false, v6 };
}

function displayAddress(text: string): string {
  const parsed = parseAddress(text);
  if (parsed === null) return text.trim();
  if (parsed.version === 4) return formatIPv4(parsed.v4);
  return text.trim();
}

function parseIPv4(text: string): number | null {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^(0|[1-9]\d{0,2})$/.test(part)) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    value = (value << 8) + octet;
  }
  return value >>> 0;
}

function formatIPv4(value: number): string {
  return `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`;
}

function ipv4InCidr(address: number, network: number, prefix: number): boolean {
  if (prefix === 0) return true;
  const shift = 32 - prefix;
  return address >>> shift === network >>> shift;
}

function parseIPv6(text: string): Uint8Array | null {
  let value = text;
  if (value.startsWith("[") && value.endsWith("]")) {
    value = value.slice(1, -1);
  }
  const zone = value.indexOf("%");
  if (zone !== -1) value = value.slice(0, zone);
  if (value.length === 0) return null;

  const lastColon = value.lastIndexOf(":");
  const lastPart = lastColon === -1 ? value : value.slice(lastColon + 1);
  if (lastPart.includes(".")) {
    const embedded = parseIPv4(lastPart);
    if (embedded === null) return null;
    const hi = ((embedded >>> 16) & 0xffff).toString(16);
    const lo = (embedded & 0xffff).toString(16);
    value = `${value.slice(0, lastColon + 1)}${hi}:${lo}`;
  }

  const halves = value.split("::");
  if (halves.length > 2) return null;
  const parseGroups = (side: string): number[] | null => {
    if (side.length === 0) return [];
    const groups: number[] = [];
    for (const group of side.split(":")) {
      if (!/^[0-9a-fA-F]{1,4}$/.test(group)) return null;
      groups.push(Number.parseInt(group, 16));
    }
    return groups;
  };

  if (halves.length === 1) {
    const groups = parseGroups(halves[0] ?? "");
    if (groups === null || groups.length !== 8) return null;
    return groupsToBytes(groups);
  }

  const left = parseGroups(halves[0] ?? "");
  const right = parseGroups(halves[1] ?? "");
  if (left === null || right === null) return null;
  const missing = 8 - left.length - right.length;
  if (missing < 1) return null;
  return groupsToBytes([...left, ...Array<number>(missing).fill(0), ...right]);
}

function groupsToBytes(groups: readonly number[]): Uint8Array {
  const bytes = new Uint8Array(16);
  for (let index = 0; index < 8; index += 1) {
    const group = groups[index] ?? 0;
    bytes[index * 2] = group >>> 8;
    bytes[index * 2 + 1] = group & 0xff;
  }
  return bytes;
}

function ipv4Mapped(bytes: Uint8Array): number | null {
  for (let index = 0; index < 10; index += 1) {
    if (bytes[index] !== 0) return null;
  }
  if (bytes[10] !== 0xff || bytes[11] !== 0xff) return null;
  return (
    (((bytes[12] ?? 0) << 24) |
      ((bytes[13] ?? 0) << 16) |
      ((bytes[14] ?? 0) << 8) |
      (bytes[15] ?? 0)) >>>
    0
  );
}

function ipv6InCidr(address: Uint8Array, network: Uint8Array, prefix: number): boolean {
  const fullBytes = Math.floor(prefix / 8);
  for (let index = 0; index < fullBytes; index += 1) {
    if (address[index] !== network[index]) return false;
  }
  const remaining = prefix % 8;
  if (remaining === 0) return true;
  const mask = (0xff << (8 - remaining)) & 0xff;
  return ((address[fullBytes] ?? 0) & mask) === ((network[fullBytes] ?? 0) & mask);
}
