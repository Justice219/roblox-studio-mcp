/**
 * Shared TypeScript interfaces for the Roblox Studio MCP Bridge.
 *
 * These types define the contract between the MCP server, the HTTP bridge,
 * and the Roblox Studio plugin. The command lifecycle is:
 *
 *   1. MCP tool handler creates a PendingCommand and enqueues it
 *   2. HTTP bridge serves the command to the plugin via GET /poll
 *   3. Plugin executes the command and POSTs a CommandResult via POST /result
 *   4. The queue resolves the pending promise, returning data to the MCP tool
 *
 * @example
 * // A PendingCommand for creating an instance:
 * {
 *   id: "a1b2c3d4-...",
 *   type: "create_instance",
 *   params: { className: "Part", parent: "game.Workspace", properties: { Name: "MyPart" } },
 *   resolve: (result) => ...,
 *   reject: (error) => ...,
 *   createdAt: 1700000000000
 * }
 */

/**
 * Represents a command that has been enqueued but not yet picked up by the plugin.
 * The resolve/reject callbacks are from the Promise returned to the MCP tool handler.
 */
export interface PendingCommand {
  /** Unique identifier for this command (UUID v4) */
  id: string;
  /** The command type — maps directly to MCP tool names */
  type: string;
  /** Parameters for the command, passed as-is to the plugin */
  params: Record<string, unknown>;
  /** Resolves the promise when the plugin returns a successful result */
  resolve: (result: CommandResult) => void;
  /** Rejects the promise if the command times out or the plugin returns an error */
  reject: (error: Error) => void;
  /** Timestamp (ms since epoch) when the command was enqueued — used for timeout */
  createdAt: number;
}

/**
 * The result returned by the Roblox Studio plugin after executing a command.
 * Sent as JSON via POST /result.
 */
export interface CommandResult {
  /** The command ID this result corresponds to */
  id: string;
  /** Whether the command executed successfully */
  success: boolean;
  /** The result data on success (structure depends on command type) */
  data?: unknown;
  /** Error message on failure */
  error?: string;
}

/**
 * A command as serialized for the plugin via GET /poll.
 * Does not include resolve/reject callbacks — those stay server-side.
 */
export interface SerializedCommand {
  /** Unique identifier — the plugin must include this in its result POST */
  id: string;
  /** The command type to dispatch in CommandRouter */
  type: string;
  /** Parameters for the command handler */
  params: Record<string, unknown>;
}

/**
 * Tracks the connection state of the Roblox Studio plugin.
 * Updated by heartbeat POSTs from the plugin.
 */
export interface ConnectionState {
  /** Whether the plugin is currently considered connected */
  connected: boolean;
  /** Timestamp of the last heartbeat received (ms since epoch) */
  lastHeartbeat: number;
  /** Plugin-reported version string, if provided */
  pluginVersion?: string;
  /** Plugin-reported Studio session ID, if provided */
  studioSessionId?: string;
}

/**
 * Configuration for the HTTP bridge server.
 */
export interface BridgeConfig {
  /** Port to bind the Express server on (default: 3001) */
  port: number;
  /** Host to bind to — should always be 127.0.0.1 for security */
  host: string;
  /** How long (ms) before a command times out waiting for plugin response */
  commandTimeoutMs: number;
  /** How long (ms) after last heartbeat before considering plugin disconnected */
  heartbeatTimeoutMs: number;
}

/**
 * Default bridge configuration values.
 * Binds to localhost only for security — never expose to network.
 *
 * @example
 * const config: BridgeConfig = { ...DEFAULT_BRIDGE_CONFIG, port: 4000 };
 */
export const DEFAULT_BRIDGE_CONFIG: BridgeConfig = {
  port: 3001,
  host: "127.0.0.1",
  commandTimeoutMs: 30_000,
  heartbeatTimeoutMs: 10_000,
};

/**
 * All supported command types. Maps 1:1 with MCP tool names.
 * The plugin's CommandRouter uses these to dispatch handlers.
 */
export const COMMAND_TYPES = [
  "get_descendants",
  "get_children",
  "get_properties",
  "find_instances",
  "get_services",
  "get_selection",
  "create_instance",
  "set_properties",
  "delete_instance",
  "clone_instance",
  "move_instance",
  "set_selection",
  "insert_service",
  "execute_luau",
] as const;

/** Union type of all valid command type strings */
export type CommandType = (typeof COMMAND_TYPES)[number];
