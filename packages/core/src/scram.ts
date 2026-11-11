import { createHash, createHmac, pbkdf2Sync, randomBytes } from "node:crypto";

// Valeurs que PostgreSQL emploie lui-même quand il chiffre un mot de passe.
const ITERATIONS = 4096;
const SALT_LENGTH = 16;
const KEY_LENGTH = 32;

/**
 * Calcule le vérificateur SCRAM-SHA-256 d'un mot de passe (RFC 5802 et 7677),
 * sous la forme que PostgreSQL enregistre telle quelle dans ALTER ROLE. Le mot
 * de passe en clair ne quitte ainsi jamais le processus.
 */
export function scramSha256Verifier(
  password: string,
  salt: Buffer = randomBytes(SALT_LENGTH),
): string {
  // SCRAM normalise les mots de passe (SASLprep). En ASCII imprimable, cette
  // normalisation ne change rien : s'y tenir dispense de l'implémenter.
  if (!/^[\x20-\x7e]+$/.test(password)) {
    throw new Error("Un mot de passe de rôle SQL doit être en ASCII imprimable et non vide.");
  }
  const saltedPassword = pbkdf2Sync(password, salt, ITERATIONS, KEY_LENGTH, "sha256");
  const clientKey = createHmac("sha256", saltedPassword).update("Client Key").digest();
  const storedKey = createHash("sha256").update(clientKey).digest("base64");
  const serverKey = createHmac("sha256", saltedPassword).update("Server Key").digest("base64");
  return `SCRAM-SHA-256$${ITERATIONS}:${salt.toString("base64")}$${storedKey}:${serverKey}`;
}
