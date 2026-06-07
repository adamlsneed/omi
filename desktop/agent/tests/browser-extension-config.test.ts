import { describe, expect, it } from "vitest";
import { buildMcpServers } from "../src/mcp-servers.js";

const baseDeps = {
  omiToolsPipePath: "/tmp/omi-bridge.sock",
  omiToolsStdioScript: "/fake/omi-tools-stdio.js",
  playwrightCli: "/fake/playwright/cli.js",
};

function playwrightServer(env: NodeJS.ProcessEnv) {
  const pw = buildMcpServers({ ...baseDeps, env }, "act").find((s) => s.name === "playwright");
  if (!pw) throw new Error("playwright MCP server was not built");
  return pw;
}

describe("buildMcpServers: Playwright browser-extension wiring", () => {
  it("does not enable the extension by default", () => {
    const pw = playwrightServer({});
    expect(pw.args).not.toContain("--extension");
    expect(pw.env.map((e) => e.name)).not.toContain("PLAYWRIGHT_MCP_EXTENSION");
  });

  it("enables the extension when PLAYWRIGHT_USE_EXTENSION=true", () => {
    const pw = playwrightServer({ PLAYWRIGHT_USE_EXTENSION: "true" });
    expect(pw.args).toContain("--extension");
    expect(pw.env).toContainEqual({ name: "PLAYWRIGHT_MCP_EXTENSION", value: "true" });
  });

  it("accepts the PLAYWRIGHT_MCP_EXTENSION alias", () => {
    const pw = playwrightServer({ PLAYWRIGHT_MCP_EXTENSION: "true" });
    expect(pw.args).toContain("--extension");
  });

  it("forwards the extension token when provided", () => {
    const pw = playwrightServer({
      PLAYWRIGHT_USE_EXTENSION: "true",
      PLAYWRIGHT_MCP_EXTENSION_TOKEN: "secret-token",
    });
    expect(pw.env).toContainEqual({ name: "PLAYWRIGHT_MCP_EXTENSION_TOKEN", value: "secret-token" });
  });

  it("omits the extension token when it is not set", () => {
    const pw = playwrightServer({ PLAYWRIGHT_USE_EXTENSION: "true" });
    expect(pw.env.map((e) => e.name)).not.toContain("PLAYWRIGHT_MCP_EXTENSION_TOKEN");
  });
});
