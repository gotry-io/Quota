import { fileURLToPath } from "node:url";
import { configDefaults, defineConfig } from "vitest/config";

/**
 * The Node suite: `test/*.test.ts` plus the SQLite driver and migration runner in
 * `test/platform`, against in-memory SQLite.
 *
 * Integration files stay on `test:node:integration` because they need the built website.
 */
export default defineConfig({
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
    exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts", "bench/**"],
  },
});
