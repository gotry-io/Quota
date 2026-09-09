import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { configDefaults, defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");

/**
 * Both runtimes, in one run.
 *
 * The Workers project is the deployment Cloudflare runs; the platform project is the SQLite
 * driver and the migration runner, which cannot be exercised inside workerd at all
 * ([ADR 0049](../../docs/decisions/0049-one-relay-two-runtimes.md)).
 */
export default defineConfig({
  test: {
    projects: [
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
          }),
        ],
        define: {
          "import.meta.env.RELAY_TEST_DRIVER": JSON.stringify("d1"),
        },
        resolve: {
          alias: {
            "quota-sveltekit-server": fileURLToPath(
              new URL("./src/quota-sveltekit-server-stub.ts", import.meta.url),
            ),
          },
        },
        test: {
          name: "workers",
          provide: { TEST_MIGRATIONS: migrations },
          exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts", "test/platform/**"],
        },
      },
      {
        test: {
          name: "platform",
          environment: "node",
          include: ["test/platform/**/*.test.ts"],
        },
      },
    ],
  },
});
