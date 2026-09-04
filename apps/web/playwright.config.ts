import { defineConfig, devices } from "@playwright/test";

const port = 5173;
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: "./e2e",
  testIgnore: process.env.SCREENSHOTS === "1" ? [] : ["**/screenshots.spec.ts"],
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL,
    colorScheme: "light",
    trace: "on-first-retry",
  },
  webServer: {
    // Signed-in header only. Usage APIs still 401; the smoke fulfills /api/v6 on the page.
    command: `QUOTA_DEV_VIEWER=octocat vite dev --host 127.0.0.1 --port ${port} --strictPort`,
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
