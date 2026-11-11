import type { Client } from "@memoire/core";
import { describe, expect, it } from "vitest";
import { checkQueue, checkRoles } from "./verify.js";

/** Client dont toute requête renvoie les lignes données. */
function clientReturning(rows: object[]): Client {
  return { query: async () => ({ rows }) } as unknown as Client;
}

const plain = { superuser: false, bypassrls: false };
const roles = ["app", "auth", "queue", "backup", "migrator"].map((name) => ({ name, ...plain }));

describe("contrôle des rôles", () => {
  it("réussit quand les cinq rôles n'ont ni SUPERUSER ni BYPASSRLS", async () => {
    const check = await checkRoles(clientReturning(roles), "avnadmin");
    expect(check).toMatchObject({ status: "ok", admin: null });
  });

  it.each(["superuser", "bypassrls"])("échoue quand un rôle a l'attribut %s", async (attribute) => {
    const rows = roles.map((role) => (role.name === "app" ? { ...role, [attribute]: true } : role));
    const check = await checkRoles(clientReturning(rows), "avnadmin");
    expect(check.status).toBe("failed");
    expect(check.detail).toMatch(/le rôle app a l'attribut SUPERUSER ou BYPASSRLS/);
  });

  it("échoue quand un rôle manque", async () => {
    const check = await checkRoles(clientReturning(roles.slice(1)), "avnadmin");
    expect(check).toMatchObject({
      status: "failed",
      detail: "Anomalies : le rôle app est absent.",
    });
  });
});

describe("contrôle du schéma de la file", () => {
  it("réussit quand le schéma appartient au rôle queue", async () => {
    expect(await checkQueue(clientReturning([{ owner: "queue" }]))).toMatchObject({
      status: "ok",
      owner: "queue",
    });
  });

  it("échoue quand le schéma appartient à un autre rôle", async () => {
    expect(await checkQueue(clientReturning([{ owner: "avnadmin" }]))).toMatchObject({
      status: "failed",
      detail: "Anomalies : le schéma pgboss appartient à avnadmin.",
    });
  });

  it("échoue quand le schéma est absent", async () => {
    expect(await checkQueue(clientReturning([]))).toMatchObject({
      status: "failed",
      detail: "Anomalies : le schéma pgboss est absent.",
      owner: null,
    });
  });
});
