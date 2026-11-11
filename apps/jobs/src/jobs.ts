import { fileURLToPath } from "node:url";
import {
  adminCredentials,
  ConfigError,
  describeError,
  type Logger,
  loadConfig,
  NotBootstrappedError,
  ROLES,
  type RoleName,
  roleCredentials,
  runBootstrap,
  runMigrations,
} from "@memoire/core";
import { runVerify } from "./verify.js";

// Depuis src comme depuis dist, le répertoire db est trois niveaux plus haut.
const BOOTSTRAP_DIRECTORY = fileURLToPath(new URL("../../../db/bootstrap", import.meta.url));
const MIGRATIONS_DIRECTORY = fileURLToPath(new URL("../../../db/migrations", import.meta.url));

export const EXIT_OK = 0;
export const EXIT_FAILED = 1;
export const EXIT_INVALID_CONFIGURATION = 2;
/** deploy.sh reconnaît ce code de « migrate » et demande d'amorcer la base. */
export const EXIT_NOT_BOOTSTRAPPED = 3;

export interface JobContext {
  env: NodeJS.ProcessEnv;
  logger: Logger;
  /** Écrit le résultat du job sur la sortie standard. */
  print: (text: string) => void;
}

/** Chaque job renvoie vrai quand il a réussi. */
const JOBS = {
  async migrate({ env, logger }: JobContext): Promise<boolean> {
    const applied = await runMigrations({
      database: loadConfig(env).database,
      credentials: roleCredentials(env, "migrator"),
      directory: MIGRATIONS_DIRECTORY,
      logger,
    });
    logger.info("migrations.completed", { applied });
    return true;
  },

  async "db-bootstrap"({ env, logger }: JobContext): Promise<boolean> {
    const passwords = ROLES.map((role) => [role, roleCredentials(env, role).password]);
    const files = await runBootstrap({
      database: loadConfig(env).database,
      admin: adminCredentials(env),
      rolePasswords: Object.fromEntries(passwords) as Record<RoleName, string>,
      directory: BOOTSTRAP_DIRECTORY,
      logger,
    });
    logger.info("bootstrap.completed", { files });
    return true;
  },

  async verify({ env, logger, print }: JobContext): Promise<boolean> {
    const report = await runVerify({ config: loadConfig(env), env, logger });
    print(`${JSON.stringify(report, null, 2)}\n`);
    return report.status === "ok";
  },
};

export type JobName = keyof typeof JOBS;

export const JOB_NAMES = Object.keys(JOBS) as JobName[];

/** Lance un job et renvoie le code de sortie du processus. */
export async function runJob(name: JobName, context: JobContext): Promise<number> {
  const { logger } = context;
  try {
    if (await JOBS[name](context)) {
      logger.info("job.succeeded", { job: name });
      return EXIT_OK;
    }
    logger.error("job.failed", { job: name });
    return EXIT_FAILED;
  } catch (error) {
    logger.error("job.failed", { job: name, error: describeError(error) });
    if (error instanceof ConfigError) {
      return EXIT_INVALID_CONFIGURATION;
    }
    return error instanceof NotBootstrappedError ? EXIT_NOT_BOOTSTRAPPED : EXIT_FAILED;
  }
}
