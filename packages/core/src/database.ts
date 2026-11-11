import { Client, Pool, type PoolClient } from "pg";
import type { Credentials, DatabaseConfig } from "./config.js";
import { describeError, type Logger } from "./logger.js";

// Sous le délai de cinq secondes des contrôles de santé : une base injoignable
// donne une réponse « degraded » plutôt qu'un silence.
const CONNECTION_TIMEOUT_MS = 3000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Options de connexion communes à node-postgres et à pg-boss. */
export function connectionOptions(database: DatabaseConfig, credentials: Credentials) {
  return {
    host: database.host,
    port: database.port,
    database: database.name,
    user: credentials.user,
    password: credentials.password,
    // Équivalent de verify-full : la chaîne de certificats et le nom d'hôte du
    // serveur sont vérifiés.
    ssl: database.tls ? { ca: database.tls.ca, rejectUnauthorized: true } : false,
    connectionTimeoutMillis: CONNECTION_TIMEOUT_MS,
  };
}

// Une connexion perdue fait échouer la requête en cours ou la suivante. Elle
// émet aussi un événement « error » qui, sans écouteur, arrêterait le processus
// avant que cet échec soit traité.
function ignoreConnectionError(): void {}

export function createPool(
  database: DatabaseConfig,
  credentials: Credentials,
  options: { max: number; logger: Logger },
): Pool {
  const pool = new Pool({ ...connectionOptions(database, credentials), max: options.max });
  pool.on("error", (error) => {
    options.logger.warn("database.idle_connection_lost", { error: describeError(error) });
  });
  return pool;
}

/** Ouvre une session unique, pour les travaux qui ont besoin d'un état de session. */
export async function connect(database: DatabaseConfig, credentials: Credentials): Promise<Client> {
  const client = new Client(connectionOptions(database, credentials));
  client.on("error", ignoreConnectionError);
  await client.connect();
  return client;
}

/**
 * Exécute fn dans une transaction dont le tenant est tenantId. Le contexte est
 * local à la transaction : il disparaît avec elle et ne peut pas fuir vers la
 * requête suivante de la même connexion.
 */
export async function withTenant<T>(
  pool: Pool,
  tenantId: string,
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  if (!UUID_PATTERN.test(tenantId)) {
    throw new TypeError("L'identifiant de tenant doit être un UUID.");
  }
  const client = await pool.connect();
  client.on("error", ignoreConnectionError);
  let unusable = false;
  try {
    await client.query("begin");
    await client.query("select set_config('app.tenant_id', $1, true)", [tenantId]);
    const result = await fn(client);
    // PostgreSQL répond ROLLBACK, sans erreur, au COMMIT d'une transaction où
    // une requête a échoué : un échec que fn aurait ignoré est signalé ici.
    const { command } = await client.query("commit");
    if (command !== "COMMIT") {
      throw new Error(
        "La transaction du tenant a été annulée par PostgreSQL : une requête y avait échoué.",
      );
    }
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => {
      unusable = true;
    });
    throw error;
  } finally {
    client.off("error", ignoreConnectionError);
    // Une connexion dont la transaction n'a pas pu être annulée est détruite
    // au lieu de retourner dans le pool.
    client.release(unusable);
  }
}
