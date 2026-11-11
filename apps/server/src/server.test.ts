import type { AddressInfo } from "node:net";
import type { Config, Pool } from "@memoire/core";
import { afterEach, describe, expect, it } from "vitest";
import { memoryLogger } from "../../../packages/core/src/testing.js";
import { createHealthServer } from "./server.js";

const config: Config = {
  appEnv: "test",
  version: "abc123",
  database: { host: "127.0.0.1", port: 5432, name: "memoire" },
};

const stops: (() => Promise<void>)[] = [];

async function start(query: () => Promise<{ rows: { version: string | null }[] }>) {
  const logger = memoryLogger();
  const server = createHealthServer({ pool: { query } as unknown as Pool, config, logger });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  stops.push(() => new Promise((resolve) => server.close(() => resolve())));
  const { port } = server.address() as AddressInfo;
  return { logger, url: `http://127.0.0.1:${port}` };
}

const healthy = async () => ({ rows: [{ version: "0001" }] });
const unreachable = async () => {
  throw Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:5432"), { code: "ECONNREFUSED" });
};

afterEach(async () => {
  for (const stop of stops.splice(0)) {
    await stop();
  }
});

describe("GET /health", () => {
  it("répond 200 avec la version, l'environnement et la dernière migration", async () => {
    const { logger, url } = await start(healthy);
    const response = await fetch(`${url}/health`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      status: "ok",
      version: "abc123",
      env: "test",
      checks: { database: "ok", migrations: "0001" },
    });
    expect(logger.entries).toEqual([]);
  });

  it("répond 503 et « degraded » quand la base ne répond pas", async () => {
    const { logger, url } = await start(unreachable);
    const response = await fetch(`${url}/health`);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      status: "degraded",
      version: "abc123",
      env: "test",
      checks: { database: "error", migrations: null },
    });
    expect(logger.entries.map((entry) => entry.event)).toEqual([
      "health.database_check_failed",
      "http.request",
    ]);
  });

  it("accepte HEAD et refuse les autres méthodes", async () => {
    const { url } = await start(healthy);
    expect((await fetch(`${url}/health`, { method: "HEAD" })).status).toBe(200);
    const response = await fetch(`${url}/health`, { method: "POST" });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, HEAD");
    expect(await response.json()).toEqual({ error: "method_not_allowed" });
  });
});

describe("autres chemins", () => {
  it("répond 404 en JSON", async () => {
    const { url } = await start(healthy);
    for (const path of ["/", "/healthz", "/health/", "/admin"]) {
      const response = await fetch(`${url}${path}`);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
  });

  it("ne journalise que la méthode, le chemin sans sa requête, le statut et la durée", async () => {
    const { logger, url } = await start(healthy);
    await fetch(`${url}/memoires?email=personne@example.com`, {
      headers: { authorization: "Bearer jeton", "x-forwarded-for": "203.0.113.7" },
    });
    expect(logger.entries).toHaveLength(1);
    const { event, context } = logger.entries[0] ?? {};
    expect(event).toBe("http.request");
    expect(Object.keys(context ?? {}).sort()).toEqual(["durationMs", "method", "path", "status"]);
    expect(context).toMatchObject({ method: "GET", path: "/memoires", status: 404 });
  });
});
