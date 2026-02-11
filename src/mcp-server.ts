/**
 * MCP Server for the Roblox Studio Bridge.
 *
 * Defines 14 MCP tools that map 1:1 to commands executed by the Studio plugin.
 * Uses the @modelcontextprotocol/sdk with stdio transport so Claude Code can
 * communicate directly via JSON-RPC over stdin/stdout.
 *
 * Each tool:
 *   1. Validates input with a Zod schema
 *   2. Enqueues a command in the CommandQueue
 *   3. Awaits the plugin's response (or timeout)
 *   4. Returns the result as MCP tool output
 *
 * Tool Categories:
 *   - Read tools (6): get_descendants, get_children, get_properties,
 *                      find_instances, get_services, get_selection
 *   - Write tools (8): create_instance, set_properties, delete_instance,
 *                       clone_instance, move_instance, set_selection,
 *                       insert_service, execute_luau
 *
 * @example
 * const queue = new CommandQueue(config);
 * const server = createMcpServer(queue);
 * // The server is connected to stdio transport in index.ts
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { CommandQueue } from "./command-queue.js";

/**
 * Zod schema for serialized Roblox property values.
 * Properties can be primitives, or objects with a `_type` tag for
 * complex Roblox types (Vector3, CFrame, Color3, etc.).
 *
 * @example
 * // Primitive: { Name: "MyPart" }
 * // Tagged:    { Position: { _type: "Vector3", x: 0, y: 5, z: 0 } }
 * // Enum:     { Material: { _type: "Enum", enumType: "Material", value: "Plastic" } }
 */
const PropertyValueSchema = z.union([
  z.string(),
  z.number(),
  z.boolean(),
  z.null(),
  z.record(z.unknown()),
]);

/**
 * Zod schema for a map of property name → property value.
 * Used by create_instance and set_properties tools.
 */
const PropertiesSchema = z
  .record(z.string(), PropertyValueSchema)
  .optional()
  .describe(
    "Map of property names to values. Complex types use _type tags: " +
      '{ Position: { _type: "Vector3", x: 0, y: 5, z: 0 } }'
  );

/**
 * Create and configure the MCP server with all 14 tools registered.
 *
 * @param queue - The command queue shared with the HTTP bridge
 * @returns Configured McpServer instance ready to be connected to a transport
 */
