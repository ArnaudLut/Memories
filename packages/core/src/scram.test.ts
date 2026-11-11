import { describe, expect, it } from "vitest";
import { scramSha256Verifier } from "./scram.js";

describe("scramSha256Verifier", () => {
  it("retrouve les clés de l'échange d'exemple de la RFC 7677", () => {
    // Utilisateur « user », mot de passe « pencil » : la clé enregistrée et la
    // clé du serveur ci-dessous redonnent la preuve et la signature publiées
    // dans la section 3 de la RFC.
    const salt = Buffer.from("W22ZaJ0SNY7soEsUEjb6gQ==", "base64");
    expect(scramSha256Verifier("pencil", salt)).toBe(
      "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU=",
    );
  });

  it("donne le vérificateur que PostgreSQL 17 calcule pour le même sel", () => {
    // Relevé dans pg_authid après CREATE ROLE ... PASSWORD 'Probe-123 xyz'.
    const salt = Buffer.from("QpXN3J6Ihsv3WNrTUDBLIA==", "base64");
    expect(scramSha256Verifier("Probe-123 xyz", salt)).toBe(
      "SCRAM-SHA-256$4096:QpXN3J6Ihsv3WNrTUDBLIA==$9FxQ6o0wRT2tQ/3TIaQWTxO0bu32UziFBa1qws7TzQA=:xcIiIrZd6pY2N6FCRhhgmkwYn7psp4D/yk2WZ81Pu70=",
    );
  });

  it("tire un sel de seize octets à chaque appel", () => {
    const first = scramSha256Verifier("pencil");
    const second = scramSha256Verifier("pencil");
    expect(first).not.toBe(second);
    const salt = /^SCRAM-SHA-256\$4096:([^$]+)\$/.exec(first)?.[1] ?? "";
    expect(Buffer.from(salt, "base64")).toHaveLength(16);
  });

  it.each(["", "motdepassé", "tab\tulation"])("refuse le mot de passe « %s »", (password) => {
    expect(() => scramSha256Verifier(password)).toThrow(/ASCII imprimable/);
  });
});
