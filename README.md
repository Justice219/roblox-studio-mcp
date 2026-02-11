# Roblox Studio MCP Bridge

A [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server that connects AI coding assistants like **Claude Code** directly to **Roblox Studio**. Read, create, modify, and delete instances in the DataModel — all from your terminal.

## How It Works

```
Claude Code (MCP Client)
        |
   MCP Server (stdio)
        |
   HTTP Bridge (localhost:3001)
        |
   Studio Plugin (polls every 200ms)
        |
   Roblox Studio DataModel
```

The bridge has two halves:

1. **MCP Server** (TypeScript) — Runs locally, exposes 14 tools via MCP over stdio, and serves an HTTP API on `localhost:3001`
2. **Studio Plugin** (Luau) — Polls the HTTP API for commands, executes them against the DataModel, and returns results

All write operations are wrapped in `ChangeHistoryService`, so every change can be undone with `Ctrl+Z` in Studio.

## Available Tools

| Tool | Type | Description |
|------|------|-------------|
| `get_descendants` | Read | Get all descendants with paths, optional `maxDepth` |
| `get_children` | Read | Get immediate children of an instance |
| `get_properties` | Read | Get serialized properties of an instance |
| `find_instances` | Read | Search by `className` and/or `namePattern` |
| `get_services` | Read | List all DataModel services |
| `get_selection` | Read | Get currently selected instances in Studio |
| `create_instance` | Write | Create a new Instance with properties |
| `set_properties` | Write | Modify properties on an existing instance |
| `delete_instance` | Write | Destroy an instance (undo-supported) |
| `clone_instance` | Write | Clone an instance to a new parent |
| `move_instance` | Write | Reparent an instance |
| `set_selection` | Write | Set the Studio selection |
| `insert_service` | Write | Insert a service via `game:GetService()` |
| `execute_luau` | Write | Execute arbitrary Luau code in the plugin context |

Paths use dot-notation starting from `game`, e.g. `game.Workspace.SpawnLocation`.

## Prerequisites

- **Node.js** 18+
- **Roblox Studio**
- **Rojo** 7+ ([aftman](https://github.com/LPGhatguy/aftman) or standalone install)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/Justice219/roblox-studio-mcp.git
cd roblox-studio-mcp
```

### 2. Install dependencies and build

```bash
npm install
npm run build
```

### 3. Build and install the Studio plugin

Using Rojo:

```bash
rojo build plugin.project.json -o MCPBridge.rbxmx
```

Then copy the plugin file to your Roblox plugins folder:

| OS | Path |
|----|------|
| macOS | `~/Documents/Roblox/Plugins/MCPBridge.rbxmx` |
| Windows | `%LOCALAPPDATA%\Roblox\Plugins\MCPBridge.rbxmx` |

Or build directly to the plugins folder:

```bash
# macOS
rojo build plugin.project.json -o ~/Documents/Roblox/Plugins/MCPBridge.rbxmx

# Windows
rojo build plugin.project.json -o "%LOCALAPPDATA%\Roblox\Plugins\MCPBridge.rbxmx"
```

### 4. Enable HttpService in Studio

Open Roblox Studio, then:

**Home → Game Settings → Security → Allow HTTP Requests → ON**

This is required for the plugin to communicate with the local MCP server.

### 5. Configure your MCP client

Add the server to your MCP client configuration.

**Claude Code** (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "node",
      "args": ["/absolute/path/to/roblox-studio-mcp/dist/index.js"]
    }
  }
}
```

**Claude Desktop** (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "node",
      "args": ["/absolute/path/to/roblox-studio-mcp/dist/index.js"]
    }
  }
}
```

Replace `/absolute/path/to/` with the actual path where you cloned the repo.

### 6. Restart Studio and your MCP client

- Restart Roblox Studio (or reload plugins) — you should see an "MCP Bridge" button in the toolbar
- Restart Claude Code / your MCP client
- The plugin status widget will show a green dot when connected

## Usage

Once connected, your AI assistant can manipulate Studio directly:

```
"Create a Part named SpawnPad in Workspace at position 0, 5, 0"
"Get all children of ServerScriptService"
"Find all instances with className RemoteEvent"
"Set the BrickColor of game.Workspace.SpawnPad to Bright green"
```

The assistant uses the MCP tools to read the DataModel, create instances, set properties, and more — all reflected live in Studio with full undo support.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `MCP_BRIDGE_PORT` | `3001` | HTTP bridge port |

```bash
MCP_BRIDGE_PORT=4000 npm start
```

## Development

```bash
# Watch mode — recompiles on file changes
npm run dev

# Type-check without emitting
npm run typecheck

# Build
npm run build

# Start the server
npm start
```

## Architecture

```
src/
├── index.ts           # Entry point — wires up all components
├── types.ts           # Interfaces, constants, command type definitions
├── mcp-server.ts      # MCP tool definitions (14 tools with Zod validation)
├── http-bridge.ts     # Express HTTP server (poll/result/heartbeat endpoints)
└── command-queue.ts   # In-memory command queue with timeout management

plugin/
├── init.server.luau   # Plugin entry point — polling loop, UI, toolbar
└── modules/
    ├── CommandRouter.luau  # Dispatches commands to handlers
    ├── HttpClient.luau     # HTTP requests to the bridge
    ├── PathResolver.luau   # Dot-notation path ↔ Instance resolution
    └── Serializer.luau     # Roblox type ↔ JSON serialization
```

## Security

- The HTTP bridge **only binds to `127.0.0.1`** — it is never exposed to the network
- Write operations are wrapped in `ChangeHistoryService` for undo support
- Commands timeout after 30 seconds
- Connection requires heartbeat every 10 seconds
- `execute_luau` runs code in the plugin context with no sandboxing — only use with trusted input

## Supported Roblox Types

The serializer handles bidirectional conversion for:

`Vector3` · `Vector2` · `CFrame` · `Color3` · `BrickColor` · `UDim` · `UDim2` · `Rect` · `NumberSequence` · `ColorSequence` · `NumberRange` · `Enum` · `Instance` · `Font` · `PhysicalProperties` · `Ray`

All types use a `{ _type: "TypeName", ... }` JSON format for lossless round-tripping.

## Troubleshooting

**Plugin shows red dot / "Disconnected"**
- Make sure the MCP server is running (`npm start`)
- Check that HttpService is enabled in Studio
- Verify the port matches (default `3001`)

**"Plugin not connected" error in Claude Code**
- Open Studio and check the MCP Bridge toolbar button is enabled
- The plugin auto-starts on load — try reloading plugins
- Check Studio's Output window for error messages

**Port already in use**
- Another instance may be running. Kill it or use a different port:
  ```bash
  MCP_BRIDGE_PORT=4000 npm start
  ```

## License

MIT
