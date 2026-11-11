// Outils des tests d'intégration. Ce fichier ne fait pas partie du paquet
// compilé : les tests des applications l'importent par son chemin.

import { fileURLToPath } from "node:url";
import { runBootstrap } from "./bootstrap.js";
import {
  adminCredentials,
  type Config,
  type Credentials,
  loadConfig,
  ROLES,
  type RoleName,
  roleCredentials,
} from "./config.js";
import { connect } from "./database.js";
import type { LogContext, Logger } from "./logger.js";
import { runMigrations } from "./migrations.js";

export const BOOTSTRAP_DIRECTORY = fileURLToPath(new URL("../../../db/bootstrap", import.meta.url));
export const MIGRATIONS_DIRECTORY = fileURLToPath(
  new URL("../../../db/migrations", import.meta.url),
);

// Valeurs de la base locale (dev/compose.yaml et .env.example). L'environnement
// peut les remplacer, par exemple quand la base écoute sur un autre port.
const LOCAL_DEFAULTS = {
  PGHOST: "127.0.0.1",
  PGPORT: "5432",
  DB_ADMIN_USER: "avnadmin",
  DB_ADMIN_PASSWORD: "avnadmin",
  DB_APP_PASSWORD: "app-local",
  DB_AUTH_PASSWORD: "auth-local",
  DB_QUEUE_PASSWORD: "queue-local",
  DB_BACKUP_PASSWORD: "backup-local",
  DB_MIGRATOR_PASSWORD: "migrator-local",
};

export interface LogEntry {
  level: "info" | "warn" | "error";
  event: string;
  context: LogContext;
}

/** Journal qui garde ses entrées en mémoire, pour que les tests les lisent. */
export function memoryLogger(): Logger & { entries: LogEntry[] } {
  const entries: LogEntry[] = [];
  const log =
    (level: LogEntry["level"]) =>
    (event: string, context: LogContext = {}) => {
      entries.push({ level, event, context });
    };
  return { entries, info: log("info"), warn: log("warn"), error: log("error") };
}

export interface TestDatabase {
  env: NodeJS.ProcessEnv;
  config: Config;
  credentials(role: RoleName | "admin"): Credentials;
  /** Exécute une requête sous un rôle, dans une session ouverte pour elle. */
  query<Row extends object>(
    role: RoleName | "admin",
    sql: string,
    values?: unknown[],
  ): Promise<Row[]>;
  bootstrap(): Promise<string[]>;
  migrate(directory?: string): Promise<string[]>;
  drop(): Promise<void>;
}

/**
 * Crée une base de test vide, amorcée ou migrée, après avoir supprimé celle du
 * même nom. Les rôles SQL, eux, sont communs à toutes les bases du serveur :
 * l'amorçage leur redonne les mots de passe de l'environnement de test.
 */
export async function createTestDatabase(
  suffix: string,
  state: "empty" | "bootstrapped" | "migrated",
): Promise<TestDatabase> {
  if (!/^[a-z_]+$/.test(suffix)) {
    throw new Error("Le suffixe d'une base de test se compose de minuscules et de tirets bas.");
  }
  const name = `memoire_test_${suffix}`;
  const env: NodeJS.ProcessEnv = {
    APP_ENV: "test",
    APP_VERSION: "test",
    PGDATABASE: name,
    // Une base de test n'est jamais chiffrée : ces tests, qui suppriment des
    // bases et changent des mots de passe, ne peuvent donc pas atteindre un
    // PostgreSQL managé, où TLS est obligatoire.
    PGSSLMODE: "disable",
  };
  for (const [variable, fallback] of Object.entries(LOCAL_DEFAULTS)) {
    env[variable] = process.env[variable] || fallback;
  }
  const config = loadConfig(env);
  const credentials = (role: RoleName | "admin") =>
    role === "admin" ? adminCredentials(env) : roleCredentials(env, role);

  const asAdmin = async (sql: string): Promise<void> => {
    const client = await connect({ ...config.database, name: "postgres" }, credentials("admin"));
    try {
      await client.query(sql);
    } finally {
      await client.end();
    }
  };
  const drop = () => asAdmin(`drop database if exists ${name}`);

  const database: TestDatabase = {
    env,
    config,
    credentials,
    drop,
    async query<Row extends object>(role: RoleName | "admin", sql: string, values?: unknown[]) {
      const client = await connect(config.database, credentials(role));
      try {
        return (await client.query<Row>(sql, values)).rows;
      } finally {
        await client.end();
      }
    },
    bootstrap() {
      const passwords = ROLES.map((role) => [role, credentials(role).password]);
      return runBootstrap({
        database: config.database,
        admin: credentials("admin"),
        rolePasswords: Object.fromEntries(passwords) as Record<RoleName, string>,
        directory: BOOTSTRAP_DIRECTORY,
        logger: memoryLogger(),
      });
    },
    migrate(directory = MIGRATIONS_DIRECTORY) {
      return runMigrations({
        database: config.database,
        credentials: credentials("migrator"),
        directory,
        logger: memoryLogger(),
      });
    },
  };

  await drop();
  await asAdmin(`create database ${name}`);
  if (state !== "empty") {
    await database.bootstrap();
  }
  if (state === "migrated") {
    await database.migrate();
  }
  return database;
}
