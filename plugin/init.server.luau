--[[
	MCP Bridge Plugin — Entry Point

	This is the main server script for the Roblox Studio MCP Bridge plugin.
	It creates a toolbar button, a status DockWidget, and runs the polling loop
	that communicates with the MCP bridge HTTP server on localhost:3001.

	Architecture:
		- Polls GET /poll every ~200ms for commands from Claude Code
		- Executes commands against the DataModel via CommandRouter
		- POSTs results back via POST /result
		- Sends heartbeat every ~3s to maintain connection state

	The polling loop runs on RunService.Heartbeat for precise timing.
	The toolbar button toggles the connection on/off.
	The DockWidget shows real-time connection status.

	@see CommandRouter — Dispatches and executes the 14 command types
	@see HttpClient — Handles all HTTP communication with the bridge server
	@see PathResolver — Converts dot-notation paths to Instance references
	@see Serializer — Converts Roblox types to/from JSON-safe tables
]]

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local HttpClient = require(script.modules.HttpClient)
local CommandRouter = require(script.modules.CommandRouter)

-- ──────────────────────────── CONFIGURATION ────────────────────────────

--[[
	Bridge server base URL. Must match the HTTP bridge port in the MCP server.
	Only localhost connections are supported for security.
]]
local BRIDGE_URL = "http://localhost:3001"

--[[
	Polling interval in seconds. 200ms provides sub-200ms latency while staying
	well within Roblox's 2000 req/min localhost rate limit (~300 req/min at 200ms).
]]
local POLL_INTERVAL = 0.2

--[[
	Heartbeat interval in seconds. The MCP server considers the plugin disconnected
	if no heartbeat is received within 10s, so 3s provides comfortable margin.
]]
local HEARTBEAT_INTERVAL = 3.0

-- ──────────────────────────── PLUGIN SETUP ────────────────────────────

--[[
	Create the plugin toolbar and button.
	The button toggles the MCP bridge connection on/off.
]]
local toolbar = plugin:CreateToolbar("MCP Bridge")
local toggleButton = toolbar:CreateButton(
	"MCP Bridge",
	"Toggle MCP Bridge connection to Claude Code",
	"rbxassetid://4458901886" -- generic network/connection icon
)

--[[
	Create the status DockWidget.
	Shows connection status, command count, and last activity.
	Minimal size: 200x120, floats by default.
]]
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,   -- Start floating
	false,                          -- Start disabled (hidden)
	false,                          -- Don't override previous state
	200,                            -- Default width
	120,                            -- Default height
	180,                            -- Min width
	100                             -- Min height
)
local statusWidget = plugin:CreateDockWidgetPluginGui("MCPBridgeStatus", widgetInfo)
statusWidget.Title = "MCP Bridge"

-- ──────────────────────────── STATUS UI ────────────────────────────

--[[
	Build the status widget UI.
	Shows a colored status indicator and text with connection details.
]]
local statusFrame = Instance.new("Frame")
statusFrame.Size = UDim2.new(1, 0, 1, 0)
statusFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
statusFrame.BorderSizePixel = 0
statusFrame.Parent = statusWidget

local statusPadding = Instance.new("UIPadding")
statusPadding.PaddingTop = UDim.new(0, 8)
statusPadding.PaddingBottom = UDim.new(0, 8)
statusPadding.PaddingLeft = UDim.new(0, 10)
statusPadding.PaddingRight = UDim.new(0, 10)
statusPadding.Parent = statusFrame

local statusLayout = Instance.new("UIListLayout")
statusLayout.SortOrder = Enum.SortOrder.LayoutOrder
statusLayout.Padding = UDim.new(0, 6)
statusLayout.Parent = statusFrame

