// MCP server config builder. Extracted from index.ts so the wiring (especially
// the Playwright browser-extension flags) can be tested without importing the
// bridge entry point, which runs main() on import.

export type McpServerConfig = {
  name: string;
  command: string;
  args: string[];
  env: Array<{ name: string; value: string }>;
};

export interface McpServerDeps {
  omiToolsPipePath: string;
  omiToolsStdioScript: string;
  playwrightCli: string;
  // Overridable for tests; defaults to process.env at call time.
  env?: NodeJS.ProcessEnv;
}

export function buildMcpServers(
  deps: McpServerDeps,
  mode: string,
  cwd?: string,
  sessionKey?: string
): McpServerConfig[] {
  const env = deps.env ?? process.env;
  const servers: McpServerConfig[] = [];

  // omi-tools (stdio, connects back via Unix socket)
  const omiToolsEnv: Array<{ name: string; value: string }> = [
    { name: "OMI_BRIDGE_PIPE", value: deps.omiToolsPipePath },
    { name: "OMI_QUERY_MODE", value: mode },
  ];
  if (cwd) {
    omiToolsEnv.push({ name: "OMI_WORKSPACE", value: cwd });
  }
  if (sessionKey === "onboarding") {
    omiToolsEnv.push({ name: "OMI_ONBOARDING", value: "true" });
  }
  servers.push({
    name: "omi-tools",
    command: process.execPath,
    args: [deps.omiToolsStdioScript],
    env: omiToolsEnv,
  });

  // Playwright MCP server
  const playwrightArgs = [deps.playwrightCli];
  const usePlaywrightExtension =
    env.PLAYWRIGHT_USE_EXTENSION === "true" ||
    env.PLAYWRIGHT_MCP_EXTENSION === "true";
  const playwrightEnv: Array<{ name: string; value: string }> = [];
  if (usePlaywrightExtension) {
    playwrightArgs.push("--extension");
    playwrightEnv.push({
      name: "PLAYWRIGHT_MCP_EXTENSION",
      value: "true",
    });
  }
  if (env.PLAYWRIGHT_MCP_EXTENSION_TOKEN) {
    playwrightEnv.push({
      name: "PLAYWRIGHT_MCP_EXTENSION_TOKEN",
      value: env.PLAYWRIGHT_MCP_EXTENSION_TOKEN,
    });
  }
  servers.push({
    name: "playwright",
    command: process.execPath,
    args: playwrightArgs,
    env: playwrightEnv,
  });

  return servers;
}
