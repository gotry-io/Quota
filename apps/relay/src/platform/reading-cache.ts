/**
 * Where the provider status route keeps the last reading it got from an official status page.
 *
 * It is the `Cache` shape narrowed to the two calls that route makes, so Workers can hand it
 * `caches.default` unchanged and Node can hand it a Map
 * ([ADR 0049](../../../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
export interface LastReadingCache {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
}

/** The Workers cache shared by every isolate in a colo. */
export class WorkersReadingCache implements LastReadingCache {
  /** The DOM `CacheStorage` the type check also loads has no `default`; the Workers one does. */
  private readonly cache = (caches as unknown as { default: Cache }).default;

  match(request: Request): Promise<Response | undefined> {
    return this.cache.match(request);
  }

  put(request: Request, response: Response): Promise<void> {
    return this.cache.put(request, response);
  }
}

/**
 * One process's cache, for the Node deployment.
 *
 * Freshness is decided by the `checked_at` inside the reading, so the expiry here only bounds how
 * long a reading nothing refreshed keeps taking memory. It is far longer than that freshness
 * window, because a reading that has gone stale is still the last good answer when a poll fails.
 */
export const MEMORY_READING_RETENTION_MILLISECONDS = 24 * 60 * 60 * 1000;

export class MemoryReadingCache implements LastReadingCache {
  private readonly entries = new Map<string, { body: string; expiresAt: number }>();

  constructor(private readonly now: () => number = Date.now) {}

  async match(request: Request): Promise<Response | undefined> {
    const entry = this.entries.get(request.url);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(request.url);
      return undefined;
    }
    return new Response(entry.body, { headers: { "Content-Type": "application/json" } });
  }

  async put(request: Request, response: Response): Promise<void> {
    this.entries.set(request.url, {
      body: await response.text(),
      expiresAt: this.now() + MEMORY_READING_RETENTION_MILLISECONDS,
    });
  }
}
