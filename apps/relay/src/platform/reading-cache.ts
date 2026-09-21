/**
 * Where the provider status route keeps the last reading it got from an official status page.
 *
 * Node hands this a process-local Map
 * ([ADR 0058](../../../../docs/decisions/0058-relay-runs-on-node-only.md)).
 */
export interface LastReadingCache {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
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
