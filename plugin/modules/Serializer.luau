--[[
	Serializer — Bidirectional conversion between Roblox types and JSON-safe tables.

	Roblox has many special types (Vector3, CFrame, Color3, UDim2, etc.) that cannot
	be directly serialized to JSON. This module converts them to/from tagged table
	representations using a `_type` field for unambiguous deserialization.

	Serialization Protocol:
		- Primitives (string, number, boolean, nil) pass through unchanged
		- Complex types are serialized as tables with a `_type` field:
			{ _type = "Vector3", x = 0, y = 5, z = 0 }
			{ _type = "Color3", r = 1, g = 0, b = 0 }
			{ _type = "CFrame", position = {...}, rotation = {...} }
		- Enum values use: { _type = "Enum", enumType = "Material", value = "Plastic" }

	Deserialization:
		- Tables with a `_type` field are deserialized to the corresponding Roblox type
		- Untagged tables pass through as-is (useful for ad-hoc data)

	@example
		local Serializer = require(script.Parent.Serializer)
		local json = Serializer.serialize(Vector3.new(1, 2, 3))
		-- { _type = "Vector3", x = 1, y = 2, z = 3 }
		local vec = Serializer.deserialize(json)
		-- Vector3.new(1, 2, 3)
]]

local HttpService = game:GetService("HttpService")

local Serializer = {}

--[[
	Serialize a single Roblox value to a JSON-safe representation.
	Handles all common Roblox types. Unknown userdata types are converted
	to their string representation as a fallback.

	@param value — Any Roblox value (Instance, Vector3, string, number, etc.)
	@return A JSON-safe Lua value (table, string, number, boolean, or nil)

	@example
		Serializer.serialize(Vector3.new(1, 2, 3))
		-- Returns: { _type = "Vector3", x = 1, y = 2, z = 3 }
]]
function Serializer.serialize(value: any): any
	if value == nil then
		return nil
	end

	local valueType = typeof(value)

	-- Primitives pass through
	if valueType == "string" or valueType == "number" or valueType == "boolean" then
		return value
	end

	-- Vector3
	if valueType == "Vector3" then
		return {
			_type = "Vector3",
			x = value.X,
			y = value.Y,
			z = value.Z,
		}
	end

	-- Vector2
	if valueType == "Vector2" then
		return {
			_type = "Vector2",
			x = value.X,
			y = value.Y,
		}
	end

	-- CFrame — serialize as position + rotation matrix (9 components)
	if valueType == "CFrame" then
		local components = { value:GetComponents() }
		return {
			_type = "CFrame",
			position = { x = components[1], y = components[2], z = components[3] },
			rotation = {
				r00 = components[4],
				r01 = components[5],
				r02 = components[6],
				r10 = components[7],
				r11 = components[8],
				r12 = components[9],
				r20 = components[10],
				r21 = components[11],
				r22 = components[12],
			},
		}
	end

	-- Color3
	if valueType == "Color3" then
		return {
			_type = "Color3",
			r = value.R,
			g = value.G,
			b = value.B,
		}
	end

	-- BrickColor
	if valueType == "BrickColor" then
		return {
			_type = "BrickColor",
			name = value.Name,
		}
	end

	-- UDim
	if valueType == "UDim" then
		return {
			_type = "UDim",
			scale = value.Scale,
			offset = value.Offset,
		}
	end

	-- UDim2
	if valueType == "UDim2" then
		return {
			_type = "UDim2",
			xScale = value.X.Scale,
			xOffset = value.X.Offset,
			yScale = value.Y.Scale,
			yOffset = value.Y.Offset,
		}
	end

	-- Rect
	if valueType == "Rect" then
		return {
			_type = "Rect",
			minX = value.Min.X,
			minY = value.Min.Y,
			maxX = value.Max.X,
			maxY = value.Max.Y,
		}
	end

	-- NumberRange
	if valueType == "NumberRange" then
		return {
			_type = "NumberRange",
			min = value.Min,
			max = value.Max,
		}
	end

	-- NumberSequence
	if valueType == "NumberSequence" then
		local keypoints = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(keypoints, {
				time = kp.Time,
				value = kp.Value,
				envelope = kp.Envelope,
			})
		end
		return {
			_type = "NumberSequence",
			keypoints = keypoints,
		}
	end

	-- ColorSequence
	if valueType == "ColorSequence" then
		local keypoints = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(keypoints, {
				time = kp.Time,
				color = { r = kp.Value.R, g = kp.Value.G, b = kp.Value.B },
			})
		end
		return {
			_type = "ColorSequence",
			keypoints = keypoints,
		}
	end

	-- EnumItem (e.g. Enum.Material.Plastic)
	if valueType == "EnumItem" then
		return {
			_type = "Enum",
			enumType = tostring(value.EnumType),
			value = value.Name,
		}
	end

	-- Instance reference — serialize as path
	if valueType == "Instance" then
		return {
			_type = "Instance",
			className = value.ClassName,
			name = value.Name,
			path = Serializer.getInstancePath(value),
		}
	end

	-- Font
	if valueType == "Font" then
		return {
			_type = "Font",
			family = value.Family,
			weight = value.Weight.Name,
			style = value.Style.Name,
		}
	end

	-- PhysicalProperties
	if valueType == "PhysicalProperties" then
		return {
			_type = "PhysicalProperties",
			density = value.Density,
			friction = value.Friction,
			elasticity = value.Elasticity,
			frictionWeight = value.FrictionWeight,
			elasticityWeight = value.ElasticityWeight,
		}
	end

	-- Ray
	if valueType == "Ray" then
		return {
			_type = "Ray",
			origin = { x = value.Origin.X, y = value.Origin.Y, z = value.Origin.Z },
			direction = { x = value.Direction.X, y = value.Direction.Y, z = value.Direction.Z },
		}
	end

	-- Fallback: convert to string
	return {
		_type = "unknown",
		typeName = valueType,
		value = tostring(value),
	}
