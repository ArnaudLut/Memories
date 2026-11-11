import {
  createLogger,
  createPool,
  describeError,
  loadConfig,
  onShutdownSignal,
  readPort,
  roleCredentials,
} from "@memoire/core";
import { createHealthServer } from "./server.js";

const DEFAULT_PORT = 8080;
// La limite de connexions du rôle app laisse deux instances cohabiter.
const POOL_SIZE = 10;
// Caddy garde deux minutes ses connexions inactives vers le service. Le serveur
// les garde plus longtemps que lui : sinon une requête non idempotente écrite à
// l'instant où Node ferme la connexion reçoit un 502.
const KEEP_ALIVE_TIMEOUT_MS = 125_000;
// Docker accorde dix secondes à un conteneur pour s'arrêter.
const STOP_TIMEOUT_MS = 5000;

const logger = createLogger({
  service: "server",
  env: process.env.APP_ENV ?? "unknown",
  version: process.env.APP_VERSION ?? "unknown",
});

try {
  const config = loadConfig(process.env);
  const port = readPort(process.env, "PORT", DEFAULT_PORT);
  const pool = createPool(config.database, roleCredentials(process.env, "app"), {
    max: POOL_SIZE,
    logger,
  });
  const server = createHealthServer({ pool, config, logger });
  server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, () => {
      // Passé le démarrage, une erreur du serveur n'a plus d'écouteur : elle
      // arrête le processus, que Docker relance.
      server.off("error", reject);
      resolve();
    });
  });
  logger.info("server.started", { port });

  onShutdownSignal((signal) => {
    logger.info("server.stopping", { signal });
    // Les requêtes en cours se terminent, puis le pool se ferme et le
    // processus s'arrête de lui-même. Les connexions encore ouvertes passé le
    // délai sont fermées d'office, avant que Docker ne tue le processus.
    server.close(() => void pool.end());
    setTimeout(() => server.closeAllConnections(), STOP_TIMEOUT_MS).unref();
  });
} catch (error) {
  logger.error("server.failed", { error: describeError(error) });
  process.exitCode = 1;
}
