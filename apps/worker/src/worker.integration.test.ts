import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  createTestDatabase,
  memoryLogger,
  type TestDatabase,
} from "../../../packages/core/src/testing.js";
import { isAlive } from "./liveness.js";
import { HEARTBEAT_QUEUE, startWorker, type Worker } from "./worker.js";

let db: TestDatabase;
let directory: string;
let livenessFile: string;
let worker: Worker | undefined;
const logger = memoryLogger();

function start(): Promise<Worker> {
  return startWorker({
    database: db.config.database,
    credentials: db.credentials("queue"),
    logger,
    livenessFile,
  });
}

beforeAll(async () => {
  db = await createTestDatabase("worker", "bootstrapped");
  directory = mkdtempSync(join(tmpdir(), "memoire-worker-"));
  livenessFile = join(directory, "worker.alive");
});

afterAll(async () => {
  await worker?.stop();
  await db.drop();
  rmSync(directory, { recursive: true });
});

describe("worker sous le rôle queue", () => {
  it("installe pg-boss dans le schéma pgboss, sans autre droit que sa propriété", async () => {
    worker = await start();
    const owners = await db.query<{ owner: string }>(
      "queue",
      `select distinct pg_catalog.pg_get_userbyid(relowner) as owner
       from pg_catalog.pg_class where relnamespace = 'pgboss'::regnamespace`,
    );
    expect(owners).toEqual([{ owner: "queue" }]);
    expect(await worker.boss.isInstalled()).toBe(true);
  });

  it("déclare la file system-heartbeat et sa planification toutes les cinq minutes", async () => {
    expect(await worker?.boss.getQueue(HEARTBEAT_QUEUE)).toMatchObject({
      name: "system-heartbeat",
    });
    expect(await worker?.boss.getSchedules(HEARTBEAT_QUEUE)).toMatchObject([
      { name: "system-heartbeat", cron: "*/5 * * * *" },
    ]);
  });

  it("donne signe de vie une fois démarré", async () => {
    expect(await isAlive(livenessFile)).toBe(true);
    expect(logger.entries.map((entry) => entry.event)).toEqual(["worker.started"]);
  });

  it("traite un battement en le journalisant", async () => {
    const jobId = await worker?.boss.send(HEARTBEAT_QUEUE);
    expect(jobId).toEqual(expect.any(String));
    await vi.waitFor(
      () => {
        expect(logger.entries).toContainEqual({
          level: "info",
          event: "heartbeat.handled",
          context: { jobId },
        });
      },
      { timeout: 15_000, interval: 100 },
    );
  });

  it("journalise une erreur de fond de pg-boss au lieu de s'arrêter", () => {
    expect(() => worker?.boss.emit("error", new Error("base injoignable"))).not.toThrow();
    expect(logger.entries).toContainEqual({
      level: "error",
      event: "queue.error",
      context: { error: { name: "Error", message: "base injoignable" } },
    });
  });

  it("ne donne plus signe de vie quand la base ne répond plus", async () => {
    const lastSign = statSync(livenessFile).mtimeMs;
    const queueDb = worker?.boss.getDb();
    if (queueDb === undefined) {
      throw new Error("le worker n'a pas démarré");
    }
    const cut = vi.spyOn(queueDb, "executeSql").mockRejectedValue(new Error("base coupée"));
    try {
      // Le contrôle suivant arrive dans les dix secondes.
      await vi.waitFor(
        () => {
          expect(logger.entries.map((entry) => entry.event)).toContain(
            "worker.liveness_check_failed",
          );
        },
        { timeout: 15_000, interval: 100 },
      );
      expect(statSync(livenessFile).mtimeMs).toBe(lastSign);
    } finally {
      cut.mockRestore();
    }
  });

  it("s'arrête proprement, puis redémarre sur le schéma déjà installé", async () => {
    await worker?.stop();
    expect(await isAlive(livenessFile)).toBe(false);

    worker = await start();
    expect(await isAlive(livenessFile)).toBe(true);
    expect(await worker.boss.getSchedules(HEARTBEAT_QUEUE)).toHaveLength(1);
  });

  it("refuse de démarrer sous un rôle qui ne possède pas le schéma", async () => {
    const intruder = startWorker({
      database: db.config.database,
      credentials: db.credentials("auth"),
      logger: memoryLogger(),
      livenessFile: join(directory, "intruder.alive"),
    });
    await expect(intruder).rejects.toThrow(/permission denied/);
  });
});
