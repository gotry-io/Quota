declare module "quota-sveltekit-server" {
  export class Server {
    constructor(manifest: unknown);
    init(opts: {
      env: object;
      read?: (file: string) => ReadableStream | Promise<ReadableStream | null>;
    }): Promise<void>;
    respond(
      request: Request,
      opts: {
        platform: object;
        getClientAddress: () => string;
      },
    ): Promise<Response>;
  }
  export const manifest: unknown;
}
