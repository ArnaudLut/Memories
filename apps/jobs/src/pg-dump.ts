import { execFile } from "node:child_process";
import type { Credentials, DatabaseConfig } from "@memoire/core";

export interface DumpResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * Sauvegarde les données de la table témoin avec pg_dump. Sans l'option
 * --enable-row-security, pg_dump demande à lire la table hors de toute
 * politique et PostgreSQL le lui refuse, à moins que le rôle puisse contourner
 * la sécurité par ligne.
 */
export function dumpWitness(
  database: DatabaseConfig,
  credentials: Credentials,
  options: { rowSecurity: boolean },
): Promise<DumpResult> {
  const args = ["--data-only", "--table", "app.rls_witness"];
  if (options.rowSecurity) {
    args.unshift("--enable-row-security");
  }
  // pg_dump ne reçoit que ce dont il a besoin. Le mot de passe passe par
  // l'environnement, jamais par la ligne de commande.
  const env = {
    PATH: process.env.PATH,
    PGHOST: database.host,
    PGPORT: String(database.port),
    PGDATABASE: database.name,
    PGUSER: credentials.user,
    PGPASSWORD: credentials.password,
    PGSSLMODE: database.tls ? "verify-full" : "disable",
    PGSSLROOTCERT: database.tls?.rootCertPath,
    PGCONNECT_TIMEOUT: "10",
  };
  return new Promise((resolve, reject) => {
    execFile("pg_dump", args, { env, timeout: 60_000 }, (error, stdout, stderr) => {
      if (error === null) {
        resolve({ exitCode: 0, stdout, stderr });
      } else if (typeof error.code === "number") {
        resolve({ exitCode: error.code, stdout, stderr });
      } else {
        reject(new Error(`pg_dump n'a pas pu s'exécuter : ${error.message}`, { cause: error }));
      }
    });
  });
}