end

--[[
	Deserialize a JSON-safe table back to a Roblox value.
	Tables with a `_type` field are converted to the corresponding Roblox type.
	Tables without `_type` pass through unchanged.

	@param data — A JSON-decoded Lua value (table, string, number, boolean, nil)
	@return The deserialized Roblox value

	@example
		Serializer.deserialize({ _type = "Vector3", x = 1, y = 2, z = 3 })
		-- Returns: Vector3.new(1, 2, 3)
]]
function Serializer.deserialize(data: any): any
	-- Primitives pass through
	if type(data) ~= "table" then
		return data
	end

	-- No _type tag: pass through as plain table
	local dataType = data._type
	if not dataType then
		return data
	end

	-- Vector3
	if dataType == "Vector3" then
		return Vector3.new(data.x or 0, data.y or 0, data.z or 0)
	end

	-- Vector2
	if dataType == "Vector2" then
		return Vector2.new(data.x or 0, data.y or 0)
	end

	-- CFrame
	if dataType == "CFrame" then
		local pos = data.position or {}
		local rot = data.rotation
		if rot then
			return CFrame.new(
				pos.x or 0,
				pos.y or 0,
				pos.z or 0,
				rot.r00 or 1,
				rot.r01 or 0,
				rot.r02 or 0,
				rot.r10 or 0,
				rot.r11 or 1,
				rot.r12 or 0,
				rot.r20 or 0,
				rot.r21 or 0,
				rot.r22 or 1
			)
		else
			return CFrame.new(pos.x or 0, pos.y or 0, pos.z or 0)
		end
	end

	-- Color3
	if dataType == "Color3" then
		return Color3.new(data.r or 0, data.g or 0, data.b or 0)
	end

	-- BrickColor
	if dataType == "BrickColor" then
		return BrickColor.new(data.name or "Medium stone grey")
	end

	-- UDim
	if dataType == "UDim" then
		return UDim.new(data.scale or 0, data.offset or 0)
	end

	-- UDim2
	if dataType == "UDim2" then
		return UDim2.new(
			data.xScale or 0,
			data.xOffset or 0,
			data.yScale or 0,
			data.yOffset or 0
		)
	end

	-- Rect
	if dataType == "Rect" then
		return Rect.new(data.minX or 0, data.minY or 0, data.maxX or 0, data.maxY or 0)
	end

	-- NumberRange
	if dataType == "NumberRange" then
		return NumberRange.new(data.min or 0, data.max or 1)
	end

	-- NumberSequence
	if dataType == "NumberSequence" then
		local keypoints = {}
		for _, kp in ipairs(data.keypoints or {}) do
			table.insert(
				keypoints,
				NumberSequenceKeypoint.new(kp.time or 0, kp.value or 0, kp.envelope or 0)
			)
		end
		if #keypoints >= 2 then
			return NumberSequence.new(keypoints)
		else
			return NumberSequence.new(0)
		end
	end

	-- ColorSequence
	if dataType == "ColorSequence" then
		local keypoints = {}
		for _, kp in ipairs(data.keypoints or {}) do
			local color = kp.color or {}
			table.insert(
				keypoints,
				ColorSequenceKeypoint.new(
					kp.time or 0,
					Color3.new(color.r or 0, color.g or 0, color.b or 0)
				)
			)
		end
		if #keypoints >= 2 then
			return ColorSequence.new(keypoints)
		else
			return ColorSequence.new(Color3.new(1, 1, 1))
		end
	end

	-- Enum
	if dataType == "Enum" then
		local enumType = data.enumType
		local enumValue = data.value
		if enumType and enumValue then
			local ok, result = pcall(function()
				return (Enum :: any)[enumType][enumValue]
			end)
			if ok then
				return result
			end
		end
		return nil
	end

	-- PhysicalProperties
	if dataType == "PhysicalProperties" then
		return PhysicalProperties.new(
			data.density or 1,
			data.friction or 0.3,
			data.elasticity or 0.5,
			data.frictionWeight or 1,
			data.elasticityWeight or 1
		)
	end

	-- Fallback: return the table as-is
	return data
