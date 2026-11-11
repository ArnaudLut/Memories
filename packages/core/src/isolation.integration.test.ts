import { randomUUID } from "node:crypto";
import type { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { connect, createPool, withTenant } from "./database.js";
import { createTestDatabase, memoryLogger, type TestDatabase } from "./testing.js";

// Codes d'erreur de PostgreSQL : droit insuffisant, politique RLS violée.
const INSUFFICIENT_PRIVILEGE = "42501";

const tenantA = randomUUID();
const tenantB = randomUUID();

let db: TestDatabase;
let app: Pool;

function notes(tenantId: string): Promise<string[]> {
  return withTenant(app, tenantId, async (client) => {
    const { rows } = await client.query<{ note: string }>(
      "select note from app.rls_witness order by note",
    );
    return rows.map((row) => row.note);
  });
}

beforeAll(async () => {
  db = await createTestDatabase("isolation", "migrated");
  // Une seule connexion : toute fuite de contexte d'une transaction à la
  // suivante se verrait.
  app = createPool(db.config.database, db.credentials("app"), { max: 1, logger: memoryLogger() });
  for (const [tenantId, note] of [
    [tenantA, "ligne de A"],
    [tenantB, "ligne de B"],
  ] as const) {
    await withTenant(app, tenantId, (client) =>
      client.query("insert into app.rls_witness (tenant_id, note) values ($1, $2)", [
        tenantId,
        note,
      ]),
    );
  }
});

afterAll(async () => {
  await app.end();
  await db.drop();
});

describe("isolation des tenants sous le rôle app", () => {
  it("ne montre à chaque tenant que ses lignes", async () => {
    expect(await notes(tenantA)).toEqual(["ligne de A"]);
    expect(await notes(tenantB)).toEqual(["ligne de B"]);
  });

  it("ne montre aucune ligne et n'accepte aucune écriture sans contexte de tenant", async () => {
    expect((await app.query("select app.current_tenant_id() as tenant")).rows).toEqual([
      { tenant: null },
    ]);
    expect((await app.query("select count(*)::int as n from app.rls_witness")).rows).toEqual([
      { n: 0 },
    ]);
    await expect(
      app.query("insert into app.rls_witness (tenant_id, note) values ($1, 'intrus')", [tenantA]),
    ).rejects.toMatchObject({ code: INSUFFICIENT_PRIVILEGE });
  });

  it("empêche un tenant d'écrire, de modifier ou de supprimer chez un autre", async () => {
    await expect(
      withTenant(app, tenantA, (client) =>
        client.query("insert into app.rls_witness (tenant_id, note) values ($1, 'intrus')", [
          tenantB,
        ]),
      ),
    ).rejects.toMatchObject({ code: INSUFFICIENT_PRIVILEGE });
    await expect(
      withTenant(app, tenantA, (client) =>
        client.query("update app.rls_witness set tenant_id = $1", [tenantB]),
      ),
    ).rejects.toMatchObject({ code: INSUFFICIENT_PRIVILEGE });

    const touched = await withTenant(app, tenantA, async (client) => {
      const updated = await client.query(
        "update app.rls_witness set note = 'volée' where tenant_id = $1",
        [tenantB],
      );
      const deleted = await client.query("delete from app.rls_witness where tenant_id = $1", [
        tenantB,
      ]);
      return [updated.rowCount, deleted.rowCount];
    });
    expect(touched).toEqual([0, 0]);
    expect(await notes(tenantB)).toEqual(["ligne de B"]);
  });

  it("annule la transaction quand le traitement échoue", async () => {
    const failure = withTenant(app, tenantA, async (client) => {
      await client.query("insert into app.rls_witness (tenant_id, note) values ($1, 'annulée')", [
        tenantA,
      ]);
      throw new Error("échec du traitement");
    });
    await expect(failure).rejects.toThrow("échec du traitement");
    expect(await notes(tenantA)).toEqual(["ligne de A"]);
  });

  it("échoue quand le traitement a ignoré l'échec d'une requête", async () => {
    const ignored = withTenant(app, tenantA, async (client) => {
      await client.query("insert into app.rls_witness (tenant_id, note) values ($1, 'perdue')", [
        tenantA,
      ]);
      await client.query("select 1 / 0").catch(() => {});
      return "terminé";
    });
    await expect(ignored).rejects.toThrow(/annulée par PostgreSQL/);
    expect(await notes(tenantA)).toEqual(["ligne de A"]);
  });

  it("survit à une connexion perdue en cours de transaction", async () => {
    const lost = withTenant(app, tenantA, (client) =>
      client.query("select pg_terminate_backend(pg_backend_pid())"),
    );
    await expect(lost).rejects.toThrow();
    expect(await notes(tenantA)).toEqual(["ligne de A"]);
  });

  it("ne peut pas vider la table, ce qui échapperait à la RLS", async () => {
    await expect(app.query("truncate app.rls_witness")).rejects.toMatchObject({
      code: INSUFFICIENT_PRIVILEGE,
    });
  });
});

describe("autres rôles", () => {
  it("le propriétaire des tables ne voit ni n'écrit aucune ligne : la RLS est forcée", async () => {
    expect(await db.query("migrator", "select count(*)::int as n from app.rls_witness")).toEqual([
      { n: 0 },
    ]);
    await expect(
      db.query("migrator", "insert into app.rls_witness (tenant_id, note) values ($1, 'intrus')", [
        tenantA,
      ]),
    ).rejects.toMatchObject({ code: INSUFFICIENT_PRIVILEGE });
  });

  it("le propriétaire des tables ne voit aucune ligne, même avec le contexte d'un tenant", async () => {
    // La politique des tenants ne vaut que pour le rôle app.
    const migrator = await connect(db.config.database, db.credentials("migrator"));
    try {
      await migrator.query("begin");
      await migrator.query("select set_config('app.tenant_id', $1, true)", [tenantA]);
      const { rows } = await migrator.query("select count(*)::int as n from app.rls_witness");
      expect(rows).toEqual([{ n: 0 }]);
    } finally {
      await migrator.query("rollback");
      await migrator.end();
    }
  });

  it("backup lit les lignes de tous les tenants, sans pouvoir écrire", async () => {
    expect(await db.query("backup", "select note from app.rls_witness order by note")).toEqual([
      { note: "ligne de A" },
      { note: "ligne de B" },
    ]);
    for (const statement of [
      `insert into app.rls_witness (tenant_id, note) values ('${tenantA}', 'intrus')`,
      "update app.rls_witness set note = 'volée'",
      "delete from app.rls_witness",
    ]) {
      await expect(db.query("backup", statement)).rejects.toMatchObject({
        code: INSUFFICIENT_PRIVILEGE,
      });
    }
  });

  it("app et backup lisent le journal des migrations, sans pouvoir l'écrire", async () => {
    for (const role of ["app", "backup"] as const) {
      const rows = await db.query(role, "select version from meta.schema_migrations");
      expect(rows.length).toBeGreaterThan(0);
      await expect(db.query(role, "delete from meta.schema_migrations")).rejects.toMatchObject({
        code: INSUFFICIENT_PRIVILEGE,
      });
    }
  });

  it.each(["admin", "auth", "queue"] as const)(
    "%s n'a aucun accès aux données des tenants",
    async (role) => {
      await expect(db.query(role, "select count(*) from app.rls_witness")).rejects.toMatchObject({
        code: INSUFFICIENT_PRIVILEGE,
      });
    },
  );
});

describe("règle pour toutes les tables du schéma app", () => {
  it("chaque table a la RLS activée et forcée, une politique pour app et la lecture pour backup", async () => {
    // Sans politique de lecture pour backup, pg_dump réussit et sauvegarde une
    // table vide : cet oubli ne se verrait qu'à la restauration.
    const tables = await db.query<{
      name: string;
      enabled: boolean;
      forced: boolean;
      tenantPolicy: boolean;
      backupReads: boolean;
    }>(
      "migrator",
      `select c.relname as name, c.relrowsecurity as enabled, c.relforcerowsecurity as forced,
              exists (select from pg_catalog.pg_policy p
                      where p.polrelid = c.oid and 'app'::regrole = any (p.polroles)) as "tenantPolicy",
              exists (select from pg_catalog.pg_policy p
                      where p.polrelid = c.oid and p.polpermissive and p.polcmd in ('r', '*')
                        and 'backup'::regrole = any (p.polroles)
                        and pg_catalog.pg_get_expr(p.polqual, p.polrelid) = 'true') as "backupReads"
       from pg_catalog.pg_class c
       where c.relnamespace = 'app'::regnamespace and c.relkind in ('r', 'p')
       order by c.relname`,
    );
    expect(tables.map((table) => table.name)).toContain("rls_witness");
    const unprotected = tables.filter(
      (table) => !table.enabled || !table.forced || !table.tenantPolicy || !table.backupReads,
    );
    expect(unprotected).toEqual([]);
  });

  it("une table créée par une migration future reçoit les mêmes droits", async () => {
    // Droits par défaut posés par la migration 0001, observés sur une table
    // créée puis annulée.
    const migrator = await connect(db.config.database, db.credentials("migrator"));
    try {
      await migrator.query("begin");
      await migrator.query(
        "create table app.future_table (id bigint generated always as identity primary key)",
      );
      const { rows } = await migrator.query(
        `select grantee::text, array_agg(privilege_type::text order by privilege_type) as privileges
         from information_schema.role_table_grants
         where table_schema = 'app' and table_name = 'future_table' and grantee in ('app', 'backup')
         group by grantee order by grantee`,
      );
      expect(rows).toEqual([
        { grantee: "app", privileges: ["DELETE", "INSERT", "SELECT", "UPDATE"] },
        { grantee: "backup", privileges: ["SELECT"] },
      ]);
      // La séquence de la colonne suit la table : sans ces droits, app
      // n'insère pas dans une colonne serial et pg_dump échoue sous backup.
      const sequence = await migrator.query(
        `select has_sequence_privilege('app', 'app.future_table_id_seq', 'USAGE') as "appDraws",
                has_sequence_privilege('backup', 'app.future_table_id_seq', 'SELECT') as "backupReads"`,
      );
      expect(sequence.rows).toEqual([{ appDraws: true, backupReads: true }]);
    } finally {
      await migrator.query("rollback");
      await migrator.end();
    }
  });
});
