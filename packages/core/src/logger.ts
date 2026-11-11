export type LogContext = Readonly<Record<string, unknown>>;

export interface Logger {
  info(event: string, context?: LogContext): void;
  warn(event: string, context?: LogContext): void;
  error(event: string, context?: LogContext): void;
}

export interface LoggerOptions {
  service: string;
  env: string;
  version: string;
  /** Destination des lignes : la sortie standard, sauf indication contraire. */
  write?: (line: string) => void;
}

/**
 * Journal structuré : un objet JSON par ligne. Le contexte ne doit contenir ni
 * secret ni donnée personnelle.
 */
export function createLogger(options: LoggerOptions): Logger {
  const { service, env, version } = options;
  const write = options.write ?? ((line: string) => process.stdout.write(line));
  const log =
    (level: string) =>
    (event: string, context: LogContext = {}) => {
      const fixed = { ts: new Date().toISOString(), level, service, env, version, event };
      // Les champs fixes viennent en tête et le contexte ne peut pas les remplacer.
      write(`${JSON.stringify({ ...fixed, ...context, ...fixed })}\n`);
    };
  return { info: log("info"), warn: log("warn"), error: log("error") };
}

export interface ErrorDescription {
  name: string;
  message: string;
  code?: string;
  cause?: ErrorDescription;
}

/**
 * Ce qu'une erreur a d'utile dans un journal : son nom, son message, son code.
 * Les champs sont lus sur tout objet, car pg-boss transmet parfois une copie de
 * l'erreur plutôt que l'erreur elle-même.
 */
export function describeError(error: unknown): ErrorDescription {
  if (typeof error !== "object" || error === null) {
    return { name: "Error", message: String(error) };
  }
  const { name, message, code, cause, errors } = error as Record<string, unknown>;
  const description: ErrorDescription = {
    name: typeof name === "string" ? name : "Error",
    message: typeof message === "string" ? message : "",
  };
  // Une connexion refusée sur plusieurs adresses arrive sous la forme d'une
  // erreur groupée dont le message est vide.
  if (description.message === "" && Array.isArray(errors)) {
    description.message = errors.map((inner) => describeError(inner).message).join(" ; ");
  }
  if (typeof code === "string") {
    description.code = code;
  }
  if (cause !== undefined) {
    description.cause = describeError(cause);
  }
  return description;
}
