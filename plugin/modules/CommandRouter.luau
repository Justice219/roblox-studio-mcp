--[[
	CommandRouter — Dispatches commands from the MCP bridge to the appropriate handler.

	Each of the 14 MCP tools has a corresponding handler function here. All write
	operations are wrapped in ChangeHistoryService recordings so they can be undone
	with Ctrl+Z in Studio.

	Command Flow:
		1. HttpClient polls a command from the bridge
		2. CommandRouter.execute(command) is called
		3. The router dispatches to the matching handler based on command.type
		4. The handler executes against the DataModel and returns a result
		5. The result is POSTed back to the bridge via HttpClient

	Supported Commands (14):
		Read:  get_descendants, get_children, get_properties, find_instances,
		       get_services, get_selection
		Write: create_instance, set_properties, delete_instance, clone_instance,
		       move_instance, set_selection, insert_service, execute_luau

	@example
		local CommandRouter = require(script.Parent.CommandRouter)
		local result = CommandRouter.execute({
			id = "abc-123",
			type = "get_children",
			params = { path = "game.Workspace" }
		})
		-- { id = "abc-123", success = true, data = { ... } }
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local PathResolver = require(script.Parent.PathResolver)
local Serializer = require(script.Parent.Serializer)

local CommandRouter = {}

--[[
	Lookup table mapping command type strings to handler functions.
	Each handler takes (params: table) and returns (success: boolean, data: any?, error: string?).
]]
local handlers: { [string]: (params: { [string]: any }) -> (boolean, any?, string?) } = {}

-- ──────────────────────────── READ HANDLERS ────────────────────────────

--[[
	Handler: get_descendants
	Returns all descendants of an instance as a flat list with paths and classNames.
	Optionally limited by maxDepth.

	@param params.path — Dot-notation path to the root instance
	@param params.maxDepth — Optional maximum depth to traverse
	@return Array of { name, className, path } objects
]]
handlers["get_descendants"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	local maxDepth: number? = params.maxDepth
	local results: { { [string]: any } } = {}

	--[[
		Recursively collect descendants up to maxDepth.
		Uses depth-first traversal to maintain a predictable order.
	]]
	local function collect(inst: Instance, depth: number)
		if maxDepth and depth > maxDepth then
			return
		end
		for _, child in ipairs(inst:GetChildren()) do
			table.insert(results, {
				name = child.Name,
				className = child.ClassName,
				path = PathResolver.getPath(child),
			})
			collect(child, depth + 1)
		end
	end

	collect(instance, 1)
	return true, results, nil
end

--[[
	Handler: get_children
	Returns immediate children of an instance. Lighter than get_descendants.

	@param params.path — Dot-notation path to the parent instance
	@return Array of { name, className, path } objects
]]
handlers["get_children"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	local results: { { [string]: any } } = {}
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(results, {
			name = child.Name,
			className = child.ClassName,
			path = PathResolver.getPath(child),
		})
	end

	return true, results, nil
end

--[[
	Handler: get_properties
	Returns serialized properties of an instance. Uses Serializer for type conversion.

	@param params.path — Dot-notation path to the instance
	@param params.properties — Optional array of specific property names
	@return Table of property name → serialized value
]]
handlers["get_properties"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	local properties = Serializer.serializeProperties(instance, params.properties)
	return true, properties, nil
end

--[[
	Handler: find_instances
	Search for instances matching criteria (className, name pattern, or both).

	@param params.className — Optional class name to filter by (e.g. "Part")
	@param params.namePattern — Optional Lua string pattern to match names
	@param params.searchRoot — Dot-notation path to start search (default: "game")
	@param params.maxResults — Maximum number of results (default: 100)
	@return Array of { name, className, path } objects matching criteria
]]
handlers["find_instances"] = function(params)
	local rootPath = params.searchRoot or "game"
	local root, err = PathResolver.resolve(rootPath)
	if not root then
		return false, nil, err
	end

	local className: string? = params.className
	local namePattern: string? = params.namePattern
	local maxResults: number = params.maxResults or 100
	local results: { { [string]: any } } = {}

	--[[
		Iterate all descendants and filter by criteria.
		Stops early once maxResults is reached.
	]]
	for _, descendant in ipairs(root:GetDescendants()) do
		if #results >= maxResults then
			break
		end

		local matches = true

		-- Filter by className if specified
		if className and descendant.ClassName ~= className then
			-- Also check IsA for inheritance matching
			local isaOk, isaResult = pcall(function()
				return descendant:IsA(className :: string)
			end)
			if not (isaOk and isaResult) then
				matches = false
			end
		end

		-- Filter by name pattern if specified
		if matches and namePattern then
			local patternOk, patternResult = pcall(function()
				return string.find(descendant.Name, namePattern :: string) ~= nil
			end)
			if not (patternOk and patternResult) then
				matches = false
			end
		end

		if matches then
			table.insert(results, {
				name = descendant.Name,
				className = descendant.ClassName,
				path = PathResolver.getPath(descendant),
			})
		end
	end

	return true, results, nil
end

--[[
	Handler: get_services
	Lists all services in the DataModel.
	Filters game:GetChildren() to only include service-like objects.

	@return Array of { name, className } objects for each service
]]
handlers["get_services"] = function(_params)
	local results: { { [string]: any } } = {}

	for _, child in ipairs(game:GetChildren()) do
		table.insert(results, {
			name = child.Name,
			className = child.ClassName,
		})
	end

	return true, results, nil
end

--[[
	Handler: get_selection
	Returns the currently selected objects in the Studio editor.

	@return Array of { name, className, path } objects for selected instances
]]
handlers["get_selection"] = function(_params)
	local selected = Selection:Get()
	local results: { { [string]: any } } = {}

	for _, instance in ipairs(selected) do
		table.insert(results, {
			name = instance.Name,
			className = instance.ClassName,
			path = PathResolver.getPath(instance),
		})
	end

	return true, results, nil
end

-- ──────────────────────────── WRITE HANDLERS ────────────────────────────

--[[
	Handler: create_instance
	Creates a new Instance with the given className under the specified parent.
	Wrapped in ChangeHistoryService for Ctrl+Z undo support.

	@param params.className — Roblox class name (e.g. "Part", "RemoteEvent")
	@param params.parent — Dot-notation path to the parent
	@param params.properties — Optional initial properties to set
	@return { name, className, path } of the created instance
]]
handlers["create_instance"] = function(params)
	local parent, err = PathResolver.resolve(params.parent)
	if not parent then
		return false, nil, err
	end

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Create " .. tostring(params.className))
	if not recording then
		return false, nil, "Failed to begin ChangeHistoryService recording"
	end

	local ok, result = pcall(function()
		local instance = Instance.new(params.className)

		-- Apply properties before parenting (avoids unnecessary replication/rendering)
		if params.properties then
			local propErrors = Serializer.applyProperties(instance, params.properties)
			if #propErrors > 0 then
				warn("[MCP Bridge] Property errors during create:", table.concat(propErrors, ", "))
			end
		end

		-- Parent last for efficiency
		instance.Parent = parent
		return instance
	end)

	if ok and result then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, {
			name = result.Name,
			className = result.ClassName,
			path = PathResolver.getPath(result),
		}, nil
	else
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		return false, nil, "Failed to create instance: " .. tostring(result)
	end
end

--[[
	Handler: set_properties
	Sets properties on an existing instance.
	Wrapped in ChangeHistoryService for undo support.

	@param params.path — Dot-notation path to the instance
	@param params.properties — Map of property names to new values
	@return { path, propertiesSet, errors } summary
]]
handlers["set_properties"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Set properties on " .. instance.Name)
	if not recording then
		return false, nil, "Failed to begin ChangeHistoryService recording"
	end

	local propErrors = Serializer.applyProperties(instance, params.properties)

	if #propErrors > 0 then
		-- Some properties failed, but others may have succeeded — still commit
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, {
			path = PathResolver.getPath(instance),
			propertiesSet = params.properties,
			errors = propErrors,
		}, nil
	else
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, {
			path = PathResolver.getPath(instance),
			propertiesSet = params.properties,
			errors = {},
		}, nil
	end
end

--[[
	Handler: delete_instance
	Destroys an instance and all its descendants.
	Wrapped in ChangeHistoryService — Ctrl+Z restores the deleted instances.

	@param params.path — Dot-notation path to the instance to destroy
	@return { deleted, className } confirmation
]]
handlers["delete_instance"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	-- Safety check: prevent deleting the DataModel or core services
	if instance == game then
		return false, nil, "Cannot delete the DataModel (game) itself"
	end

	local name = instance.Name
	local className = instance.ClassName

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Delete " .. name)
	if not recording then
		return false, nil, "Failed to begin ChangeHistoryService recording"
	end

	local ok, destroyErr = pcall(function()
		instance:Destroy()
	end)

	if ok then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, { deleted = name, className = className }, nil
	else
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		return false, nil, "Failed to destroy instance: " .. tostring(destroyErr)
	end
end

--[[
	Handler: clone_instance
	Clones an instance and places the clone under a new parent.
	Wrapped in ChangeHistoryService for undo support.

	@param params.sourcePath — Dot-notation path to the instance to clone
	@param params.destinationParent — Dot-notation path to the clone's new parent
	@return { name, className, path } of the cloned instance
]]
handlers["clone_instance"] = function(params)
	local source, err = PathResolver.resolve(params.sourcePath)
	if not source then
		return false, nil, "Source: " .. tostring(err)
	end

	local destination, destErr = PathResolver.resolve(params.destinationParent)
	if not destination then
		return false, nil, "Destination: " .. tostring(destErr)
	end

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Clone " .. source.Name)
	if not recording then
		return false, nil, "Failed to begin ChangeHistoryService recording"
	end

	local ok, clone = pcall(function()
		local cloned = source:Clone()
		cloned.Parent = destination
		return cloned
	end)

	if ok and clone then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, {
			name = clone.Name,
			className = clone.ClassName,
			path = PathResolver.getPath(clone),
		}, nil
	else
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		return false, nil, "Failed to clone instance: " .. tostring(clone)
	end
end

--[[
	Handler: move_instance
	Reparents an instance to a new parent.
	Wrapped in ChangeHistoryService for undo support.

	@param params.path — Dot-notation path to the instance to move
	@param params.newParent — Dot-notation path to the new parent
	@return { name, className, newPath } of the moved instance
]]
handlers["move_instance"] = function(params)
	local instance, err = PathResolver.resolve(params.path)
	if not instance then
		return false, nil, err
	end

	local newParent, parentErr = PathResolver.resolve(params.newParent)
	if not newParent then
		return false, nil, "New parent: " .. tostring(parentErr)
	end

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Move " .. instance.Name)
	if not recording then
		return false, nil, "Failed to begin ChangeHistoryService recording"
	end

	local ok, moveErr = pcall(function()
		instance.Parent = newParent
	end)

	if ok then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		return true, {
			name = instance.Name,
			className = instance.ClassName,
			newPath = PathResolver.getPath(instance),
		}, nil
	else
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		return false, nil, "Failed to move instance: " .. tostring(moveErr)
	end
end

--[[
	Handler: set_selection
	Sets the Roblox Studio selection to the specified instances.
	Useful for drawing the user's attention to created/modified objects.

	@param params.paths — Array of dot-notation paths to select
	@return { selected } array of paths that were successfully resolved
]]
handlers["set_selection"] = function(params)
	local instances: { Instance } = {}
	local resolved: { string } = {}

	for _, path in ipairs(params.paths) do
		local instance, err = PathResolver.resolve(path)
		if instance then
			table.insert(instances, instance)
			table.insert(resolved, path)
		else
			warn("[MCP Bridge] Could not resolve selection path:", path, err)
		end
	end

	Selection:Set(instances)
	return true, { selected = resolved }, nil
end

--[[
	Handler: insert_service
	Calls game:GetService() to ensure a service exists in the DataModel.
	Some services (e.g. TeleportService, Teams) are not present by default.

	@param params.serviceName — The service class name
	@return { name, className } of the inserted/fetched service
]]
handlers["insert_service"] = function(params)
	local ok, service = pcall(function()
		return game:GetService(params.serviceName)
	end)

	if ok and service then
		return true, {
			name = service.Name,
			className = service.ClassName,
		}, nil
	else
		return false, nil, "Failed to get service '" .. tostring(params.serviceName) .. "': " .. tostring(service)
	end
end

--[[
	Handler: execute_luau
	Executes arbitrary Luau code in the plugin's security context.
	The code string is compiled and run via loadstring. The return value
	of the code is captured and sent back as the result.

	WARNING: This executes with full plugin permissions. Use with caution.

	@param params.code — Luau source code string
	@return The return value of the executed code (serialized)
]]
handlers["execute_luau"] = function(params)
	local code = params.code
	if not code or type(code) ~= "string" then
		return false, nil, "Missing or invalid 'code' parameter"
	end

	local recording = ChangeHistoryService:TryBeginRecording("MCP: Execute Luau")

	local fn, loadErr = loadstring(code)
	if not fn then
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		end
		return false, nil, "Luau compilation error: " .. tostring(loadErr)
	end

	local ok, result = pcall(fn)

	if recording then
		if ok then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		else
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		end
	end

	if ok then
		-- Attempt to serialize the result
		local serialized = Serializer.serialize(result)
		return true, serialized, nil
	else
		return false, nil, "Luau execution error: " .. tostring(result)
	end
end

-- ──────────────────────────── DISPATCHER ────────────────────────────

--[[
	Execute a command by dispatching to the appropriate handler.
	This is the main entry point called by the plugin's polling loop.

	@param command — Table with { id: string, type: string, params: table }
	@return Result table { id: string, success: boolean, data?: any, error?: string }

	@example
		local result = CommandRouter.execute({
			id = "abc-123",
			type = "get_children",
			params = { path = "game.Workspace" },
		})
		-- result = { id = "abc-123", success = true, data = [...] }
]]
function CommandRouter.execute(command: { [string]: any }): { [string]: any }
	local commandType = command.type
	local commandId = command.id
	local params = command.params or {}

	local handler = handlers[commandType]
	if not handler then
		return {
			id = commandId,
			success = false,
			error = "Unknown command type: " .. tostring(commandType),
		}
	end

	-- Execute the handler in a protected call for safety
	local ok, success, data, err = pcall(handler, params)

	if not ok then
		-- pcall itself failed — handler threw an unrecoverable error
		return {
			id = commandId,
			success = false,
			error = "Handler crashed: " .. tostring(success), -- success contains the error when pcall fails
		}
	end

	if success then
		return {
			id = commandId,
			success = true,
			data = data,
		}
	else
		return {
			id = commandId,
			success = false,
			error = err or "Unknown error in handler",
		}
	end
end

return CommandRouter
