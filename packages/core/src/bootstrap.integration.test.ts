import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { runBootstrap } from "./bootstrap.js";
import { ROLES, type RoleName } from "./config.js";
import { connect } from "./database.js";
import {
  BOOTSTRAP_DIRECTORY,
  createTestDatabase,
  memoryLogger,
  type TestDatabase,
} from "./testing.js";

const EXPECTED_SETTINGS: Record<RoleName, { limit: number; statementTimeout: string }> = {
  app: { limit: 20, statementTimeout: "15s" },
  auth: { limit: 10, statementTimeout: "5s" },
  queue: { limit: 10, statementTimeout: "60s" },
  backup: { limit: 3, statementTimeout: "60s" },
  migrator: { limit: 3, statementTimeout: "15min" },
};

let db: TestDatabase;
let afterFirstRun: unknown;

/** Tout ce que l'amorçage pose, hormis les mots de passe, illisibles ici. */
async function snapshot(): Promise<unknown> {
  const roles = [...ROLES];
  return {
    roles: await db.query(
      "admin",
      `select rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole,
              rolreplication, rolconnlimit, rolconfig
       from pg_catalog.pg_roles where rolname = any($1) order by rolname`,
      [roles],
    ),
    memberships: await db.query(
      "admin",
      `select r.rolname as role, m.rolname as member, g.rolname as grantor,
              a.admin_option, a.inherit_option, a.set_option
       from pg_catalog.pg_auth_members a
       join pg_catalog.pg_roles r on r.oid = a.roleid
       join pg_catalog.pg_roles m on m.oid = a.member
       join pg_catalog.pg_roles g on g.oid = a.grantor
       where r.rolname = any($1) or m.rolname = any($1)
       order by 1, 2, 3`,
      [roles],
    ),
    database: await db.query(
      "admin",
      `select pg_catalog.pg_get_userbyid(datdba) as owner, datacl::text as acl
       from pg_catalog.pg_database where datname = current_database()`,
    ),
    schemas: await db.query(
      "admin",
      `select nspname, pg_catalog.pg_get_userbyid(nspowner) as owner, nspacl::text as acl
       from pg_catalog.pg_namespace
       where nspname in ('app', 'auth', 'meta', 'pgboss', 'public') order by nspname`,
    ),
    extensions: await db.query(
      "admin",
      `select extname, extnamespace::regnamespace::text as schema
       from pg_catalog.pg_extension order by extname`,
    ),
  };
}

beforeAll(async () => {
  db = await createTestDatabase("bootstrap", "empty");
});

afterAll(async () => {
  await db.drop();
});

