/**
 * Promise-based command queue for the Roblox Studio MCP Bridge.
 *
 * Commands flow through this queue in a producer-consumer pattern:
 *   - MCP tool handlers ENQUEUE commands (producer) and receive a Promise
 *   - The HTTP bridge DEQUEUES commands for the plugin via GET /poll (consumer)
 *   - The HTTP bridge RESOLVES commands when the plugin POSTs results
 *
 * Each command has a configurable timeout (default 30s). If the plugin doesn't
 * respond in time, the promise is rejected with a timeout error.
 *
 * The queue also tracks connection state via heartbeats. Commands are rejected
 * immediately if the plugin is disconnected, avoiding a 30s wait.
 *
 * @example
 * const queue = new CommandQueue({ commandTimeoutMs: 30000, heartbeatTimeoutMs: 10000 });
 * // MCP handler enqueues a command:
 * const result = await queue.enqueue("get_children", { path: "game.Workspace" });
 * // Meanwhile, HTTP bridge polls and resolves:
 * const cmd = queue.dequeue(); // returns SerializedCommand or null
 * queue.resolve({ id: cmd.id, success: true, data: [...] });
 */

import { v4 as uuidv4 } from "uuid";
import {
  PendingCommand,
  CommandResult,
  SerializedCommand,
  ConnectionState,
} from "./types.js";

/**
 * Configuration subset needed by the command queue.
 */
interface QueueConfig {
  /** How long (ms) before a command times out (default: 30000) */
  commandTimeoutMs: number;
  /** How long (ms) after last heartbeat before plugin is considered disconnected */
  heartbeatTimeoutMs: number;
}

/**
 * Manages the lifecycle of commands sent to the Roblox Studio plugin.
 * Thread-safe for single-threaded Node.js — no mutex needed.
 */
export class CommandQueue {
  /** Commands waiting to be picked up by the plugin (FIFO order) */
  private waitingQueue: PendingCommand[] = [];

  /** Commands that have been sent to the plugin but not yet resolved */
  private pendingCommands: Map<string, PendingCommand> = new Map();

  /** Plugin connection state — updated by heartbeat calls */
  private connectionState: ConnectionState = {
    connected: false,
    lastHeartbeat: 0,
  };

  /** Interval handle for the timeout sweep timer */
  private timeoutInterval: ReturnType<typeof setInterval> | null = null;

  private config: QueueConfig;

  constructor(config: QueueConfig) {
    this.config = config;
    this.startTimeoutSweep();
  }

  /**
   * Enqueue a command and return a Promise that resolves when the plugin responds.
   * Rejects immediately if the plugin is not connected.
   *
   * @param type - The command type (e.g. "create_instance")
   * @param params - Parameters to send to the plugin
   * @returns Promise that resolves with the CommandResult from the plugin
   * @throws Error if the plugin is disconnected or the command times out
   *
   * @example
   * const result = await queue.enqueue("get_children", { path: "game.Workspace" });
   * console.log(result.data); // [{ name: "Baseplate", className: "Part" }, ...]
   */
  enqueue(
    type: string,
    params: Record<string, unknown>
  ): Promise<CommandResult> {
    /* Reject immediately if Studio is not connected — no point waiting 30s */
    if (!this.isConnected()) {
      return Promise.reject(
        new Error(
          "Roblox Studio plugin is not connected. Open Studio and ensure the MCP Bridge plugin is running."
        )
      );
    }

    return new Promise<CommandResult>((resolve, reject) => {
      const command: PendingCommand = {
        id: uuidv4(),
        type,
        params,
        resolve,
        reject,
        createdAt: Date.now(),
      };

      this.waitingQueue.push(command);
    });
  }

  /**
   * Dequeue the next command for the plugin to execute.
   * Called by the HTTP bridge's GET /poll endpoint.
   * Moves the command from the waiting queue to the pending map.
   *
   * @returns The next command as a SerializedCommand, or null if the queue is empty
   */
  dequeue(): SerializedCommand | null {
    const command = this.waitingQueue.shift();
    if (!command) return null;

    /* Move to pending — we're now waiting for the plugin's result */
    this.pendingCommands.set(command.id, command);

    return {
      id: command.id,
      type: command.type,
      params: command.params,
    };
  }

