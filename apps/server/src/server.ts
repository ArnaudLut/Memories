import { createServer, type Server } from "node:http";
import { type Config, describeError, type Logger, type Pool } from "@memoire/core";

interface Health {
  status: "ok" | "degraded";
  version: string;
  env: string;
  checks: { database: "ok" | "error"; migrations: string | null };
}

/**
 * Une seule requête répond aux deux questions : la base est-elle joignable,
 * et quelle est la dernière migration appliquée.
 */
const HEALTH_QUERY = {
  text: "select max(version) as version from meta.schema_migrations",
  // Délai que node-postgres applique à cette requête, côté client. Une base
  // qui a accepté la connexion puis se tait donne ainsi une réponse
  // « degraded » au lieu d'une requête HTTP sans fin, et la connexion muette
  // est détruite.
  query_timeout: 3000,
};

async function checkHealth(pool: Pool, config: Config, logger: Logger): Promise<Health> {
  const identity = { version: config.version, env: config.appEnv };
  try {
    const { rows } = await pool.query<{ version: string | null }>(HEALTH_QUERY);
    return {
      status: "ok",
      ...identity,
      checks: { database: "ok", migrations: rows[0]?.version ?? null },
    };
  } catch (error) {
    logger.warn("health.database_check_failed", { error: describeError(error) });
    return { status: "degraded", ...identity, checks: { database: "error", migrations: null } };
  }
}

export function createHealthServer(options: {
  pool: Pool;
  config: Config;
  logger: Logger;
}): Server {
  const { pool, config, logger } = options;
  return createServer(async (request, response) => {
    const startedAt = performance.now();
    const method = request.method ?? "";
    // Le chemin est journalisé sans sa chaîne de requête, et rien d'autre de la
    // requête ne l'est : ni en-tête, ni adresse.
    const path = (request.url ?? "").split("?", 1)[0] ?? "";

    let status = 404;
    let body: object = { error: "not_found" };
    if (path === "/health" && (method === "GET" || method === "HEAD")) {
      const health = await checkHealth(pool, config, logger);
      status = health.status === "ok" ? 200 : 503;
      body = health;
    } else if (path === "/health") {
      status = 405;
      body = { error: "method_not_allowed" };
      response.setHeader("allow", "GET, HEAD");
    }
    response.writeHead(status, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify(body));

    // Docker interroge /health toutes les dix secondes : ses succès noieraient
    // le journal.
    if (path !== "/health" || status !== 200) {
      const durationMs = Math.round(performance.now() - startedAt);
      logger.info("http.request", { method, path, status, durationMs });
    }
  });
}
