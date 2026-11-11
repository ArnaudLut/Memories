import { isAlive, LIVENESS_FILE, LIVENESS_MAX_AGE_MS } from "./liveness.js";

if (!(await isAlive(LIVENESS_FILE))) {
  const seconds = LIVENESS_MAX_AGE_MS / 1000;
  process.stderr.write(
    `Le worker n'a donné aucun signe de vie au cours des ${seconds} dernières secondes.\n`,
  );
  process.exitCode = 1;
}
