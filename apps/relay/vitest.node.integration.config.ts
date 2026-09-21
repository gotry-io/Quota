import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const testSecret = "test-secret-that-is-long-enough-for-hmac-and-aes";

/**
 * Integration tests against in-memory SQLite. The SvelteKit server alias is the built website.
 */
export default defineConfig({
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
