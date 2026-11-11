import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { type MigrationFile, pendingMigrations, readMigrationFiles } from "./migrations.js";

const directories: string[] = [];

function migrationsDirectory(files: Record<string, string>): string {
  const directory = mkdtempSync(join(tmpdir(), "memoire-migrations-"));
  directories.push(directory);
  for (const [name, content] of Object.entries(files)) {
    writeFileSync(join(directory, name), content);
  }
  return directory;
}

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true });
  }
});

describe("readMigrationFiles", () => {
  it("lit les fichiers dans l'ordre de leur numéro, avec leur somme de contrôle", async () => {
    const directory = migrationsDirectory({
      "0002_second_step.sql": "select 2;\n",
      "0001_first.sql": "select 1;\n",
    });
    expect(await readMigrationFiles(directory)).toEqual([
      {
        version: "0001",
        name: "first",
        checksum: createHash("sha256").update("select 1;\n").digest("hex"),
        sql: "select 1;\n",
      },
      {
        version: "0002",
        name: "second_step",
        checksum: createHash("sha256").update("select 2;\n").digest("hex"),
        sql: "select 2;\n",
      },
    ]);
  });

  it.each(["1_short.sql", "0001_Majuscule.sql", "0001-tiret.sql", "0001_.sql", "notes.txt"])(
    "refuse le fichier « %s »",
    async (name) => {
      const directory = migrationsDirectory({ [name]: "select 1;\n" });
      await expect(readMigrationFiles(directory)).rejects.toThrow(/ne suit pas la forme/);
    },
  );

  it("refuse deux migrations de même numéro", async () => {
    const directory = migrationsDirectory({ "0001_a.sql": "", "0001_b.sql": "" });
    await expect(readMigrationFiles(directory)).rejects.toThrow(/portent le numéro 0001/);
  });
});

describe("pendingMigrations", () => {
  const file = (version: string, checksum = `sum-${version}`): MigrationFile => ({
    version,
    name: "step",
    checksum,
    sql: "",
  });
  const files = [file("0001"), file("0002"), file("0003")];

  it("retient tout sur une base neuve", () => {
    expect(pendingMigrations(files, [])).toEqual(files);
  });

  it("ne retient que les migrations absentes du journal", () => {
    const applied = [{ version: "0001", checksum: "sum-0001" }];
    expect(pendingMigrations(files, applied)).toEqual([file("0002"), file("0003")]);
  });

  it("refuse une migration modifiée après son application", () => {
    const applied = [{ version: "0001", checksum: "autre" }];
    expect(() => pendingMigrations(files, applied)).toThrow(/0001 a changé depuis son application/);
  });

  it("refuse une migration plus ancienne que la dernière appliquée", () => {
    const applied = [
      { version: "0001", checksum: "sum-0001" },
      { version: "0003", checksum: "sum-0003" },
    ];
    expect(() => pendingMigrations(files, applied)).toThrow(/0002 n'est pas au journal/);
  });

  it("admet une base en avance sur les fichiers, après un retour arrière", () => {
    const applied = files.map(({ version, checksum }) => ({ version, checksum }));
    expect(pendingMigrations(files.slice(0, 2), applied)).toEqual([]);
  });
});
