import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts", "../tests/parity/run_parity.ts"],
  },
});