  /**
   * Resolve a pending command with the plugin's result.
   * Called by the HTTP bridge's POST /result endpoint.
   *
   * @param result - The result from the plugin
   * @returns true if the command was found and resolved, false if unknown ID
   */
  resolve(result: CommandResult): boolean {
    const command = this.pendingCommands.get(result.id);
    if (!command) return false;

    this.pendingCommands.delete(result.id);
    command.resolve(result);
    return true;
  }

  /**
   * Record a heartbeat from the plugin, updating connection state.
   * Called by the HTTP bridge's POST /heartbeat endpoint.
   *
   * @param pluginVersion - Optional version string reported by the plugin
   * @param studioSessionId - Optional session ID from the plugin
   */
  heartbeat(pluginVersion?: string, studioSessionId?: string): void {
    this.connectionState = {
      connected: true,
      lastHeartbeat: Date.now(),
      pluginVersion,
      studioSessionId,
    };
  }

  /**
   * Check whether the plugin is currently connected.
   * A plugin is "connected" if we've received a heartbeat within the timeout window.
   *
   * @returns true if the plugin is connected and responsive
   */
  isConnected(): boolean {
    if (!this.connectionState.connected) return false;
    const elapsed = Date.now() - this.connectionState.lastHeartbeat;
    return elapsed < this.config.heartbeatTimeoutMs;
  }

  /**
   * Get the current connection state (for diagnostics / health endpoint).
   */
  getConnectionState(): ConnectionState {
    return {
      ...this.connectionState,
      connected: this.isConnected(),
    };
  }

  /**
   * Get queue statistics for the health endpoint.
   */
  getStats(): {
    waitingCount: number;
    pendingCount: number;
    connected: boolean;
  } {
    return {
      waitingCount: this.waitingQueue.length,
      pendingCount: this.pendingCommands.size,
      connected: this.isConnected(),
    };
  }

  /**
   * Starts a periodic sweep that rejects commands that have exceeded their timeout.
   * Runs every second. Commands in both the waiting queue and pending map are checked.
   */
  private startTimeoutSweep(): void {
    this.timeoutInterval = setInterval(() => {
      const now = Date.now();

      /* Sweep waiting queue — reject commands that have been waiting too long */
      const expiredWaiting: PendingCommand[] = [];
      this.waitingQueue = this.waitingQueue.filter((cmd) => {
        if (now - cmd.createdAt > this.config.commandTimeoutMs) {
          expiredWaiting.push(cmd);
          return false;
        }
        return true;
      });
      for (const cmd of expiredWaiting) {
        cmd.reject(
          new Error(
            `Command '${cmd.type}' timed out after ${this.config.commandTimeoutMs}ms — plugin never picked it up`
          )
        );
      }

      /* Sweep pending map — reject commands the plugin picked up but didn't respond to */
      for (const [id, cmd] of this.pendingCommands) {
        if (now - cmd.createdAt > this.config.commandTimeoutMs) {
          this.pendingCommands.delete(id);
          cmd.reject(
            new Error(
              `Command '${cmd.type}' timed out after ${this.config.commandTimeoutMs}ms — plugin did not return a result`
            )
          );
        }
      }
    }, 1000);
  }

  /**
   * Clean shutdown — clears the timeout sweep and rejects all pending commands.
   * Call this when the MCP server is shutting down.
   */
  shutdown(): void {
    if (this.timeoutInterval) {
      clearInterval(this.timeoutInterval);
      this.timeoutInterval = null;
    }

    /* Reject all waiting commands */
    for (const cmd of this.waitingQueue) {
      cmd.reject(new Error("MCP server shutting down"));
    }
    this.waitingQueue = [];

    /* Reject all pending commands */
    for (const [, cmd] of this.pendingCommands) {
      cmd.reject(new Error("MCP server shutting down"));
    }
    this.pendingCommands.clear();
  }
}
