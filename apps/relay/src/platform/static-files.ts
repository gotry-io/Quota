import { readFile, stat } from "node:fs/promises";
import { join, normalize, resolve, sep } from "node:path";

/**
 * The built website's files, as the deployment serves them.
 *
 * On Workers this is the Static Assets binding; on Node it is the SvelteKit client build read
 * from disk ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)). A path the
 * build did not produce answers 404, which is how the entry decides to render a document instead.
 */
export interface StaticFiles {
  fetch(url: URL): Promise<Response>;
}

export class WorkersStaticFiles implements StaticFiles {
  constructor(private readonly assets: Fetcher) {}

  fetch(url: URL): Promise<Response> {
    return this.assets.fetch(url);
  }
}

/**
 * Vite fingerprints everything under `_app/immutable`, so those may be held for a year; every
 * other file keeps its name across builds and must be revalidated.
 */
const IMMUTABLE_PREFIX = "/_app/immutable/";
const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";
const REVALIDATE_CACHE_CONTROL = "public, no-cache";

const CONTENT_TYPES = new Map<string, string>([
  [".avif", "image/avif"],
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".ico", "image/vnd.microsoft.icon"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".map", "application/json; charset=utf-8"],
  [".md", "text/markdown; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
  [".webmanifest", "application/manifest+json"],
  [".webp", "image/webp"],
  [".woff2", "font/woff2"],
  [".xml", "application/xml"],
]);

export class NodeStaticFiles implements StaticFiles {
  private readonly root: string;

  constructor(directory: string) {
    this.root = resolve(directory);
  }

  async fetch(url: URL): Promise<Response> {
    const path = this.resolveWithin(url.pathname);
    if (path === null) return new Response(null, { status: 404 });
    let body: Buffer;
    try {
      if (!(await stat(path)).isFile()) return new Response(null, { status: 404 });
      body = await readFile(path);
    } catch {
      return new Response(null, { status: 404 });
    }
    return new Response(new Uint8Array(body), {
      headers: {
        "Content-Type": contentType(path),
        "Content-Length": String(body.byteLength),
        "Cache-Control": url.pathname.startsWith(IMMUTABLE_PREFIX)
          ? IMMUTABLE_CACHE_CONTROL
          : REVALIDATE_CACHE_CONTROL,
      },
    });
  }

  /** A percent-encoded `..` is still `..`, so the decoded path is what has to stay inside root. */
  private resolveWithin(pathname: string): string | null {
    let decoded: string;
    try {
      decoded = decodeURIComponent(pathname);
    } catch {
      return null;
    }
    if (decoded.includes("\0")) return null;
    const path = resolve(join(this.root, normalize(decoded)));
    return path === this.root || path.startsWith(this.root + sep) ? path : null;
  }
}

function contentType(path: string): string {
  const extension = path.slice(path.lastIndexOf("."));
  return CONTENT_TYPES.get(extension) ?? "application/octet-stream";
}
