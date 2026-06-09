import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.GHOSTD_TEST_PORT ?? "51234");

export default defineConfig({
  testDir: "./tests",
  outputDir: "./test-results/playwright",
  timeout: 30_000,
  workers: 1,
  expect: {
    timeout: 5_000,
  },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
    video: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: `pnpm build && PORT=${port} HOST=127.0.0.1 pnpm native:run`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
