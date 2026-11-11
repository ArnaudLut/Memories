import { randomUUID } from "node:crypto";
import {
  adminUser,
  type Client,
  type Config,
  connect,
  createPool,
  type DatabaseConfig,
  type Logger,
  type Pool,
  ROLES,
  roleCredentials,
  withTenant,
} from "@memoire/core";
import { dumpWitness } from "./pg-dump.js";

type Status = "ok" | "failed";

/** Résultat d'un contrôle : son verdict, une phrase qui le résume, ses mesures. */
export interface Check {
  status: Status;
  detail: string;
  [measure: string]: unknown;
}

export interface VerifyReport {
  status: Status;
  env: string;
  version: string;
  postgresql: string | null;
  checks: { roles: Check; pgvector: Check; rls: Check; queue: Check };
}

function verdict(problems: string[], success: string, measures: Record<string, unknown>): Check {
  return problems.length === 0
    ? { status: "ok", detail: success, ...measures }
    : { status: "failed", detail: `Anomalies : ${problems.join(" ; ")}.`, ...measures };
}

async function attempt(check: () => Promise<Check>): Promise<Check> {
  try {
    return await check();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return { status: "failed", detail: `Le contrôle n'a pas pu aller à son terme : ${reason}` };
  }
}

async function count(client: Client | Pool, sql: string): Promise<number> {
  const { rows } = await client.query<{ n: number }>(sql);
  return rows[0]?.n ?? -1;
}

/** (a) Aucun des cinq rôles n'est superutilisateur ni ne contourne la RLS. */
export async function checkRoles(client: Client, admin: string): Promise<Check> {
  const { rows: roles } = await client.query<{
    name: string;
    superuser: boolean;
    bypassrls: boolean;
  }>(`
    select rolname as name, rolsuper as superuser, rolbypassrls as bypassrls,
           rolcreaterole as createrole, rolcreatedb as createdb,
           rolreplication as replication, rolconnlimit as "connectionLimit"
    from pg_catalog.pg_roles
    where rolcanlogin
    order by rolname`);
  const problems: string[] = [];
  for (const name of ROLES) {
    const role = roles.find((candidate) => candidate.name === name);
    if (role === undefined) {
      problems.push(`le rôle ${name} est absent`);
    } else if (role.superuser || role.bypassrls) {
      problems.push(`le rôle ${name} a l'attribut SUPERUSER ou BYPASSRLS`);
    }
  }
  return verdict(
    problems,
    "Les cinq rôles de l'application existent, sans SUPERUSER ni BYPASSRLS.",
    {
      admin: roles.find((role) => role.name === admin) ?? null,
      roles,
    },
  );
}

/** (b) pgvector est installé et sait indexer la dimension des embeddings. */
async function checkPgvector(client: Client): Promise<Check> {
  const { rows } = await client.query<{ version: string }>(
    "select extversion as version from pg_catalog.pg_extension where extname = 'vector'",
  );
  const version = rows[0]?.version ?? null;
  if (version === null) {
    return { status: "failed", detail: "L'extension vector n'est pas installée.", version };
  }
  await client.query("begin");
  try {
    await client.query("create table meta.verify_hnsw (embedding public.vector(1024))");
    await client.query(
      "create index on meta.verify_hnsw using hnsw (embedding public.vector_cosine_ops)",
    );
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return { status: "failed", detail: `L'index HNSW n'a pas pu être créé : ${reason}`, version };
  } finally {
    await client.query("rollback");
  }
  return {
    status: "ok",
    detail: `pgvector ${version} est installé et un index HNSW se crée sur une colonne vector(1024).`,
    version,
  };
}

