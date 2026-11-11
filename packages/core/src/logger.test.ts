import { describe, expect, it } from "vitest";
import { createLogger, describeError } from "./logger.js";

function capture() {
  const lines: string[] = [];
  const logger = createLogger({
    service: "server",
    env: "test",
    version: "abc123",
    write: (line) => lines.push(line),
  });
  return { lines, logger };
}

describe("createLogger", () => {
  it("écrit un objet JSON par ligne, champs fixes en tête", () => {
    const { lines, logger } = capture();
    logger.info("server.started", { port: 8080 });
    logger.error("server.failed");

    expect(lines).toHaveLength(2);
    expect(
      lines.every((line) => line.endsWith("\n") && line.indexOf("\n") === line.length - 1),
    ).toBe(true);
    const first = JSON.parse(lines[0] ?? "");
    expect(Object.keys(first)).toEqual([
      "ts",
      "level",
      "service",
      "env",
      "version",
      "event",
      "port",
    ]);
    expect(first).toMatchObject({
      level: "info",
      service: "server",
      env: "test",
      version: "abc123",
      event: "server.started",
      port: 8080,
    });
    expect(new Date(first.ts).toISOString()).toBe(first.ts);
    expect(JSON.parse(lines[1] ?? "").level).toBe("error");
  });

  it("ne laisse pas le contexte remplacer un champ fixe", () => {
    const { lines, logger } = capture();
    logger.warn("event", { level: "info", version: "autre", service: "autre" });
    expect(JSON.parse(lines[0] ?? "")).toMatchObject({
      level: "warn",
      version: "abc123",
      service: "server",
    });
  });
});

describe("describeError", () => {
  it("garde le nom, le message, le code et la cause", () => {
    const cause = Object.assign(new Error("password authentication failed"), { code: "28P01" });
    const error = new Error("La base n'est pas amorcée.", { cause });
    expect(describeError(error)).toEqual({
      name: "Error",
      message: "La base n'est pas amorcée.",
      cause: { name: "Error", message: "password authentication failed", code: "28P01" },
    });
  });

  it("rend lisible une connexion refusée sur plusieurs adresses", () => {
    const refusals = [
      new Error("connect ECONNREFUSED ::1:5432"),
      new Error("connect ECONNREFUSED 127.0.0.1:5432"),
    ];
    const error = Object.assign(new AggregateError(refusals, ""), { code: "ECONNREFUSED" });
    expect(describeError(error)).toEqual({
      name: "AggregateError",
      message: "connect ECONNREFUSED ::1:5432 ; connect ECONNREFUSED 127.0.0.1:5432",
      code: "ECONNREFUSED",
    });
  });

  it("lit la copie d'erreur que pg-boss transmet à la place de l'erreur", () => {
    const copy = {
      code: "ECONNREFUSED",
      message: "connect ECONNREFUSED 127.0.0.1:5432",
      stack: "Error: connect ECONNREFUSED 127.0.0.1:5432",
      queue: "system-heartbeat",
    };
    expect(describeError(copy)).toEqual({
      name: "Error",
      message: "connect ECONNREFUSED 127.0.0.1:5432",
      code: "ECONNREFUSED",
    });
  });

  it("accepte ce qui n'est pas une erreur", () => {
    expect(describeError("panne")).toEqual({ name: "Error", message: "panne" });
  });
});
