import { appendFileSync, cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { NotBootstrappedError, readMigrationFiles, runMigrations } from "./migrations.js";
import {
  createTestDatabase,
  MIGRATIONS_DIRECTORY,
  memoryLogger,
  type TestDatabase,
} from "./testing.js";

let db: TestDatabase;
let versions: string[];
const directories: string[] = [];

/** Copie des migrations du dépôt, à laquelle un test ajoute ou change un fichier. */
function copyOfMigrations(): string {
  const directory = mkdtempSync(join(tmpdir(), "memoire-migrations-"));
  directories.push(directory);
  cpSync(MIGRATIONS_DIRECTORY, directory, { recursive: true });
  return directory;
}

async function journal(): Promise<string[]> {
  const rows = await db.query<{ version: string }>(
    "migrator",
    "select version from meta.schema_migrations order by version",
  );
  return rows.map((row) => row.version);
}

beforeAll(async () => {
  db = await createTestDatabase("migrations", "bootstrapped");
  versions = (await readMigrationFiles(MIGRATIONS_DIRECTORY)).map((file) => file.version);
});

afterAll(async () => {
  await db.drop();
  for (const directory of directories) {
    rmSync(directory, { recursive: true });
  }
});

describe("migrations", () => {
  it("s'appliquent une seule fois quand deux exécutions démarrent ensemble", async () => {
    const [first, second] = await Promise.all([db.migrate(), db.migrate()]);
    expect([first, second].sort((a, b) => a.length - b.length)).toEqual([[], versions]);
    expect(await journal()).toEqual(versions);
  });

  it("ne font rien au passage suivant", async () => {
    expect(await db.migrate()).toEqual([]);
    expect(await journal()).toEqual(versions);
  });

  it("inscrivent au journal le nom et la somme de contrôle de chaque fichier", async () => {
    const files = await readMigrationFiles(MIGRATIONS_DIRECTORY);
    expect(
      await db.query(
        "migrator",
        "select version, name, checksum from meta.schema_migrations order by version",
      ),
    ).toEqual(files.map(({ version, name, checksum }) => ({ version, name, checksum })));
  });

  it("refusent un fichier modifié après son application", async () => {
    const directory = copyOfMigrations();
    appendFileSync(join(directory, "0001_rls_witness.sql"), "-- retouche\n");
    await expect(db.migrate(directory)).rejects.toThrow(/0001 a changé depuis son application/);
  });

  it("annulent en entier une migration qui échoue", async () => {
    const directory = copyOfMigrations();
    writeFileSync(
      join(directory, "9998_broken.sql"),
      "create table app.broken (id integer);\nselect 1 / 0;\n",
    );
    await expect(db.migrate(directory)).rejects.toThrow(
      /^La migration 9998_broken a échoué : division by zero$/,
    );
    expect(await db.query("migrator", "select to_regclass('app.broken') as oid")).toEqual([
      { oid: null },
    ]);
    expect(await journal()).toEqual(versions);
  });

  it("signalent une base en avance sur les fichiers sans échouer", async () => {
    const directory = copyOfMigrations();
    writeFileSync(join(directory, "9997_ahead.sql"), "select 1;\n");
    expect(await db.migrate(directory)).toEqual(["9997"]);

    const logger = memoryLogger();
    const applied = await runMigrations({
      database: db.config.database,
      credentials: db.credentials("migrator"),
      directory: MIGRATIONS_DIRECTORY,
      logger,
    });
    expect(applied).toEqual([]);
    expect(logger.entries).toEqual([
      { level: "warn", event: "migrations.database_ahead", context: { versions: ["9997"] } },
    ]);
  });

  it("refusent un fichier qui termine lui-même sa transaction", async () => {
    const directory = copyOfMigrations();
    writeFileSync(join(directory, "9997_ahead.sql"), "select 1;\n");
    writeFileSync(join(directory, "9999_commits.sql"), "select 1;\ncommit;\n");
    await expect(db.migrate(directory)).rejects.toThrow(
      /^La migration 9999_commits a échoué : le fichier a terminé sa transaction/,
    );
    expect(await journal()).toEqual([...versions, "9997"]);
  });
});

describe("base non amorcée", () => {
  it("est reconnue quand le rôle migrator ne peut pas s'authentifier", async () => {
    const run = runMigrations({
      database: db.config.database,
      credentials: { user: "migrator", password: "erroné" },
      directory: MIGRATIONS_DIRECTORY,
      logger: memoryLogger(),
    });
    await expect(run).rejects.toThrow(NotBootstrappedError);
  });

  it("est reconnue quand le schéma meta manque", async () => {
    const empty = await createTestDatabase("migrations_empty", "empty");
    try {
      await expect(empty.migrate()).rejects.toThrow(NotBootstrappedError);
    } finally {
      await empty.drop();
    }
  });
});
