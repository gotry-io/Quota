export function isRelayApiPath(pathname: string): boolean {
  return (
    pathname === "/healthz" ||
    pathname === "/readyz" ||
    pathname === "/api" ||
    pathname === "/oauth" ||
    pathname.startsWith("/api/") ||
    pathname.startsWith("/oauth/")
  );
}
