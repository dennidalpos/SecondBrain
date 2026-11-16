// Visual UI/UX audit (plan item G01): screenshots of the real binary on the synthetic fixture. Not part of the regular e2e suite.
// Run: SB_E2E_FIXTURE=<fixture.json> SB_AUDIT_OUT=<folder> npx --no-install playwright test -c e2e/playwright.audit.config.ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: /.*\.audit\.ts/,
  timeout: 300_000,
  expect: { timeout: 30_000 },
  workers: 1,
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  outputDir: process.env.SB_E2E_OUTPUT ?? "test-results",
});
