import type { AddressInfo } from "node:net";
import { connect, createPool, type Pool, readMigrationFiles } from "@memoire/core";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createTestDatabase,
  MIGRATIONS_DIRECTORY,
  memoryLogger,
  type TestDatabase,
} from "../../../packages/core/src/testing.js";
import { createHealthServer } from "./server.js";

let db: TestDatabase;
const pools: Pool[] = [];
const stops: (() => Promise<void>)[] = [];

/** Démarre le service sous le rôle app et renvoie la réponse de /health. */
async function health(database: TestDatabase["config"]["database"]): Promise<Response> {
  const logger = memoryLogger();
  const pool = createPool(database, db.credentials("app"), { max: 2, logger });
  pools.push(pool);
  const server = createHealthServer({ pool, config: db.config, logger });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  stops.push(() => new Promise((resolve) => server.close(() => resolve())));
  const { port } = server.address() as AddressInfo;
  return fetch(`http://127.0.0.1:${port}/health`);
}

beforeAll(async () => {
  db = await createTestDatabase("server", "migrated");
});

afterAll(async () => {
  for (const stop of stops) {
    await stop();
  }
  for (const pool of pools) {
    await pool.end();
  }
  await db.drop();
});

describe("GET /health sur une vraie base", () => {
  it("annonce la dernière migration appliquée", async () => {
    const latest = (await readMigrationFiles(MIGRATIONS_DIRECTORY)).at(-1)?.version;
    const response = await health(db.config.database);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "ok",
      version: "test",
      env: "test",
      checks: { database: "ok", migrations: latest },
    });
  });

  it("répond 503 quand la base est injoignable", async () => {
    // Le port 1 n'est pas écouté : la connexion est refusée.
    const response = await health({ ...db.config.database, port: 1 });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      status: "degraded",
      version: "test",
      env: "test",
      checks: { database: "error", migrations: null },
    });
  });

  it("répond 503 sans attendre une base qui ne répond plus", async () => {
    // Un verrou exclusif sur le journal fait attendre la requête de /health,
    // comme une base qui a accepté la connexion puis se tait.
    const blocker = await connect(db.config.database, db.credentials("migrator"));
    try {
      await blocker.query("begin");
      await blocker.query("lock table meta.schema_migrations in access exclusive mode");
      const startedAt = performance.now();
      const response = await health(db.config.database);
      // Le contrôle de santé de Docker abandonne au bout de cinq secondes.
      expect(performance.now() - startedAt).toBeLessThan(5000);
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({ status: "degraded" });
    } finally {
      // La session que /health a abandonnée attend encore le verrou : elle est
      // fermée ici, pour que la base de test puisse être supprimée.
      await db.query(
        "app",
        `select pg_terminate_backend(pid, 5000) from pg_stat_activity
         where usename = current_user and datname = current_database()
           and pid <> pg_backend_pid()`,
      );
      await blocker.query("rollback");
      await blocker.end();
    }
  });

  it("répond 503 quand les migrations n'ont pas été appliquées", async () => {
    const unmigrated = await createTestDatabase("server_unmigrated", "bootstrapped");
    try {
      const response = await health(unmigrated.config.database);
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({ status: "degraded" });
    } finally {
      await pools.at(-1)?.end();
      pools.pop();
      await unmigrated.drop();
    }
  });
});
