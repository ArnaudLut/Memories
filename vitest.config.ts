import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      // Les tests lisent les sources de @memoire/core : aucune compilation
      // préalable n'est nécessaire.
      "@memoire/core": fileURLToPath(new URL("./packages/core/src/index.ts", import.meta.url)),
    },
  },
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: "unit",
          include: ["{packages,apps}/*/src/**/*.test.ts"],
          exclude: ["**/*.integration.test.ts"],
        },
      },
      {
        // Tests sur un vrai PostgreSQL 17 : celui de dev/compose.yaml.
        extends: true,
        test: {
          name: "integration",
          include: ["{packages,apps}/*/src/**/*.integration.test.ts"],
          // Les rôles SQL sont communs à toutes les bases du serveur : deux
          // fichiers qui jouent l'amorçage ne doivent pas se croiser.
          fileParallelism: false,
          testTimeout: 30_000,
          hookTimeout: 60_000,
        },
      },
    ],
  },
});
