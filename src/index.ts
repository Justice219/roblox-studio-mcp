#!/usr/bin/env node
/**
 * Entry point for the Roblox Studio MCP Bridge.
 *
 * Wires together:
 *   1. CommandQueue — shared state between MCP server and HTTP bridge
 *   2. HttpBridge   — Express server on localhost:3001 for Studio plugin communication
 *   3. McpServer    — MCP protocol server on stdio for Claude Code communication
 *
 * Lifecycle:
 *   - HTTP bridge starts first (so the plugin can connect immediately)
 *   - MCP server connects to stdio transport
 *   - On SIGINT/SIGTERM, everything shuts down gracefully
 *
 * Usage:
 *   node dist/index.js
 *
 * Or via MCP config in Claude Code:
 *   { "command": "node", "args": ["/path/to/dist/index.js"] }
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CommandQueue } from "./command-queue.js";
import { HttpBridge } from "./http-bridge.js";
import { createMcpServer } from "./mcp-server.js";
import { DEFAULT_BRIDGE_CONFIG } from "./types.js";

/**
 * Main bootstrap function.
 * Initializes all components and sets up graceful shutdown.
 */
async function main(): Promise<void> {
  const config = { ...DEFAULT_BRIDGE_CONFIG };

  /* Allow port override via environment variable */
  if (process.env.MCP_BRIDGE_PORT) {
    const port = parseInt(process.env.MCP_BRIDGE_PORT, 10);
    if (!isNaN(port) && port > 0 && port < 65536) {
      config.port = port;
    }
  }

  /* 1. Create the shared command queue */
  const queue = new CommandQueue({
    commandTimeoutMs: config.commandTimeoutMs,
    heartbeatTimeoutMs: config.heartbeatTimeoutMs,
  });

  /* 2. Start the HTTP bridge (plugin communication) */
  const bridge = new HttpBridge(queue, config);
  await bridge.start();

  /* 3. Create and connect the MCP server (Claude Code communication) */
  const mcpServer = createMcpServer(queue);
  const transport = new StdioServerTransport();
  await mcpServer.connect(transport);

  console.error("[MCP Bridge] Roblox Studio MCP Bridge is running");
  console.error(
    `[MCP Bridge] HTTP bridge: http://${config.host}:${config.port}`
  );
  console.error("[MCP Bridge] MCP server: connected via stdio");
  console.error(
    "[MCP Bridge] Waiting for Studio plugin to connect via heartbeat..."
  );

  /**
   * Graceful shutdown handler.
   * Closes the HTTP bridge, drains the command queue, and exits.
   */
  const shutdown = async (): Promise<void> => {
    console.error("\n[MCP Bridge] Shutting down...");
    queue.shutdown();
    await bridge.stop();
    await mcpServer.close();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

/* Run and handle fatal errors */
main().catch((err) => {
  console.error("[MCP Bridge] Fatal error:", err);
  process.exit(1);
});
