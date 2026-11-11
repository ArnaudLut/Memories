import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { type Credentials, type DatabaseConfig, ROLES, type RoleName } from "./config.js";
import { connect } from "./database.js";
import type { Logger } from "./logger.js";
import { scramSha256Verifier } from "./scram.js";

export interface BootstrapOptions {
  database: DatabaseConfig;
  /** Identifiants du compte d'administration de la base. */
  admin: Credentials;
  rolePasswords: Readonly<Record<RoleName, string>>;
  directory: string;
  logger: Logger;
}

/**
 * Joue les fichiers d'amorçage dans l'ordre de leur nom, chacun dans sa
 * transaction, au cours d'une seule session du compte d'administration. Renvoie
 * les fichiers joués.
 */
export async function runBootstrap(options: BootstrapOptions): Promise<string[]> {
  const { database, admin, rolePasswords, directory, logger } = options;
  const files = (await readdir(directory)).filter((name) => name.endsWith(".sql")).sort();
  if (files.length === 0) {
    throw new Error(`Aucun fichier d'amorçage dans ${directory}.`);
  }

  const client = await connect(database, admin);
  // PostgreSQL répond par un avertissement, et non par une erreur, quand un
  // droit manque au compte d'administration : ces messages sont à lire.
  client.on("notice", (notice) => {
    if (notice.severity !== "NOTICE") {
      logger.warn("bootstrap.server_message", {
        severity: notice.severity,
        message: notice.message,
      });
    }
  });
  try {
    // Les fichiers SQL lisent chaque mot de passe dans un paramètre de session.
    // Il n'y arrive que sous forme de vérificateur : le mot de passe en clair ne
    // quitte pas ce processus et ne peut donc figurer dans aucun journal du
    // serveur.
    for (const role of ROLES) {
      await client.query("select set_config($1, $2, false)", [
        `memoire_bootstrap.password_${role}`,
        scramSha256Verifier(rolePasswords[role]),
      ]);
    }
    for (const file of files) {
      const sql = await readFile(join(directory, file), "utf8");
      await client.query("begin");
      try {
        await client.query(sql);
        await client.query("commit");
      } catch (error) {
        await client.query("rollback").catch(() => {});
        const reason = error instanceof Error ? error.message : String(error);
        throw new Error(`Le fichier d'amorçage ${file} a échoué : ${reason}`, { cause: error });
      }
      logger.info("bootstrap.file_applied", { file });
    }
    return files;
  } finally {
    await client.end();
  }
}
