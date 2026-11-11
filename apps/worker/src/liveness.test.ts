import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { clearAlive, isAlive, LIVENESS_MAX_AGE_MS, markAlive } from "./liveness.js";

let directory: string;
let file: string;

beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), "memoire-liveness-"));
  file = join(directory, "worker.alive");
});

afterEach(() => {
  rmSync(directory, { recursive: true });
});

describe("signe de vie du worker", () => {
  it("est absent tant que le worker n'a rien écrit", async () => {
    expect(await isAlive(file)).toBe(false);
  });

  it("vaut pendant trente secondes après la dernière écriture", async () => {
    await markAlive(file);
    const writtenAt = Date.now();
    expect(await isAlive(file)).toBe(true);
    expect(await isAlive(file, writtenAt + LIVENESS_MAX_AGE_MS - 1000)).toBe(true);
    expect(await isAlive(file, writtenAt + LIVENESS_MAX_AGE_MS + 1000)).toBe(false);
  });

  it("disparaît à l'arrêt du worker", async () => {
    await markAlive(file);
    await clearAlive(file);
    expect(await isAlive(file)).toBe(false);
    await expect(clearAlive(file)).resolves.toBeUndefined();
  });
});
