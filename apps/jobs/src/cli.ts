import { createLogger } from "@memoire/core";
import { EXIT_INVALID_CONFIGURATION, JOB_NAMES, type JobName, runJob } from "./jobs.js";

const [name, ...rest] = process.argv.slice(2);

if (name === undefined || rest.length > 0 || !JOB_NAMES.includes(name as JobName)) {
  process.stderr.write(`Usage : node apps/jobs/dist/cli.js <${JOB_NAMES.join("|")}>\n`);
  process.exitCode = EXIT_INVALID_CONFIGURATION;
} else {
  // Le journal part sur la sortie d'erreur : la sortie standard est réservée
  // au résultat du job, que la chaîne de déploiement transmet tel quel.
  const logger = createLogger({
    service: "jobs",
    env: process.env.APP_ENV ?? "unknown",
    version: process.env.APP_VERSION ?? "unknown",
    write: (line) => process.stderr.write(line),
  });
  process.exitCode = await runJob(name as JobName, {
    env: process.env,
    logger,
    print: (text) => process.stdout.write(text),
  });
}
