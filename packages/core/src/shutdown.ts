/**
 * Appelle stop au premier SIGTERM ou SIGINT. Un second signal retrouve son
 * effet par défaut et arrête le processus sans attendre.
 */
export function onShutdownSignal(stop: (signal: NodeJS.Signals) => void): void {
  const handle = (signal: NodeJS.Signals) => {
    process.off("SIGTERM", handle);
    process.off("SIGINT", handle);
    stop(signal);
  };
  process.on("SIGTERM", handle);
  process.on("SIGINT", handle);
}
