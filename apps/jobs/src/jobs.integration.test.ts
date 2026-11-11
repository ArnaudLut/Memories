import { randomUUID } from "node:crypto";
import { createPool, type Pool, withTenant } from "@memoire/core";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createTestDatabase,
  memoryLogger,
  type TestDatabase,
} from "../../../packages/core/src/testing.js";
import { EXIT_FAILED, EXIT_NOT_BOOTSTRAPPED, EXIT_OK, type JobName, runJob } from "./jobs.js";
import { dumpWitness } from "./pg-dump.js";
import type { VerifyReport } from "./verify.js";

let db: TestDatabase;

async function run(name: JobName, env: NodeJS.ProcessEnv = db.env) {
  const logger = memoryLogger();
  const printed: string[] = [];
  const code = await runJob(name, { env, logger, print: (text) => printed.push(text) });
  return { code, events: logger.entries.map((entry) => entry.event), output: printed.join("") };
}

beforeAll(async () => {
  db = await createTestDatabase("jobs", "empty");
});

afterAll(async () => {
  await db.drop();
});

// Les jobs s'enchaînent comme lors d'un premier déploiement.
describe("jobs, dans l'ordre d'un premier déploiement", () => {
  it("migrate sort avec le code 3 tant que la base n'est pas amorcée", async () => {
    const { code, events } = await run("migrate");
    expect(code).toBe(EXIT_NOT_BOOTSTRAPPED);
    expect(events).toEqual(["job.failed"]);
  });

  it("db-bootstrap amorce la base", async () => {
    const { code, events, output } = await run("db-bootstrap");
    expect(code).toBe(EXIT_OK);
    expect(events.at(-1)).toBe("job.succeeded");
    expect(output).toBe("");
  });

  it("migrate applique les migrations, puis n'a plus rien à faire", async () => {
    expect(await run("migrate")).toMatchObject({ code: EXIT_OK, output: "" });
    const second = await run("migrate");
    expect(second.code).toBe(EXIT_OK);
    expect(second.events).toEqual(["migrations.completed", "job.succeeded"]);
  });

  it("verify n'écrit que son rapport sur la sortie standard, et il est positif", async () => {
    const { code, output } = await run("verify");
    const report = JSON.parse(output) as VerifyReport;
    expect(report).toMatchObject({
      status: "ok",
      env: "test",
      version: "test",
      checks: {
        roles: {
          status: "ok",
          admin: { name: "avnadmin", superuser: false, bypassrls: false, createrole: true },
        },
        pgvector: { status: "ok" },
        rls: {
          status: "ok",
          rowsWithoutTenant: 0,
          rowsSeenByOwner: 0,
          dumpContainsBothRows: true,
          dumpWithoutRowSecurityRefused: true,
        },
        queue: { status: "ok", schema: "pgboss", owner: "queue" },
      },
    });
    expect(report.postgresql).toMatch(/^17\./);
    expect(report.checks.pgvector.version).toMatch(/^\d+\.\d+\.\d+$/);
    expect(report.checks.rls.dumpRefusal).toMatch(/row-level security/);
    expect(code).toBe(EXIT_OK);
  });

  it("verify ne laisse aucune ligne dans la table témoin", async () => {
    expect(await db.query("backup", "select count(*)::int as n from app.rls_witness")).toEqual([
      { n: 0 },
    ]);
  });
});

describe("verify sur une base défaillante", () => {
  it("échoue quand la RLS de la table témoin n'est plus forcée", async () => {
    await db.query("migrator", "alter table app.rls_witness no force row level security");
    try {
      const { code, output } = await run("verify");
      const report = JSON.parse(output) as VerifyReport;
      expect(code).toBe(EXIT_FAILED);
      expect(report.status).toBe("failed");
      expect(report.checks.rls).toMatchObject({ status: "failed", rowsSeenByOwner: 2 });
      expect(report.checks.rls.detail).toMatch(/le propriétaire de la table voit 2 ligne\(s\)/);
      expect(report.checks.roles.status).toBe("ok");
    } finally {
      await db.query("migrator", "alter table app.rls_witness force row level security");
    }
  });

  it("échoue quand la sauvegarde ne peut pas se connecter", async () => {
    const { code, output } = await run("verify", { ...db.env, DB_BACKUP_PASSWORD: "erroné" });
    const report = JSON.parse(output) as VerifyReport;
    expect(code).toBe(EXIT_FAILED);
    // Un échec de connexion n'est pas le refus attendu de la RLS.
    expect(report.checks.rls).toMatchObject({
      status: "failed",
      dumpContainsBothRows: false,
      dumpWithoutRowSecurityRefused: false,
    });
  });
});

describe("pg_dump de la table témoin sous le rôle backup", () => {
  const witnesses = [
    { tenant: randomUUID(), note: `dump-${randomUUID()}` },
    { tenant: randomUUID(), note: `dump-${randomUUID()}` },
  ];
  let app: Pool;

  beforeAll(async () => {
    app = createPool(db.config.database, db.credentials("app"), { max: 1, logger: memoryLogger() });
    for (const { tenant, note } of witnesses) {
      await withTenant(app, tenant, (client) =>
        client.query("insert into app.rls_witness (tenant_id, note) values ($1, $2)", [
          tenant,
          note,
        ]),
      );
    }
  });

  afterAll(async () => {
    await app.end();
  });

  it("contient les lignes de tous les tenants avec --enable-row-security", async () => {
    const dump = await dumpWitness(db.config.database, db.credentials("backup"), {
      rowSecurity: true,
    });
    expect(dump.exitCode).toBe(0);
    expect(dump.stdout).toContain(
      "COPY app.rls_witness (id, tenant_id, note, created_at) FROM stdin;",
    );
    for (const { tenant, note } of witnesses) {
      expect(dump.stdout).toContain(`${tenant}\t${note}`);
    }
  });

  it("échoue sans cette option, au lieu de produire une sauvegarde incomplète", async () => {
    const dump = await dumpWitness(db.config.database, db.credentials("backup"), {
      rowSecurity: false,
    });
    expect(dump.exitCode).not.toBe(0);
    expect(dump.stderr).toMatch(
      /query would be affected by row-level security policy for table "rls_witness"/,
    );
    for (const { note } of witnesses) {
      expect(dump.stdout).not.toContain(note);
    }
  });
});