end

--[[
	Get the dot-notation path for an Instance.
	Walks up the parent chain to the DataModel root.

	@param instance — The Instance to get the path for
	@return String path (e.g. "game.Workspace.MyPart")
]]
function Serializer.getInstancePath(instance: Instance): string
	local parts: { string } = {}
	local current: Instance? = instance

	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end

	table.insert(parts, 1, "game")
	return table.concat(parts, ".")
end

--[[
	Serialize a table of properties from an Instance.
	Reads each property safely via pcall and serializes the values.

	@param instance — The Instance to read properties from
	@param propertyNames — Optional list of specific property names to read.
	                        If nil, reads a common set of properties based on className.
	@return Table mapping property names to serialized values

	@example
		local props = Serializer.serializeProperties(workspace.Baseplate, {"Name", "Position", "Size"})
		-- { Name = "Baseplate", Position = { _type = "Vector3", ... }, Size = { _type = "Vector3", ... } }
]]
function Serializer.serializeProperties(instance: Instance, propertyNames: { string }?): { [string]: any }
	local result: { [string]: any } = {}

	-- If specific properties are requested, use those
	if propertyNames and #propertyNames > 0 then
		for _, propName in ipairs(propertyNames) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
		return result
	end

	-- Otherwise, read common properties that exist on most instances
	local commonProps = {
		"Name",
		"ClassName",
		"Parent",
		"Archivable",
	}

	-- BasePart properties
	local basePartProps = {
		"Position",
		"Size",
		"CFrame",
		"Orientation",
		"Color",
		"BrickColor",
		"Material",
		"Transparency",
		"Reflectance",
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"Massless",
		"Locked",
		"CastShadow",
	}

	-- GuiObject properties
	local guiProps = {
		"Position",
		"Size",
		"AnchorPoint",
		"BackgroundColor3",
		"BackgroundTransparency",
		"BorderColor3",
		"BorderSizePixel",
		"Visible",
		"ZIndex",
		"LayoutOrder",
		"AutomaticSize",
		"ClipsDescendants",
	}

	-- TextLabel/TextButton/TextBox properties
	local textProps = {
		"Text",
		"TextColor3",
		"TextSize",
		"Font",
		"TextXAlignment",
		"TextYAlignment",
		"TextWrapped",
		"TextScaled",
		"RichText",
	}

	-- Read common properties first
	for _, propName in ipairs(commonProps) do
		local ok, value = pcall(function()
			return (instance :: any)[propName]
		end)
		if ok then
			result[propName] = Serializer.serialize(value)
		end
	end

	-- Add class-specific properties
	if instance:IsA("BasePart") then
		for _, propName in ipairs(basePartProps) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
	end

	if instance:IsA("GuiObject") then
		for _, propName in ipairs(guiProps) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
	end

	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		for _, propName in ipairs(textProps) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
	end

	-- Light properties
	if instance:IsA("Light") then
		for _, propName in ipairs({ "Brightness", "Color", "Enabled", "Range", "Shadows" }) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
	end

	-- Script properties
	if instance:IsA("LuaSourceContainer") then
		for _, propName in ipairs({ "Enabled", "RunContext" }) do
			local ok, value = pcall(function()
				return (instance :: any)[propName]
			end)
			if ok then
				result[propName] = Serializer.serialize(value)
			end
		end
	end

	-- Value objects
	if instance:IsA("ValueBase") then
		local ok, value = pcall(function()
			return (instance :: any).Value
		end)
		if ok then
			result["Value"] = Serializer.serialize(value)
		end
	end

	return result
end

--[[
	Apply deserialized properties to an Instance.
	Each property is set via pcall to handle read-only or invalid properties gracefully.

	@param instance — The Instance to modify
	@param properties — Table mapping property names to serialized (tagged) values
	@return Array of error messages for properties that failed to set (empty = all succeeded)

	@example
		local errors = Serializer.applyProperties(myPart, {
			Name = "NewName",
			Position = { _type = "Vector3", x = 0, y = 10, z = 0 },
		})
]]
function Serializer.applyProperties(instance: Instance, properties: { [string]: any }): { string }
	local errors: { string } = {}

	for propName, serializedValue in pairs(properties) do
		local value = Serializer.deserialize(serializedValue)
		local ok, err = pcall(function()
			(instance :: any)[propName] = value
		end)
		if not ok then
			table.insert(errors, propName .. ": " .. tostring(err))
		end
	end

	return errors
end

return Serializer
