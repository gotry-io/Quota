/**
 * Who is calling, as far as the deployment can tell.
 *
 * Rate limits and the anonymous read budget are counted per address, so both runtimes have to
 * answer this the same way. Cloudflare states it in `CF-Connecting-IP`, and a Tunnel in front of
 * the Node deployment states it in the same header; a plain reverse proxy states it in
 * `X-Forwarded-For`, whose first hop is the client and whose later hops are the proxies. When
 * neither is present the Node entry has already written the connection's own address into
 * `X-Forwarded-For`, because it is then the edge itself.
 */
export function clientAddress(headers: Headers): string | null {
  const connecting = headers.get("CF-Connecting-IP")?.trim();
  if (connecting) return connecting;
  const forwarded = headers.get("X-Forwarded-For")?.split(",")[0]?.trim();
  return forwarded ? forwarded : null;
}

/**
 * Name the connection's own address as the first `X-Forwarded-For` hop, unless a proxy in front
 * already named the client. Mutating the header rather than rebuilding the request keeps the
 * body a stream the handler can still read.
 */
export function recordConnectionAddress(request: Request, address: string | undefined): void {
  if (!address || clientAddress(request.headers)) return;
  request.headers.set("X-Forwarded-For", address);
}
