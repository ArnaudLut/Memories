import {
  type Credentials,
  connectionOptions,
  type DatabaseConfig,
  describeError,
  type Logger,
} from "@memoire/core";
import { PgBoss } from "pg-boss";
import { clearAlive, LIVENESS_INTERVAL_MS, markAlive } from "./liveness.js";

export const QUEUE_SCHEMA = "pgboss";
export const HEARTBEAT_QUEUE = "system-heartbeat";
const HEARTBEAT_CRON = "*/5 * * * *";
// La limite de connexions du rôle queue laisse deux instances cohabiter.
const POOL_SIZE = 5;
// Docker accorde dix secondes à un conteneur pour s'arrêter.
const STOP_TIMEOUT_MS = 5000;

export interface Worker {
  /** Instance pg-boss du worker, pour les tests. */
  boss: PgBoss;
  stop(): Promise<void>;
}

export interface WorkerOptions {
  database: DatabaseConfig;
  /** Identifiants du rôle queue. */
  credentials: Credentials;
  logger: Logger;
  livenessFile: string;
}

export async function startWorker(options: WorkerOptions): Promise<Worker> {
  const { database, credentials, logger, livenessFile } = options;
  const boss = new PgBoss({
    ...connectionOptions(database, credentials),
    schema: QUEUE_SCHEMA,
    // Le schéma est créé par l'amorçage et appartient au rôle queue, qui n'a
    // pas le droit d'en créer : pg-boss n'y installe que ses tables.
    createSchema: false,
    max: POOL_SIZE,
  });
  // pg-boss signale par cet événement les erreurs de ses tâches de fond, par
  // exemple une base injoignable. Sans écouteur, elles arrêteraient le processus.
  boss.on("error", (error) => logger.error("queue.error", { error: describeError(error) }));
  boss.on("warning", (warning) => logger.warn("queue.warning", { ...warning }));

  let stopped = false;
  let timer: NodeJS.Timeout | undefined;
  // Le signe de vie n'est donné qu'après une requête réussie : un worker coupé
  // de sa base cesse d'être sain. Chaque contrôle programme le suivant, pour
  // que des requêtes sans réponse ne s'accumulent pas.
  const beat = async (): Promise<void> => {
    try {
      await boss.getDb().executeSql("select 1");
      await markAlive(livenessFile);
    } catch (error) {
      logger.warn("worker.liveness_check_failed", { error: describeError(error) });
    }
    if (!stopped) {
      timer = setTimeout(beat, LIVENESS_INTERVAL_MS);
    }
  };

  try {
    await boss.start();
    await boss.createQueue(HEARTBEAT_QUEUE);
    await boss.schedule(HEARTBEAT_QUEUE, HEARTBEAT_CRON);
    await boss.work(HEARTBEAT_QUEUE, async (jobs) => {
      for (const job of jobs) {
        logger.info("heartbeat.handled", { jobId: job.id });
      }
    });
    await beat();
  } catch (error) {
    stopped = true;
    clearTimeout(timer);
    await boss.stop({ graceful: false }).catch(() => {});
    throw error;
  }
  logger.info("worker.started", { queue: HEARTBEAT_QUEUE, schedule: HEARTBEAT_CRON });

  return {
    boss,
    async stop() {
      stopped = true;
      clearTimeout(timer);
      await boss.stop({ timeout: STOP_TIMEOUT_MS });
      await clearAlive(livenessFile);
    },
  };
}
