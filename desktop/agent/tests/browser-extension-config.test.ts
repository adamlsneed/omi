import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(join(__dirname, "../src/index.ts"), "utf8");

describe("browser extension MCP config", () => {
  it("passes extension mode through to the Playwright MCP child process", () => {
    expect(indexSource).toContain('playwrightArgs.push("--extension")');
    expect(indexSource).toContain('name: "PLAYWRIGHT_MCP_EXTENSION"');
    expect(indexSource).toContain('name: "PLAYWRIGHT_MCP_EXTENSION_TOKEN"');
  });
});
