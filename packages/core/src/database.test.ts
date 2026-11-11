import type { Pool } from "pg";
import { describe, expect, it } from "vitest";
import { connectionOptions, withTenant } from "./database.js";

const database = { host: "db.example.com", port: 20184, name: "memoire" };
const credentials = { user: "app", password: "secret" };

describe("connectionOptions", () => {
  it("ne chiffre pas quand la configuration n'a pas de TLS", () => {
    expect(connectionOptions(database, credentials)).toMatchObject({
      host: "db.example.com",
      port: 20184,
      database: "memoire",
      user: "app",
      password: "secret",
      ssl: false,
    });
  });

  it("vérifie le certificat du serveur contre l'autorité fournie", () => {
    const tls = { rootCertPath: "/etc/memoire/db-ca.pem", ca: "certificat" };
    expect(connectionOptions({ ...database, tls }, credentials).ssl).toEqual({
      ca: "certificat",
      rejectUnauthorized: true,
    });
  });

  it("borne à trois secondes l'ouverture d'une connexion", () => {
    expect(connectionOptions(database, credentials)).toMatchObject({
      connectionTimeoutMillis: 3000,
    });
  });
});

describe("withTenant", () => {
  it.each(["", "tenant-1", "11111111-1111-4111-8111-11111111111", "' or true --"])(
    "refuse l'identifiant « %s » sans ouvrir de connexion",
    async (tenantId) => {
      const pool = {
        connect: () => {
          throw new Error("aucune connexion ne doit être demandée");
        },
      } as unknown as Pool;
      await expect(withTenant(pool, tenantId, async () => "jamais")).rejects.toThrow(
        /doit être un UUID/,
      );
    },
  );
});
