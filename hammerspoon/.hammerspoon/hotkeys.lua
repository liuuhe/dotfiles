local M = {}

function M.selectMenu(menuPath)
	return function()
		local app = hs.application.frontmostApplication()
		if app and not app:selectMenuItem(menuPath) then
			hs.notify
				.new({
					title = "Menu execution failed",
					informativeText = table.concat(menuPath, " → "),
				})
				:send()
		end
	end
end

function M.validate(bindings)
	assert(type(bindings) == "table", "hotkeys must be a list")
	local modifiers = {
		cmd = true,
		command = true,
		["⌘"] = true,
		ctrl = true,
		control = true,
		["⌃"] = true,
		alt = true,
		option = true,
		["⌥"] = true,
		shift = true,
		["⇧"] = true,
		fn = true,
	}
	local count = 0
	for index in pairs(bindings) do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0, "hotkeys must be a list")
		count = count + 1
	end
	for index = 1, count do
		local binding = bindings[index]
		local label = "hotkeys[" .. index .. "]"
		assert(type(binding) == "table", label .. " must be a table")
		assert(type(binding.mods) == "table", label .. ".mods must be a list")
		local modifierCount = 0
		for modifierIndex in pairs(binding.mods) do
			assert(
				type(modifierIndex) == "number" and modifierIndex >= 1 and modifierIndex % 1 == 0,
				label .. ".mods must be a list"
			)
			modifierCount = modifierCount + 1
		end
		for modifierIndex = 1, modifierCount do
			local modifier = binding.mods[modifierIndex]
			assert(type(modifier) == "string" and modifiers[modifier], label .. ".mods contains an invalid modifier")
		end
		assert(type(binding.key) == "string" and binding.key ~= "", label .. ".key must be a non-empty string")
		assert(type(binding.action) == "function", label .. ".action must be a function")
		assert(binding.repeatable == nil or type(binding.repeatable) == "boolean", label .. ".repeatable must be a boolean")
	end
end

local function each(hotkeys, method)
	local errors = {}
	for index, hotkey in ipairs(hotkeys) do
		local ok, result = pcall(function()
			return hotkey[method](hotkey)
		end)
		if not ok or (method == "enable" and not result) then
			errors[#errors + 1] = "hotkey " .. index .. ": " .. (ok and "could not enable" or tostring(result))
		end
	end
	assert(#errors == 0, table.concat(errors, "\n"))
end

function M.create(bindings, scope)
	M.validate(bindings)
	local result = {}
	local ok, message = xpcall(function()
		for _, binding in ipairs(bindings) do
			local hotkey = hs.hotkey.new(
				binding.mods,
				binding.key,
				binding.action,
				nil,
				binding.repeatable and binding.action or nil
			)
			assert(hotkey, "Could not create hotkey: " .. scope .. " / " .. binding.key)
			result[#result + 1] = hotkey
		end
	end, debug.traceback)
	if not ok then
		pcall(M.delete, result)
		error(message, 0)
	end
	return result
end

function M.enable(hotkeys)
	each(hotkeys, "enable")
end

function M.disable(hotkeys)
	each(hotkeys, "disable")
end

function M.delete(hotkeys)
	each(hotkeys, "delete")
end

return M
