import { rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Signe de vie du worker : un fichier qu'il réécrit à intervalle régulier et
 * dont la commande de contrôle de santé lit l'âge. Aucun port n'est ouvert.
 * Dans le conteneur, le répertoire temporaire est en mémoire : le fichier
 * disparaît avec le conteneur.
 */
export const LIVENESS_FILE = join(tmpdir(), "memoire-worker.alive");
export const LIVENESS_INTERVAL_MS = 10_000;
/** Trois signes de vie manqués : le worker est tenu pour bloqué. */
export const LIVENESS_MAX_AGE_MS = 30_000;

export async function markAlive(file: string): Promise<void> {
  await writeFile(file, `${new Date().toISOString()}\n`);
}

export async function clearAlive(file: string): Promise<void> {
  await rm(file, { force: true });
}

export async function isAlive(file: string, now: number = Date.now()): Promise<boolean> {
  try {
    return now - (await stat(file)).mtimeMs < LIVENESS_MAX_AGE_MS;
  } catch {
    return false;
  }
}
