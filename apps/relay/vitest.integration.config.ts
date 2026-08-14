import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

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
        new URL("../web/.svelte-kit/output/server/quota-sveltekit-server.js", import.meta.url),
      ),
    },
  },
  test: {
    provide: { TEST_MIGRATIONS: migrations },
    include: ["test/**/*.integration.test.ts"],
  },
});