/** (c) La RLS forcée isole les tenants, et la sauvegarde lit pourtant tout. */
async function checkRls(
  app: Pool,
  owner: Client,
  database: DatabaseConfig,
  env: NodeJS.ProcessEnv,
): Promise<Check> {
  const run = randomUUID();
  const witnesses = [1, 2].map((rank) => ({ tenant: randomUUID(), note: `verify-${run}-${rank}` }));
  try {
    for (const { tenant, note } of witnesses) {
      await withTenant(app, tenant, (client) =>
        client.query("insert into app.rls_witness (tenant_id, note) values ($1, $2)", [
          tenant,
          note,
        ]),
      );
    }

    const problems: string[] = [];
    for (const { tenant, note } of witnesses) {
      const { rows } = await withTenant(app, tenant, (client) =>
        client.query<{ note: string }>("select note from app.rls_witness"),
      );
      if (rows.length !== 1 || rows[0]?.note !== note) {
        problems.push(`le tenant ${tenant} voit ${rows.length} ligne(s) au lieu de la sienne`);
      }
    }
    const rowsWithoutTenant = await count(app, "select count(*)::int as n from app.rls_witness");
    if (rowsWithoutTenant !== 0) {
      problems.push(`sans tenant, le rôle app voit ${rowsWithoutTenant} ligne(s)`);
    }
    const rowsSeenByOwner = await count(owner, "select count(*)::int as n from app.rls_witness");
    if (rowsSeenByOwner !== 0) {
      problems.push(`le propriétaire de la table voit ${rowsSeenByOwner} ligne(s)`);
    }

    const backup = roleCredentials(env, "backup");
    const dump = await dumpWitness(database, backup, { rowSecurity: true });
    const dumpContainsBothRows =
      dump.exitCode === 0 && witnesses.every(({ note }) => dump.stdout.includes(note));
    if (!dumpContainsBothRows) {
      problems.push(
        `pg_dump --enable-row-security ne contient pas les deux lignes (code ${dump.exitCode} : ${dump.stderr.trim()})`,
      );
    }
    const refused = await dumpWitness(database, backup, { rowSecurity: false });
    // Le refus attendu nomme la table. Un autre échec, une connexion perdue
    // par exemple, ne prouve rien.
    const dumpWithoutRowSecurityRefused =
      refused.exitCode !== 0 && refused.stderr.includes("rls_witness");
    if (refused.exitCode === 0) {
      problems.push("pg_dump réussit sans --enable-row-security");
    } else if (!dumpWithoutRowSecurityRefused) {
      problems.push(
        `pg_dump sans --enable-row-security a échoué pour une autre raison que la RLS (code ${refused.exitCode} : ${refused.stderr.trim()})`,
      );
    }

    return verdict(
      problems,
      "Chaque tenant ne voit que sa ligne, le propriétaire de la table n'en voit aucune, et pg_dump sous le rôle backup lit les deux lignes avec --enable-row-security puis échoue sans cette option.",
      {
        rowsWithoutTenant,
        rowsSeenByOwner,
        dumpContainsBothRows,
        dumpWithoutRowSecurityRefused,
        // Premier message de pg_dump : il doit nommer la politique de sécurité.
        dumpRefusal: refused.stderr.trim().split("\n", 1)[0] ?? "",
      },
    );
  } finally {
    for (const { tenant } of witnesses) {
      await withTenant(app, tenant, (client) => client.query("delete from app.rls_witness"));
    }
  }
}

/** (d) Le schéma de la file existe et appartient au rôle du worker. */
export async function checkQueue(client: Client): Promise<Check> {
  const { rows } = await client.query<{ owner: string }>(
    "select pg_catalog.pg_get_userbyid(nspowner) as owner from pg_catalog.pg_namespace where nspname = 'pgboss'",
  );
  const owner = rows[0]?.owner ?? null;
  const problems =
    owner === "queue"
      ? []
      : [owner === null ? "le schéma pgboss est absent" : `le schéma pgboss appartient à ${owner}`];
  return verdict(problems, "Le schéma pgboss appartient au rôle queue.", {
    schema: "pgboss",
    owner,
  });
}

/**
 * Contrôles de l'étape 1 sur une base réelle. Le rapport est complet même quand
 * un contrôle échoue : chacun est indépendant des autres.
 */
export async function runVerify(options: {
  config: Config;
  env: NodeJS.ProcessEnv;
  logger: Logger;
}): Promise<VerifyReport> {
  const { config, env, logger } = options;
  const migrator = await connect(config.database, roleCredentials(env, "migrator"));
  const app = createPool(config.database, roleCredentials(env, "app"), { max: 1, logger });
  try {
    const { rows } = await migrator.query<{ version: string }>(
      "select current_setting('server_version') as version",
    );
    const checks = {
      roles: await attempt(() => checkRoles(migrator, adminUser(env))),
      pgvector: await attempt(() => checkPgvector(migrator)),
      rls: await attempt(() => checkRls(app, migrator, config.database, env)),
      queue: await attempt(() => checkQueue(migrator)),
    };
    const failed = Object.values(checks).some((check) => check.status === "failed");
    return {
      status: failed ? "failed" : "ok",
      env: config.appEnv,
      version: config.version,
      postgresql: rows[0]?.version ?? null,
      checks,
    };
  } finally {
    await app.end();
    await migrator.end();
  }
}
