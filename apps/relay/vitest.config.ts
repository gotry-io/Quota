import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { configDefaults, defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
    }),
  ],
  resolve: {
    alias: {
      "quota-sveltekit-server": fileURLToPath(
        new URL("./src/quota-sveltekit-server-stub.ts", import.meta.url),
      ),
    },
  },
  test: {
    provide: { TEST_MIGRATIONS: migrations },
    exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts"],
  },
});
