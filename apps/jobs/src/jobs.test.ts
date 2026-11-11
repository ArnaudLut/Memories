import { describe, expect, it } from "vitest";
import { memoryLogger } from "../../../packages/core/src/testing.js";
import { EXIT_INVALID_CONFIGURATION, JOB_NAMES, runJob } from "./jobs.js";

describe("runJob", () => {
  it("connaît les trois jobs de l'image", () => {
    expect(JOB_NAMES).toEqual(["migrate", "db-bootstrap", "verify"]);
  });

  it.each(JOB_NAMES)("« %s » sort avec le code 2 quand la configuration manque", async (name) => {
    const logger = memoryLogger();
    const printed: string[] = [];
    const code = await runJob(name, { env: {}, logger, print: (text) => printed.push(text) });
    expect(code).toBe(EXIT_INVALID_CONFIGURATION);
    expect(printed).toEqual([]);
    expect(logger.entries).toMatchObject([
      {
        level: "error",
        event: "job.failed",
        context: { job: name, error: { name: "ConfigError" } },
      },
    ]);
  });
});
