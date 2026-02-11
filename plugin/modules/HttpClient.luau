--[[
	HttpClient — HTTP communication layer for the MCP Bridge plugin.

	Handles all HTTP requests between the Studio plugin and the MCP bridge server:
		- Polling for new commands (GET /poll)
		- Sending execution results (POST /result)
		- Sending heartbeat keepalive signals (POST /heartbeat)

	All HTTP calls are wrapped in pcall for resilience — network errors
	(e.g. bridge not running) are caught and logged rather than crashing the plugin.

	Configuration:
		- Base URL defaults to http://localhost:3001
		- Uses HttpService:RequestAsync for full control over method/headers/body

	@example
		local HttpClient = require(script.Parent.HttpClient)
		local client = HttpClient.new("http://localhost:3001")
		local command = client:poll()
		if command then
			-- execute command...
			client:sendResult({ id = command.id, success = true, data = result })
		end
]]

local HttpService = game:GetService("HttpService")

local HttpClient = {}
HttpClient.__index = HttpClient

--[[
	Plugin version string sent with heartbeats.
	The MCP server can use this for compatibility checks.
]]
local PLUGIN_VERSION = "1.0.0"

--[[
	Create a new HttpClient instance.

	@param baseUrl — The base URL of the MCP bridge HTTP server (e.g. "http://localhost:3001")
	@return HttpClient instance

	@example
		local client = HttpClient.new("http://localhost:3001")
]]
function HttpClient.new(baseUrl: string)
	local self = setmetatable({}, HttpClient)
	self._baseUrl = baseUrl
	return self
end

--[[
	Poll the bridge server for the next command to execute.
	Sends GET /poll and returns the command if one is available.

	@return Command table { id: string, type: string, params: table } or nil if no command
	@return Error message string if the request failed, nil on success

	@example
		local command, err = client:poll()
		if command then
			print("Got command:", command.type, command.id)
		elseif err then
			warn("Poll error:", err)
		end
]]
function HttpClient:poll(): ({ [string]: any }?, string?)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = self._baseUrl .. "/poll",
			Method = "GET",
			Headers = {
				["Accept"] = "application/json",
			},
		})
	end)

	if not ok then
		return nil, "HTTP request failed: " .. tostring(response)
	end

	-- 204 No Content = no commands waiting
	if response.StatusCode == 204 then
		return nil, nil
	end

	-- 200 OK = command available
	if response.StatusCode == 200 then
		local decodeOk, command = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if decodeOk and command then
			return command, nil
		else
			return nil, "Failed to decode poll response: " .. tostring(command)
		end
	end

	return nil, "Unexpected status code from /poll: " .. tostring(response.StatusCode)
end

--[[
	Send the result of a command execution back to the bridge server.
	The result must include the command `id` for matching.

	@param result — Table with { id: string, success: boolean, data?: any, error?: string }
	@return true on success, false on failure
	@return Error message on failure, nil on success

	@example
		local ok, err = client:sendResult({
			id = "abc-123",
			success = true,
			data = { children = { ... } },
		})
]]
function HttpClient:sendResult(result: { [string]: any }): (boolean, string?)
	local body: string
	local encodeOk, encoded = pcall(function()
		return HttpService:JSONEncode(result)
	end)
	if not encodeOk then
		return false, "Failed to encode result: " .. tostring(encoded)
	end
	body = encoded

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = self._baseUrl .. "/result",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = body,
		})
	end)

	if not ok then
		return false, "HTTP request failed: " .. tostring(response)
	end

	if response.StatusCode == 200 then
		return true, nil
	end

	return false, "Unexpected status from /result: " .. tostring(response.StatusCode) .. " " .. tostring(response.Body)
end

--[[
	Send a heartbeat keepalive signal to the bridge server.
	Should be called every ~3 seconds to maintain the "connected" state.

	@return true if the heartbeat was acknowledged, false otherwise
	@return Error message on failure, nil on success

	@example
		local ok, err = client:sendHeartbeat()
		if not ok then
			warn("Heartbeat failed:", err)
		end
]]
function HttpClient:sendHeartbeat(): (boolean, string?)
	local body: string
	local encodeOk, encoded = pcall(function()
		return HttpService:JSONEncode({
			pluginVersion = PLUGIN_VERSION,
			studioSessionId = tostring(game.JobId),
		})
	end)
	if not encodeOk then
		return false, "Failed to encode heartbeat: " .. tostring(encoded)
	end
	body = encoded

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = self._baseUrl .. "/heartbeat",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = body,
		})
	end)

	if not ok then
		return false, "HTTP request failed: " .. tostring(response)
	end

	if response.StatusCode == 200 then
		return true, nil
	end

	return false, "Unexpected status from /heartbeat: " .. tostring(response.StatusCode)
end

return HttpClient
