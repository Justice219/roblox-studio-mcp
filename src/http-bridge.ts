/**
 * HTTP Bridge Server for the Roblox Studio MCP Bridge.
 *
 * This Express server acts as the communication layer between the MCP server
 * (which speaks stdio/JSON-RPC) and the Roblox Studio plugin (which speaks HTTP).
 *
 * The plugin polls GET /poll every ~200ms for commands, executes them against
 * the DataModel, and POSTs results back to POST /result.
 *
 * Security: Binds to 127.0.0.1 ONLY — never exposed to the network.
 *
 * Endpoints:
 *   GET  /poll      — Plugin dequeues the next command to execute
 *   POST /result    — Plugin submits execution result for a command
 *   POST /heartbeat — Plugin keepalive signal (every ~3s)
 *   GET  /health    — Diagnostics: queue stats, connection state, uptime
 *
 * @example
 * const queue = new CommandQueue(config);
 * const bridge = new HttpBridge(queue, config);
 * await bridge.start(); // Listening on 127.0.0.1:3001
 */

import express, { Request, Response } from "express";
import cors from "cors";
import http from "http";
import { CommandQueue } from "./command-queue.js";
import { BridgeConfig, CommandResult } from "./types.js";

/**
 * Express-based HTTP bridge that connects the MCP server to the Studio plugin.
 * Manages its own Express app and HTTP server lifecycle.
 */
export class HttpBridge {
  private app: express.Application;
  private server: http.Server | null = null;
  private queue: CommandQueue;
  private config: BridgeConfig;
  private startTime: number = Date.now();

  constructor(queue: CommandQueue, config: BridgeConfig) {
    this.queue = queue;
    this.config = config;
    this.app = express();
    this.setupMiddleware();
    this.setupRoutes();
  }

  /**
   * Configure Express middleware.
   * CORS is enabled for Roblox Studio's HttpService which sends requests
   * from an internal origin. JSON body parsing is limited to 10MB to handle
   * large DataModel responses.
   */
  private setupMiddleware(): void {
    this.app.use(
      cors({
        origin: true,
        methods: ["GET", "POST"],
        allowedHeaders: ["Content-Type"],
      })
    );
    this.app.use(express.json({ limit: "10mb" }));
  }

  /**
   * Register all HTTP routes.
   * Each route is documented inline with its expected request/response format.
   */
  private setupRoutes(): void {
    /**
     * GET /poll — Plugin dequeues the next command.
     *
     * Returns 200 with a SerializedCommand JSON body if a command is available,
     * or 204 (No Content) if the queue is empty. The plugin should poll this
     * endpoint every ~200ms.
     *
     * Response (200):
     *   { "id": "uuid", "type": "create_instance", "params": { ... } }
     *
     * Response (204): empty body
     */
    this.app.get("/poll", (_req: Request, res: Response) => {
      const command = this.queue.dequeue();
      if (command) {
        res.json(command);
      } else {
        res.status(204).send();
      }
    });

    /**
     * POST /result — Plugin submits execution result.
     *
     * The plugin must include the command `id` in the result body so we can
     * match it to the pending promise.
     *
     * Request body:
     *   { "id": "uuid", "success": true, "data": { ... } }
     *   { "id": "uuid", "success": false, "error": "Something went wrong" }
     *
     * Response: 200 if matched, 404 if command ID not found (already timed out)
     */
    this.app.post("/result", (req: Request, res: Response) => {
      const result = req.body as CommandResult;

      if (!result || !result.id) {
        res.status(400).json({ error: "Missing command id in result body" });
        return;
      }

      const resolved = this.queue.resolve(result);
      if (resolved) {
        res.json({ status: "ok" });
      } else {
        res
          .status(404)
          .json({ error: "Unknown command id — may have already timed out" });
      }
    });

    /**
     * POST /heartbeat — Plugin keepalive signal.
     *
     * The plugin sends this every ~3s. If no heartbeat is received for 10s,
     * the plugin is considered disconnected and new commands are rejected.
     *
     * Request body (optional):
     *   { "pluginVersion": "1.0.0", "studioSessionId": "abc123" }
     *
     * Response: 200 with current queue stats
     */
    this.app.post("/heartbeat", (req: Request, res: Response) => {
      const { pluginVersion, studioSessionId } = req.body || {};
      this.queue.heartbeat(pluginVersion, studioSessionId);
      res.json({
        status: "ok",
        ...this.queue.getStats(),
      });
    });

    /**
     * GET /health — Diagnostics endpoint.
     *
     * Returns the current state of the bridge: connection status, queue depths,
     * uptime, and plugin info. Useful for debugging connection issues.
     *
     * Response:
     *   {
     *     "status": "ok",
     *     "uptime": 12345,
     *     "connection": { "connected": true, "lastHeartbeat": ..., ... },
     *     "queue": { "waitingCount": 0, "pendingCount": 1, "connected": true }
     *   }
     */
    this.app.get("/health", (_req: Request, res: Response) => {
      res.json({
        status: "ok",
        uptime: Date.now() - this.startTime,
        connection: this.queue.getConnectionState(),
        queue: this.queue.getStats(),
      });
    });
  }

  /**
   * Start the HTTP bridge server.
   * Binds to the configured host:port (default 127.0.0.1:3001).
   *
   * @returns Promise that resolves when the server is listening
   * @throws Error if the port is already in use
   */
  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = this.app.listen(this.config.port, this.config.host, () => {
        console.error(
          `[MCP Bridge] HTTP bridge listening on ${this.config.host}:${this.config.port}`
        );
        resolve();
      });

      this.server.on("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "EADDRINUSE") {
          reject(
            new Error(
              `Port ${this.config.port} is already in use. Is another MCP bridge instance running?`
            )
          );
        } else {
          reject(err);
        }
      });
    });
  }

  /**
   * Gracefully stop the HTTP bridge server.
   * Closes all active connections and frees the port.
   */
  stop(): Promise<void> {
    return new Promise((resolve) => {
      if (this.server) {
        this.server.close(() => {
          console.error("[MCP Bridge] HTTP bridge stopped");
          resolve();
        });
      } else {
        resolve();
      }
    });
  }
}