--[[
	Status indicator row: colored dot + status text.
]]
local statusRow = Instance.new("Frame")
statusRow.Size = UDim2.new(1, 0, 0, 20)
statusRow.BackgroundTransparency = 1
statusRow.LayoutOrder = 1
statusRow.Parent = statusFrame

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 12, 0, 12)
statusDot.Position = UDim2.new(0, 0, 0.5, -6)
statusDot.BackgroundColor3 = Color3.fromRGB(200, 50, 50) -- Red = disconnected
statusDot.BorderSizePixel = 0
statusDot.Parent = statusRow

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 1, 0)
statusLabel.Position = UDim2.new(0, 20, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Disconnected"
statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
statusLabel.TextSize = 14
statusLabel.Font = Enum.Font.SourceSans
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = statusRow

--[[
	Command counter label.
]]
local commandLabel = Instance.new("TextLabel")
commandLabel.Size = UDim2.new(1, 0, 0, 16)
commandLabel.BackgroundTransparency = 1
commandLabel.Text = "Commands: 0"
commandLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
commandLabel.TextSize = 12
commandLabel.Font = Enum.Font.SourceSans
commandLabel.TextXAlignment = Enum.TextXAlignment.Left
commandLabel.LayoutOrder = 2
commandLabel.Parent = statusFrame

--[[
	Last activity label.
]]
local activityLabel = Instance.new("TextLabel")
activityLabel.Size = UDim2.new(1, 0, 0, 16)
activityLabel.BackgroundTransparency = 1
activityLabel.Text = "Last: --"
activityLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
activityLabel.TextSize = 12
activityLabel.Font = Enum.Font.SourceSans
activityLabel.TextXAlignment = Enum.TextXAlignment.Left
activityLabel.LayoutOrder = 3
activityLabel.Parent = statusFrame

-- ──────────────────────────── STATE ────────────────────────────

local isEnabled = false           -- Whether the polling loop is active
local isConnected = false         -- Whether the bridge server is reachable
local commandCount = 0            -- Total commands executed this session
local lastPollTime = 0            -- Last time we polled (os.clock())
local lastHeartbeatTime = 0       -- Last time we sent a heartbeat

local client = HttpClient.new(BRIDGE_URL)

-- ──────────────────────────── UI UPDATE ────────────────────────────

--[[
	Update the status widget UI to reflect current connection state.
	Called after state changes (connect, disconnect, command executed).
]]
local function updateStatusUI()
	if isConnected then
		statusDot.BackgroundColor3 = Color3.fromRGB(50, 200, 50) -- Green
		statusLabel.Text = "Connected"
	else
		statusDot.BackgroundColor3 = Color3.fromRGB(200, 50, 50) -- Red
		statusLabel.Text = isEnabled and "Connecting..." or "Disconnected"
	end
	commandLabel.Text = "Commands: " .. tostring(commandCount)
end

-- ──────────────────────────── POLLING LOOP ────────────────────────────

--[[
	Main heartbeat connection. Runs every frame while the plugin is enabled.
	Handles both polling (every POLL_INTERVAL) and heartbeat (every HEARTBEAT_INTERVAL).

	The polling and heartbeat are driven by os.clock() timers checked each frame,
	rather than spawning separate threads — this keeps everything on the main thread
	and avoids race conditions.
]]
local heartbeatConnection: RBXScriptConnection? = nil

local function startPolling()
	if heartbeatConnection then
		return -- Already running
	end

	isEnabled = true
	updateStatusUI()

	heartbeatConnection = RunService.Heartbeat:Connect(function()
		if not isEnabled then
			return
		end

		local now = os.clock()

		-- Send heartbeat at the configured interval
		if now - lastHeartbeatTime >= HEARTBEAT_INTERVAL then
			lastHeartbeatTime = now
			task.spawn(function()
				local ok, err = client:sendHeartbeat()
				if ok then
					if not isConnected then
						isConnected = true
						updateStatusUI()
						print("[MCP Bridge] Connected to bridge server")
					end
				else
					if isConnected then
						isConnected = false
						updateStatusUI()
						warn("[MCP Bridge] Lost connection:", err)
					end
				end
			end)
		end

		-- Poll for commands at the configured interval
		if now - lastPollTime >= POLL_INTERVAL then
			lastPollTime = now
			task.spawn(function()
				if not isConnected then
					return
				end

				local command, pollErr = client:poll()

				if pollErr then
					-- Network error — may have lost connection
					if isConnected then
						isConnected = false
						updateStatusUI()
						warn("[MCP Bridge] Poll error:", pollErr)
					end
					return
				end

				if not command then
					return -- 204 No Content — no commands waiting
				end

				-- Execute the command
				local result = CommandRouter.execute(command)
				commandCount += 1
				activityLabel.Text = "Last: " .. tostring(command.type)
				updateStatusUI()

				-- Send the result back to the bridge
				local sendOk, sendErr = client:sendResult(result)
				if not sendOk then
					warn("[MCP Bridge] Failed to send result:", sendErr)
				end
			end)
		end
	end)
end

--[[
	Stop the polling loop and clean up the heartbeat connection.
	Called when the user toggles the button off.
]]
local function stopPolling()
	isEnabled = false
	isConnected = false

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	updateStatusUI()
	print("[MCP Bridge] Disconnected")
end

-- ──────────────────────────── TOOLBAR BUTTON ────────────────────────────

--[[
	Toggle button handler.
	Clicking the toolbar button starts or stops the polling loop
	and shows/hides the status widget.
]]
toggleButton.Click:Connect(function()
	if isEnabled then
		stopPolling()
		toggleButton:SetActive(false)
		statusWidget.Enabled = false
	else
		startPolling()
		toggleButton:SetActive(true)
		statusWidget.Enabled = true
	end
end)

-- ──────────────────────────── AUTO-START ────────────────────────────

--[[
	Auto-start the polling loop on plugin load.
	This ensures the bridge is ready immediately when Studio opens.
	The user can still toggle it off via the toolbar button.
]]
task.defer(function()
	startPolling()
	toggleButton:SetActive(true)
	statusWidget.Enabled = true
	print("[MCP Bridge] Plugin loaded — polling bridge at " .. BRIDGE_URL)
end)