export function createMcpServer(queue: CommandQueue): McpServer {
  const server = new McpServer({
    name: "roblox-studio-bridge",
    version: "1.0.0",
  });

  /* ─────────────────────────── READ TOOLS ─────────────────────────── */

  /**
   * Tool: get_descendants
   * Returns all descendants of an instance as a flat array with paths and classNames.
   * Useful for exploring a subtree of the DataModel.
   *
   * @param path - Dot-notation path (e.g. "game.Workspace")
   * @param maxDepth - Optional max depth limit to avoid huge responses
   */
  server.tool(
    "get_descendants",
    "Get all descendants of an instance at the given path, with their classNames and full paths",
    {
      path: z
        .string()
        .describe(
          'Dot-notation path to the instance (e.g. "game.Workspace", "game.ServerStorage.Items")'
        ),
      maxDepth: z
        .number()
        .optional()
        .describe("Maximum depth to traverse (default: unlimited)"),
    },
    async ({ path, maxDepth }) => {
      return executeCommand(queue, "get_descendants", { path, maxDepth });
    }
  );

  /**
   * Tool: get_children
   * Returns immediate children of an instance. Lighter than get_descendants
   * for exploring one level at a time.
   *
   * @param path - Dot-notation path to the parent instance
   */
  server.tool(
    "get_children",
    "Get immediate children of an instance at the given path",
    {
      path: z
        .string()
        .describe(
          'Dot-notation path to the parent (e.g. "game.Workspace")'
        ),
    },
    async ({ path }) => {
      return executeCommand(queue, "get_children", { path });
    }
  );

  /**
   * Tool: get_properties
   * Returns all readable properties of an instance, serialized with _type tags
   * for complex Roblox types.
   *
   * @param path - Dot-notation path to the instance
   * @param properties - Optional list of specific property names to read
   */
  server.tool(
    "get_properties",
    "Get serialized properties of an instance (with _type tags for Vector3, CFrame, etc.)",
    {
      path: z.string().describe("Dot-notation path to the instance"),
      properties: z
        .array(z.string())
        .optional()
        .describe(
          "Specific property names to read (default: all readable properties)"
        ),
    },
    async ({ path, properties }) => {
      return executeCommand(queue, "get_properties", { path, properties });
    }
  );

  /**
   * Tool: find_instances
   * Search the DataModel for instances matching criteria.
   * Supports filtering by className, name pattern, and search scope.
   *
   * @param className - Optional class name to filter by
   * @param namePattern - Optional Lua pattern to match against instance names
   * @param searchRoot - Where to search (default: "game")
   */
  server.tool(
    "find_instances",
    "Search for instances by className and/or name pattern",
    {
      className: z
        .string()
        .optional()
        .describe('Class name to filter by (e.g. "Part", "RemoteEvent")'),
      namePattern: z
        .string()
        .optional()
        .describe('Lua pattern to match instance names (e.g. "^Button")'),
      searchRoot: z
        .string()
        .optional()
        .describe(
          'Dot-notation path to search from (default: "game")'
        ),
      maxResults: z
        .number()
        .optional()
        .describe("Maximum number of results to return (default: 100)"),
    },
    async ({ className, namePattern, searchRoot, maxResults }) => {
      return executeCommand(queue, "find_instances", {
        className,
        namePattern,
        searchRoot,
        maxResults,
      });
    }
  );

  /**
   * Tool: get_services
   * Lists all services currently in the DataModel.
   * Equivalent to iterating game:GetChildren() and filtering for services.
   */
  server.tool(
    "get_services",
    "List all services currently in the DataModel (Workspace, ReplicatedStorage, etc.)",
    {},
    async () => {
      return executeCommand(queue, "get_services", {});
    }
  );

  /**
   * Tool: get_selection
   * Returns the currently selected objects in Roblox Studio.
   * Useful for context-aware operations.
   */
  server.tool(
    "get_selection",
    "Get the currently selected objects in Roblox Studio",
    {},
    async () => {
      return executeCommand(queue, "get_selection", {});
    }
  );

  /* ─────────────────────────── WRITE TOOLS ─────────────────────────── */

  /**
   * Tool: create_instance
   * Creates a new Instance in the DataModel.
   * All mutations are wrapped in ChangeHistoryService for Ctrl+Z support.
   *
   * @param className - The class to instantiate (e.g. "Part", "RemoteEvent")
   * @param parent - Dot-notation path to the parent instance
   * @param properties - Optional initial properties to set
   */
  server.tool(
    "create_instance",
    "Create a new Instance with the given className under the specified parent",
    {
      className: z
        .string()
        .describe('Roblox class name (e.g. "Part", "RemoteEvent", "Folder")'),
      parent: z
        .string()
        .describe(
          'Dot-notation path to parent (e.g. "game.Workspace", "game.ReplicatedStorage")'
        ),
      properties: PropertiesSchema,
    },
    async ({ className, parent, properties }) => {
      return executeCommand(queue, "create_instance", {
        className,
        parent,
        properties,
      });
    }
  );

  /**
   * Tool: set_properties
   * Modify properties on an existing instance.
   * Wrapped in ChangeHistoryService for undo support.
   *
   * @param path - Dot-notation path to the target instance
   * @param properties - Map of property names to new values
   */
  server.tool(
    "set_properties",
    "Set properties on an existing instance",
    {
      path: z.string().describe("Dot-notation path to the instance"),
      properties: z
        .record(z.string(), PropertyValueSchema)
        .describe("Map of property names to new values"),
    },
    async ({ path, properties }) => {
      return executeCommand(queue, "set_properties", { path, properties });
    }
  );

  /**
   * Tool: delete_instance
   * Destroy an instance and all its descendants.
   * Wrapped in ChangeHistoryService — Ctrl+Z will restore it.
   *
   * @param path - Dot-notation path to the instance to destroy
   */
  server.tool(
    "delete_instance",
    "Destroy an instance (and all its descendants)",
    {
      path: z
        .string()
        .describe("Dot-notation path to the instance to destroy"),
    },
    async ({ path }) => {
      return executeCommand(queue, "delete_instance", { path });
    }
  );

  /**
   * Tool: clone_instance
   * Clone an instance to a new parent.
   *
   * @param sourcePath - Dot-notation path to the instance to clone
   * @param destinationParent - Dot-notation path to the new parent
   */
  server.tool(
    "clone_instance",
    "Clone an instance to a new parent location",
    {
      sourcePath: z
        .string()
        .describe("Dot-notation path to the instance to clone"),
      destinationParent: z
        .string()
        .describe("Dot-notation path to the clone's new parent"),
    },
    async ({ sourcePath, destinationParent }) => {
      return executeCommand(queue, "clone_instance", {
        sourcePath,
        destinationParent,
      });
    }
  );

  /**
   * Tool: move_instance
   * Reparent an instance (move it to a new parent).
   *
   * @param path - Dot-notation path to the instance to move
   * @param newParent - Dot-notation path to the new parent
   */
  server.tool(
    "move_instance",
    "Move (reparent) an instance to a new parent",
    {
      path: z
        .string()
        .describe("Dot-notation path to the instance to move"),
      newParent: z
        .string()
        .describe("Dot-notation path to the new parent"),
    },
    async ({ path, newParent }) => {
      return executeCommand(queue, "move_instance", { path, newParent });
    }
  );

  /**
   * Tool: set_selection
   * Set the Studio selection to a list of instances.
   * Useful for drawing the user's attention to specific objects.
   *
   * @param paths - Array of dot-notation paths to select
   */
  server.tool(
    "set_selection",
    "Set the Roblox Studio selection to the given instances",
    {
      paths: z
        .array(z.string())
        .describe("Array of dot-notation paths to select"),
    },
    async ({ paths }) => {
      return executeCommand(queue, "set_selection", { paths });
    }
  );

  /**
   * Tool: insert_service
   * Calls game:GetService() to ensure a service exists.
   * Some services are not present by default and must be inserted.
   *
   * @param serviceName - The service class name (e.g. "TeleportService")
   */
  server.tool(
    "insert_service",
    "Insert/get a service via game:GetService() (e.g. TeleportService, Teams)",
    {
      serviceName: z
        .string()
        .describe(
          'Service class name (e.g. "TeleportService", "Teams", "Chat")'
        ),
    },
    async ({ serviceName }) => {
      return executeCommand(queue, "insert_service", { serviceName });
    }
  );

  /**
   * Tool: execute_luau
   * Execute arbitrary Luau code in the plugin's security context.
   * The code runs with plugin-level permissions and can access the full DataModel.
   * Use with caution — prefer specific tools when possible.
   *
   * @param code - Luau source code to execute
   */
  server.tool(
    "execute_luau",
    "Execute arbitrary Luau code in the Studio plugin context. Returns the result of the last expression.",
    {
      code: z
        .string()
        .describe("Luau source code to execute in the plugin context"),
    },
    async ({ code }) => {
      return executeCommand(queue, "execute_luau", { code });
    }
  );

  return server;
}

/**
 * Helper: enqueue a command and format the MCP tool response.
 *
 * Wraps the command queue interaction with consistent error handling
 * and response formatting for all 14 tools.
 *
 * @param queue - The command queue
 * @param type - Command type (tool name)
 * @param params - Command parameters
 * @returns MCP tool result with content array
 */
async function executeCommand(
  queue: CommandQueue,
  type: string,
  params: Record<string, unknown>
): Promise<{ content: Array<{ type: "text"; text: string }> }> {
  try {
    const result = await queue.enqueue(type, params);

    if (result.success) {
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(result.data, null, 2),
          },
        ],
      };
    } else {
      return {
        content: [
          {
            type: "text" as const,
            text: `Error from Studio plugin: ${result.error}`,
          },
        ],
      };
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      content: [
        {
          type: "text" as const,
          text: `Bridge error: ${message}`,
        },
      ],
    };
  }
}
