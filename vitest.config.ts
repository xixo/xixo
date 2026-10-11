import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/client/**/*.test.{ts,tsx}'],
    environment: 'happy-dom',
    setupFiles: ['test/client/support/setup.ts'],
  },
})
