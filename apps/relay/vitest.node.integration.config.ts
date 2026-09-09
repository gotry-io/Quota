import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const testSecret = "test-secret-that-is-long-enough-for-hmac-and-aes";

/**
 * The same integration test files as `vitest.integration.config.ts`, against in-memory SQLite.
 * No cloudflare pool; the SvelteKit server alias is the built website.
 */
export default defineConfig({
  define: {
    "import.meta.env.RELAY_TEST_DRIVER": JSON.stringify("sqlite"),
  },
  resolve: {
    alias: {
      "quota-sveltekit-server": fileURLToPath(
        new URL("../web/.svelte-kit/output/server/quota-sveltekit-server.js", import.meta.url),
      ),
    },
  },
  test: {
    name: "node-integration",
    environment: "node",
    env: {
      RELAY_TEST_DRIVER: "sqlite",
      GITHUB_CLIENT_ID: "test-github-client-id",
      GITHUB_CLIENT_SECRET: testSecret,
      IDENTITY_SUBJECT_KEY: testSecret,
      QUOTA_INSTALLATION_KEY: testSecret,
      QUOTA_SESSION_HASH_KEY: testSecret,
      RESEND_API_KEY: testSecret,
    },
    include: ["test/**/*.integration.test.ts"],
  },
});
