import { readFileSync } from "node:fs";

/** Rôles SQL de l'application, créés par db/bootstrap/10_roles.sql. */
export const ROLES = ["app", "auth", "queue", "backup", "migrator"] as const;
export type RoleName = (typeof ROLES)[number];

const APP_ENVS = ["preview", "production", "development", "test"] as const;
export type AppEnv = (typeof APP_ENVS)[number];

/** Nom du compte d'administration d'un PostgreSQL managé par OVHcloud. */
const DEFAULT_ADMIN_USER = "avnadmin";

export interface DatabaseConfig {
  host: string;
  port: number;
  name: string;
  /** Absent quand PGSSLMODE vaut « disable ». */
  tls?: { rootCertPath: string; ca: string };
}

export interface Config {
  appEnv: AppEnv;
  version: string;
  database: DatabaseConfig;
}

export interface Credentials {
  user: string;
  password: string;
}

/** Erreur de configuration : son message s'adresse à la personne qui déploie. */
export class ConfigError extends Error {
  override name = "ConfigError";
}

function requireVariable(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value === "") {
    throw new ConfigError(`La variable d'environnement ${name} est absente.`);
  }
  return value;
}

/** Lit un numéro de port. Sans valeur de repli, la variable est obligatoire. */
export function readPort(env: NodeJS.ProcessEnv, name: string, fallback?: number): number {
  if (fallback !== undefined && (env[name] === undefined || env[name] === "")) {
    return fallback;
  }
  const value = requireVariable(env, name);
  const port = Number(value);
  if (!/^\d+$/.test(value) || port < 1 || port > 65535) {
    throw new ConfigError(
      `La variable ${name} vaut « ${value} », qui n'est pas un numéro de port.`,
    );
  }
  return port;
}

function loadDatabaseConfig(env: NodeJS.ProcessEnv): DatabaseConfig {
  const database = {
    host: requireVariable(env, "PGHOST"),
    port: readPort(env, "PGPORT"),
    name: requireVariable(env, "PGDATABASE"),
  };
  // Seuls deux modes sont admis : tout vérifier, ou ne pas chiffrer (base locale
  // et CI). Les modes intermédiaires de libpq chiffrent sans authentifier le
  // serveur.
  const sslMode = requireVariable(env, "PGSSLMODE");
  if (sslMode === "disable") {
    return database;
  }
  if (sslMode !== "verify-full") {
    throw new ConfigError(
      `La variable PGSSLMODE vaut « ${sslMode} » : seules les valeurs verify-full et disable sont admises.`,
    );
  }
  const rootCertPath = requireVariable(env, "PGSSLROOTCERT");
  let ca: string;
  try {
    ca = readFileSync(rootCertPath, "utf8");
  } catch (cause) {
    throw new ConfigError(`Le certificat ${rootCertPath} (PGSSLROOTCERT) est illisible.`, {
      cause,
    });
  }
  return { ...database, tls: { rootCertPath, ca } };
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const value = requireVariable(env, "APP_ENV");
  const appEnv = APP_ENVS.find((known) => known === value);
  if (appEnv === undefined) {
    throw new ConfigError(
      `La variable APP_ENV vaut « ${value} » : les valeurs admises sont ${APP_ENVS.join(", ")}.`,
    );
  }
  return {
    appEnv,
    version: requireVariable(env, "APP_VERSION"),
    database: loadDatabaseConfig(env),
  };
}

/** Chaque processus ne lit que le mot de passe des rôles dont il se sert. */
export function roleCredentials(env: NodeJS.ProcessEnv, role: RoleName): Credentials {
  return { user: role, password: requireVariable(env, `DB_${role.toUpperCase()}_PASSWORD`) };
}

export function adminUser(env: NodeJS.ProcessEnv): string {
  return env.DB_ADMIN_USER || DEFAULT_ADMIN_USER;
}

export function adminCredentials(env: NodeJS.ProcessEnv): Credentials {
  return { user: adminUser(env), password: requireVariable(env, "DB_ADMIN_PASSWORD") };
}
