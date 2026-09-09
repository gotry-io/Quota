import { fileURLToPath } from "node:url";
import { configDefaults, defineConfig } from "vitest/config";

/**
 * The same `test/*.test.ts` files as the Workers project, against in-memory SQLite.
 *
 * This config is independent of `vitest.config.ts`: it must not load
 * `@cloudflare/vitest-pool-workers`, because that pool owns the run even when a file asks for
 * `environment: "node"` ([ADR 0049](../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
export default defineConfig({
  define: {
    "import.meta.env.RELAY_TEST_DRIVER": JSON.stringify("sqlite"),
  },
  resolve: {
    alias: {
      "quota-sveltekit-server": fileURLToPath(
        new URL("./src/quota-sveltekit-server-stub.ts", import.meta.url),
      ),
    },
  },
  test: {
    name: "node",
    environment: "node",
    env: {
      RELAY_TEST_DRIVER: "sqlite",
    },
    exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts", "test/platform/**"],
  },
});
