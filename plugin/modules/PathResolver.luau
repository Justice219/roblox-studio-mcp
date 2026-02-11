--[[
	PathResolver — Converts between dot-notation string paths and Roblox Instance references.

	The MCP bridge uses dot-notation paths (e.g. "game.Workspace.MyFolder.MyPart")
	as the universal addressing scheme. This module handles the bidirectional conversion.

	Path Format:
		- Always starts with "game" (the DataModel root)
		- Each segment separated by "." maps to a child name
		- Example: "game.Workspace.SpawnLocation" → game:GetService("Workspace").SpawnLocation

	Service Resolution:
		- The second segment is always treated as a service name
		- Uses game:GetService() for known services (handles names like "Workspace", "ReplicatedStorage")
		- Falls back to game:FindFirstChild() for non-service children

	@example
		local PathResolver = require(script.Parent.PathResolver)
		local instance = PathResolver.resolve("game.Workspace.MyPart")
		local path = PathResolver.getPath(workspace.MyPart) -- "game.Workspace.MyPart"
]]

local PathResolver = {}

--[[
	Known Roblox services that should be resolved via game:GetService().
	This list covers the most commonly used services. If a service isn't here,
	FindFirstChild is used as a fallback.
]]
local KNOWN_SERVICES: { [string]: boolean } = {
	Workspace = true,
	Players = true,
	Lighting = true,
	ReplicatedFirst = true,
	ReplicatedStorage = true,
	ServerScriptService = true,
	ServerStorage = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayer = true,
	Teams = true,
	SoundService = true,
	Chat = true,
	LocalizationService = true,
	TestService = true,
	HttpService = true,
	RunService = true,
	UserInputService = true,
	TweenService = true,
	PhysicsService = true,
	CollectionService = true,
	MarketplaceService = true,
	TeleportService = true,
	TextService = true,
	PathfindingService = true,
	GroupService = true,
	BadgeService = true,
	InsertService = true,
	GamePassService = true,
	MaterialService = true,
	MemoryStoreService = true,
	MessagingService = true,
	PolicyService = true,
	ProximityPromptService = true,
	Selection = true,
	ChangeHistoryService = true,
	ScriptEditorService = true,
	StudioService = true,
	CoreGui = true,
}

--[[
	Split a dot-notation path string into an array of segments.
	@param path — The path string (e.g. "game.Workspace.MyPart")
	@return Array of path segments (e.g. {"game", "Workspace", "MyPart"})
]]
local function splitPath(path: string): { string }
	local segments: { string } = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(segments, segment)
	end
	return segments
end

--[[
	Resolve a dot-notation path string to a Roblox Instance.

	@param path — Dot-notation path starting with "game" (e.g. "game.Workspace.MyPart")
	@return The resolved Instance, or nil if any segment in the path doesn't exist
	@return Error message if resolution fails, nil on success

	@example
		local instance, err = PathResolver.resolve("game.Workspace.SpawnLocation")
		if not instance then
			warn("Failed to resolve:", err)
		end
]]
function PathResolver.resolve(path: string): (Instance?, string?)
	local segments = splitPath(path)

	-- Path must start with "game"
	if #segments == 0 or segments[1] ~= "game" then
		return nil, "Path must start with 'game', got: " .. tostring(path)
	end

	-- "game" alone returns the DataModel
	if #segments == 1 then
		return game, nil
	end

	-- Second segment: try as a service first, then FindFirstChild
	local current: Instance
	local serviceName = segments[2]

	if KNOWN_SERVICES[serviceName] then
		local ok, service = pcall(function()
			return game:GetService(serviceName)
		end)
		if ok and service then
			current = service
		else
			return nil, "Failed to get service: " .. serviceName
		end
	else
		local child = game:FindFirstChild(serviceName)
		if child then
			current = child
		else
			return nil, "Child not found: game." .. serviceName
		end
	end

	-- Resolve remaining segments via FindFirstChild
	for i = 3, #segments do
		local child = current:FindFirstChild(segments[i])
		if not child then
			local resolvedSoFar = table.concat(segments, ".", 1, i - 1)
			return nil, "Child '" .. segments[i] .. "' not found under '" .. resolvedSoFar .. "'"
		end
		current = child
	end

	return current, nil
end

--[[
	Get the dot-notation path string for a Roblox Instance.
	Walks up the parent chain to build the full path from the DataModel root.

	@param instance — The Instance to get the path for
	@return Dot-notation path string (e.g. "game.Workspace.MyPart")

	@example
		local path = PathResolver.getPath(workspace.MyPart) -- "game.Workspace.MyPart"
]]
function PathResolver.getPath(instance: Instance): string
	local parts: { string } = {}
	local current: Instance? = instance

	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end

	table.insert(parts, 1, "game")
	return table.concat(parts, ".")
end

return PathResolver
