import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Client } from "pg";
import type { Credentials, DatabaseConfig } from "./config.js";
import { connect } from "./database.js";
import type { Logger } from "./logger.js";

export interface MigrationFile {
  version: string;
  name: string;
  checksum: string;
  sql: string;
}

export interface AppliedMigration {
  version: string;
  checksum: string;
}

/** Les migrations ne peuvent pas s'appliquer : la base attend son amorçage. */
export class NotBootstrappedError extends Error {
  override name = "NotBootstrappedError";
}

const FILE_PATTERN = /^(\d{4})_([a-z0-9]+(?:_[a-z0-9]+)*)\.sql$/;

// Identifiant arbitraire du verrou des migrations : « memo » en ASCII.
const ADVISORY_LOCK_KEY = 0x6d656d6f;

// Mot de passe refusé ou rôle inconnu, puis rôle sans droit de connexion.
const AUTHENTICATION_FAILURES = new Set(["28P01", "28000"]);
const UNDEFINED_SCHEMA = "3F000";

function sqlState(error: unknown): string | undefined {
  return error instanceof Error && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined;
}

/** Lit les migrations d'un répertoire, dans l'ordre de leur numéro. */
export async function readMigrationFiles(directory: string): Promise<MigrationFile[]> {
  const files: MigrationFile[] = [];
  for (const entry of (await readdir(directory)).sort()) {
    const [, version, name] = FILE_PATTERN.exec(entry) ?? [];
    if (version === undefined || name === undefined) {
      throw new Error(`Le fichier ${entry} ne suit pas la forme NNNN_nom_en_minuscules.sql.`);
    }
    if (files.at(-1)?.version === version) {
      throw new Error(`Deux migrations portent le numéro ${version}.`);
    }
    const content = await readFile(join(directory, entry));
    files.push({
      version,
      name,
      checksum: createHash("sha256").update(content).digest("hex"),
      sql: content.toString("utf8"),
    });
  }
  return files;
}

/**
 * Migrations qui restent à appliquer, dans l'ordre. Un journal qui contredit
 * les fichiers est refusé. Une version du journal sans fichier est admise :
 * c'est l'état normal d'une image plus ancienne que la base, après un retour
 * arrière.
 */
export function pendingMigrations(
  files: readonly MigrationFile[],
  applied: readonly AppliedMigration[],
): MigrationFile[] {
  const checksums = new Map(applied.map((migration) => [migration.version, migration.checksum]));
  const latest = applied
    .map((migration) => migration.version)
    .sort()
    .at(-1);
  const pending: MigrationFile[] = [];
  for (const file of files) {
    const recorded = checksums.get(file.version);
    if (recorded === undefined) {
      if (latest !== undefined && file.version < latest) {
        throw new Error(
          `La migration ${file.version} n'est pas au journal alors que la ${latest}, plus récente, y figure.`,
        );
      }
      pending.push(file);
    } else if (recorded !== file.checksum) {
      throw new Error(
        `La migration ${file.version} a changé depuis son application : une migration appliquée ne se modifie pas, la correction passe par une nouvelle migration.`,
      );
    }
  }
  return pending;
}

async function transactionId(client: Client): Promise<string> {
  const { rows } = await client.query<{ id: string }>("select pg_current_xact_id()::text as id");
  return rows[0]?.id ?? "";
}

async function applyMigration(client: Client, file: MigrationFile): Promise<void> {
  await client.query("begin");
  try {
    const before = await transactionId(client);
    await client.query(file.sql);
    // Un COMMIT glissé dans le fichier laisserait la migration à moitié
    // appliquée en cas d'échec : il se voit au changement de transaction.
    if ((await transactionId(client)) !== before) {
      throw new Error(
        "le fichier a terminé sa transaction (BEGIN, COMMIT et ROLLBACK y sont interdits)",
      );
    }
    await client.query(
      "insert into meta.schema_migrations (version, name, checksum) values ($1, $2, $3)",
      [file.version, file.name, file.checksum],
    );
    await client.query("commit");
  } catch (error) {
    await client.query("rollback").catch(() => {});
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error(`La migration ${file.version}_${file.name} a échoué : ${reason}`, {
      cause: error,
    });
  }
}

export interface MigrationOptions {
  database: DatabaseConfig;
  /** Identifiants du rôle migrator. */
  credentials: Credentials;
  directory: string;
  logger: Logger;
}

/** Applique les migrations en attente et renvoie leurs numéros. */
export async function runMigrations(options: MigrationOptions): Promise<string[]> {
  const { database, credentials, directory, logger } = options;
  const files = await readMigrationFiles(directory);

  let client: Client;
  try {
    client = await connect(database, credentials);
  } catch (error) {
    if (AUTHENTICATION_FAILURES.has(sqlState(error) ?? "")) {
      throw new NotBootstrappedError(
        `Le rôle ${credentials.user} ne peut pas s'authentifier : la base n'est pas amorcée, ou son mot de passe a changé depuis l'amorçage.`,
        { cause: error },
      );
    }
    throw error;
  }

  try {
    // Verrou de session : deux déploiements simultanés appliquent les
    // migrations l'un après l'autre. La fin de la session le libère.
    await client.query("select pg_advisory_lock($1)", [ADVISORY_LOCK_KEY]);
    try {
      await client.query(`
        create table if not exists meta.schema_migrations (
          version text primary key,
          name text not null,
          checksum text not null,
          applied_at timestamptz not null default now()
        )`);
    } catch (error) {
      if (sqlState(error) === UNDEFINED_SCHEMA) {
        throw new NotBootstrappedError("Le schéma meta n'existe pas : la base n'est pas amorcée.", {
          cause: error,
        });
      }
      throw error;
    }

    const { rows: applied } = await client.query<AppliedMigration>(
      "select version, checksum from meta.schema_migrations",
    );
    const known = new Set(files.map((file) => file.version));
    const unknown = applied.map((migration) => migration.version).filter((v) => !known.has(v));
    if (unknown.length > 0) {
      logger.warn("migrations.database_ahead", { versions: unknown.sort() });
    }

    const pending = pendingMigrations(files, applied);
    for (const file of pending) {
      await applyMigration(client, file);
      logger.info("migrations.applied", { migration: `${file.version}_${file.name}` });
    }
    return pending.map((file) => file.version);
  } finally {
    await client.end();
  }
}
