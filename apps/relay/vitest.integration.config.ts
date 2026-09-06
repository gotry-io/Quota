import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");
const testSecret = "test-secret-that-is-long-enough-for-hmac-and-aes";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          GITHUB_CLIENT_ID: "test-github-client-id",
          GITHUB_CLIENT_SECRET: testSecret,
          IDENTITY_SUBJECT_KEY: testSecret,
          QUOTA_INSTALLATION_KEY: testSecret,
          QUOTA_SESSION_HASH_KEY: testSecret,
        },
      },
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
