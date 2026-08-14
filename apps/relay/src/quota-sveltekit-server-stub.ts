export class Server {
  readonly #manifest: unknown;

  constructor(manifest: unknown) {
    this.#manifest = manifest;
  }
  async init(_opts: { env: object }): Promise<void> {}
  async respond(_request: Request): Promise<Response> {
    void this.#manifest;
    return new Response("quota-sveltekit-server-stub", { status: 599 });
  }
}

export const manifest = {};
