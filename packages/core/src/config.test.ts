import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { adminCredentials, ConfigError, loadConfig, readPort, roleCredentials } from "./config.js";

const local = {
  APP_ENV: "development",
  APP_VERSION: "abc123",
  PGHOST: "127.0.0.1",
  PGPORT: "5432",
  PGDATABASE: "memoire",
  PGSSLMODE: "disable",
};

describe("loadConfig", () => {
  it("lit la configuration d'une base locale, sans TLS", () => {
    expect(loadConfig(local)).toEqual({
      appEnv: "development",
      version: "abc123",
      database: { host: "127.0.0.1", port: 5432, name: "memoire" },
    });
  });

  it("lit le certificat de l'autorité quand PGSSLMODE vaut verify-full", () => {
    const directory = mkdtempSync(join(tmpdir(), "memoire-config-"));
    const rootCertPath = join(directory, "db-ca.pem");
    writeFileSync(rootCertPath, "certificat de test\n");
    try {
      const config = loadConfig({
        ...local,
        PGSSLMODE: "verify-full",
        PGSSLROOTCERT: rootCertPath,
      });
      expect(config.database.tls).toEqual({ rootCertPath, ca: "certificat de test\n" });
    } finally {
      rmSync(directory, { recursive: true });
    }
  });

  it("refuse verify-full sans certificat lisible", () => {
    const env = { ...local, PGSSLMODE: "verify-full" };
    expect(() => loadConfig(env)).toThrow(/PGSSLROOTCERT est absente/);
    expect(() => loadConfig({ ...env, PGSSLROOTCERT: "/chemin/absent.pem" })).toThrow(
      /\(PGSSLROOTCERT\) est illisible/,
    );
  });

  it.each(["require", "prefer", "verify-ca", "no-verify"])(
    "refuse le mode TLS « %s », qui n'authentifie pas le serveur",
    (mode) => {
      expect(() => loadConfig({ ...local, PGSSLMODE: mode })).toThrow(/PGSSLMODE/);
    },
  );

  it.each(Object.keys(local))("refuse une configuration sans %s", (name) => {
    const env: NodeJS.ProcessEnv = { ...local, [name]: "" };
    expect(() => loadConfig(env)).toThrow(ConfigError);
    expect(() => loadConfig(env)).toThrow(`${name} est absente`);
  });

  it("refuse un environnement inconnu", () => {
    expect(() => loadConfig({ ...local, APP_ENV: "staging" })).toThrow(/APP_ENV vaut « staging »/);
  });
});

describe("readPort", () => {
  it.each(["0", "65536", "80a", "-1", "8080.5"])("refuse « %s »", (value) => {
    expect(() => readPort({ PORT: value }, "PORT")).toThrow(/n'est pas un numéro de port/);
  });

  it("n'emploie la valeur de repli que si la variable est absente", () => {
    expect(readPort({}, "PORT", 8080)).toBe(8080);
    expect(readPort({ PORT: "9090" }, "PORT", 8080)).toBe(9090);
  });
});

describe("identifiants", () => {
  it("lit le mot de passe du seul rôle demandé", () => {
    expect(roleCredentials({ DB_APP_PASSWORD: "secret" }, "app")).toEqual({
      user: "app",
      password: "secret",
    });
    expect(() => roleCredentials({ DB_APP_PASSWORD: "secret" }, "queue")).toThrow(
      /DB_QUEUE_PASSWORD est absente/,
    );
  });

  it("nomme le compte d'administration avnadmin par défaut", () => {
    expect(adminCredentials({ DB_ADMIN_PASSWORD: "secret" }).user).toBe("avnadmin");
    expect(adminCredentials({ DB_ADMIN_USER: "admin", DB_ADMIN_PASSWORD: "secret" }).user).toBe(
      "admin",
    );
  });
});
