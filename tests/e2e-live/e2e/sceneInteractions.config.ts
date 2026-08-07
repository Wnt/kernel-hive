import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'sceneInteractions.spec.ts',
  fullyParallel: false,
  workers: 1,
  timeout: 90_000,
  retries: 0,
  expect: { timeout: 30_000 },
  reporter: [['list']],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: process.env.GALLERY_URL || 'http://127.0.0.1:5238',
    headless: true,
    viewport: { width: 1440, height: 900 },
    actionTimeout: 12_000,
    launchOptions: {
      channel: 'chrome',
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader'],
    },
  },
});
