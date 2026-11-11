import {
  createLogger,
  describeError,
  loadConfig,
  onShutdownSignal,
  roleCredentials,
} from "@memoire/core";
import { LIVENESS_FILE } from "./liveness.js";
import { startWorker } from "./worker.js";

const logger = createLogger({
  service: "worker",
  env: process.env.APP_ENV ?? "unknown",
  version: process.env.APP_VERSION ?? "unknown",
});

try {
  const config = loadConfig(process.env);
  const worker = await startWorker({
    database: config.database,
    credentials: roleCredentials(process.env, "queue"),
    logger,
    livenessFile: LIVENESS_FILE,
  });

  onShutdownSignal((signal) => {
    logger.info("worker.stopping", { signal });
    worker.stop().catch((error: unknown) => {
      logger.error("worker.stop_failed", { error: describeError(error) });
      process.exitCode = 1;
    });
  });
} catch (error) {
  logger.error("worker.failed", { error: describeError(error) });
  process.exitCode = 1;
}