describe("amorçage sous un compte d'administration qui n'est pas superutilisateur", () => {
  it("s'applique à une base vierge, fichier par fichier", async () => {
    const [admin] = await db.query<{ rolsuper: boolean; rolcreaterole: boolean }>(
      "admin",
      "select rolsuper, rolcreaterole from pg_catalog.pg_roles where rolname = current_user",
    );
    expect(admin).toEqual({ rolsuper: false, rolcreaterole: true });

    expect(await db.bootstrap()).toEqual([
      "10_roles.sql",
      "20_database.sql",
      "30_schemas.sql",
      "40_extensions.sql",
      "90_checks.sql",
    ]);
    afterFirstRun = await snapshot();
  });

  it("ne change rien quand il est rejoué", async () => {
    await db.bootstrap();
    expect(await snapshot()).toEqual(afterFirstRun);
  });

  it("crée les cinq rôles sans attribut privilégié, avec leurs limites", async () => {
    const roles = await db.query<Record<string, unknown>>(
      "admin",
      `select rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole,
              rolreplication, rolconnlimit, rolconfig
       from pg_catalog.pg_roles where rolname = any($1)`,
      [[...ROLES]],
    );
    expect(roles).toHaveLength(ROLES.length);
    for (const role of ROLES) {
      expect(roles.find((row) => row.rolname === role)).toEqual({
        rolname: role,
        rolcanlogin: true,
        rolsuper: false,
        rolbypassrls: false,
        rolcreatedb: false,
        rolcreaterole: false,
        rolreplication: false,
        rolconnlimit: EXPECTED_SETTINGS[role].limit,
        rolconfig: [
          `statement_timeout=${EXPECTED_SETTINGS[role].statementTimeout}`,
          "idle_in_transaction_session_timeout=60s",
        ],
      });
    }
  });

  it.each(ROLES)("laisse le rôle %s se connecter avec son mot de passe", async (role) => {
    // Le mot de passe a été transmis sous forme de vérificateur SCRAM-SHA-256 :
    // cette connexion prouve que PostgreSQL l'a enregistré tel quel.
    expect(await db.query(role, "select current_user as name")).toEqual([{ name: role }]);
  });

  it("refuse un mot de passe erroné", async () => {
    await expect(
      connect(db.config.database, { user: "app", password: "erroné" }),
    ).rejects.toMatchObject({
      code: "28P01",
    });
  });

  it("ferme la base aux rôles étrangers à l'application", async () => {
    expect(
      await db.query(
        "admin",
        `select has_database_privilege('public', current_database(), 'CONNECT') as connect,
                has_database_privilege('public', current_database(), 'TEMPORARY') as temporary,
                has_schema_privilege('public', 'public', 'CREATE') as create_in_public`,
      ),
    ).toEqual([{ connect: false, temporary: false, create_in_public: false }]);

    await db.query("admin", "drop role if exists memoire_test_intruder");
    await db.query("admin", "create role memoire_test_intruder login password 'intruder'");
    try {
      const intruder = { user: "memoire_test_intruder", password: "intruder" };
      await expect(connect(db.config.database, intruder)).rejects.toMatchObject({ code: "42501" });
    } finally {
      await db.query("admin", "drop role memoire_test_intruder");
    }
  });

  it("donne les schémas à leurs propriétaires et installe les extensions", async () => {
    expect(
      await db.query(
        "admin",
        `select nspname as schema, pg_catalog.pg_get_userbyid(nspowner) as owner
         from pg_catalog.pg_namespace
         where nspname in ('app', 'auth', 'meta', 'pgboss') order by nspname`,
      ),
    ).toEqual([
      { schema: "app", owner: "migrator" },
      { schema: "auth", owner: "migrator" },
      { schema: "meta", owner: "migrator" },
      { schema: "pgboss", owner: "queue" },
    ]);
    const extensions = await db.query<{ extname: string }>(
      "admin",
      "select extname from pg_catalog.pg_extension where extnamespace = 'public'::regnamespace",
    );
    expect(extensions.map((row) => row.extname).sort()).toEqual(["pg_trgm", "unaccent", "vector"]);
  });

  it("ne laisse au compte d'administration aucun droit hérité des cinq rôles", async () => {
    const rights = await db.query<{ role: string; usage: boolean; set: boolean }>(
      "admin",
      `select role, pg_has_role(current_user, role, 'USAGE') as usage,
              pg_has_role(current_user, role, 'SET') as set
       from unnest($1::text[]) as role`,
      [[...ROLES]],
    );
    expect(rights).toEqual(ROLES.map((role) => ({ role, usage: false, set: false })));
  });

  it("retire une appartenance que le compte d'administration se serait accordée", async () => {
    // C'est l'état que laisse createrole_self_grant à la création d'un rôle.
    await db.query("admin", "grant app, migrator to current_user with inherit true, set true");
    expect(
      await db.query("admin", "select pg_has_role(current_user, 'migrator', 'USAGE') as usage"),
    ).toEqual([{ usage: true }]);

    await db.bootstrap();
    expect(await snapshot()).toEqual(afterFirstRun);
  });

  it("refuse un rôle qui a reçu un attribut privilégié", async () => {
    // ALTER ROLE est transactionnel : l'attribut disparaît avec la transaction,
    // et rien ne reste sur le serveur si le test est interrompu.
    const checks = readFileSync(join(BOOTSTRAP_DIRECTORY, "90_checks.sql"), "utf8");
    const admin = await connect(db.config.database, db.credentials("admin"));
    try {
      await admin.query("begin");
      await admin.query("alter role backup createdb");
      await expect(admin.query(checks)).rejects.toThrow(
        /^amorçage incomplet : le rôle backup a un attribut inattendu$/,
      );
    } finally {
      await admin.query("rollback");
      await admin.end();
    }
    expect(await snapshot()).toEqual(afterFirstRun);
  });

  it("échoue en nommant le fichier fautif, sans rien appliquer de ce fichier", async () => {
    const directory = mkdtempSync(join(tmpdir(), "memoire-bootstrap-"));
    const empty = await createTestDatabase("bootstrap_checks", "empty");
    try {
      // Sur une base vierge, le contrôle final seul doit tout refuser.
      cpSync(join(BOOTSTRAP_DIRECTORY, "90_checks.sql"), join(directory, "90_checks.sql"));
      const run = runBootstrap({
        database: empty.config.database,
        admin: empty.credentials("admin"),
        rolePasswords: Object.fromEntries(ROLES.map((role) => [role, "inutile"])) as Record<
          RoleName,
          string
        >,
        directory,
        logger: memoryLogger(),
      });
      await expect(run).rejects.toThrow(
        /^Le fichier d'amorçage 90_checks\.sql a échoué : amorçage incomplet : PUBLIC peut encore se connecter à la base memoire_test_bootstrap_checks.* ; le schéma app appartient à personne au lieu de migrator ; .*l'extension pg_trgm manque/,
      );
    } finally {
      await empty.drop();
      rmSync(directory, { recursive: true });
    }
  });
});
