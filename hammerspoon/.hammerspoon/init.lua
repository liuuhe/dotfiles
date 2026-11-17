local log = hs.logger.new("config", "info")
local config = { running = false, modules = {}, apps = {}, errors = {} }
hammerspoonConfig = config

local function reportError(name, trace)
	config.errors[name] = trace
	log.e(name .. "\n" .. tostring(trace))
	hs.notify.new({
		title = "Hammerspoon configuration error",
		informativeText = name .. " failed. See Hammerspoon Console for details.",
	}):send()
end

local function attempt(name, action)
	local ok, result = xpcall(action, debug.traceback)
	if not ok then
		reportError(name, result)
	end
	return ok, result
end

local function listLength(value, label)
	assert(type(value) == "table", label .. " must be a list")
	local count = 0
	for index in pairs(value) do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0, label .. " must be a list")
		count = count + 1
	end
	for index = 1, count do
		assert(value[index] ~= nil, label .. " must not contain gaps")
	end
	return count
end

local function validateBindings(bindings)
	local modifiers = {
		cmd = true, command = true, ["⌘"] = true,
		ctrl = true, control = true, ["⌃"] = true,
		alt = true, option = true, ["⌥"] = true,
		shift = true, ["⇧"] = true, fn = true,
	}
	for index = 1, listLength(bindings, "hotkeys") do
		local binding = bindings[index]
		local label = "hotkeys[" .. index .. "]"
		assert(type(binding) == "table", label .. " must be a table")
		for modifierIndex = 1, listLength(binding.mods, label .. ".mods") do
			local modifier = binding.mods[modifierIndex]
			assert(type(modifier) == "string" and modifiers[modifier], label .. ".mods contains an invalid modifier")
		end
		assert(type(binding.key) == "string" and binding.key ~= "", label .. ".key must be a non-empty string")
		assert(type(binding.action) == "function", label .. ".action must be a function")
		assert(binding.repeatable == nil or type(binding.repeatable) == "boolean", label .. ".repeatable must be a boolean")
	end
end

local function changeHotkeys(keys, method)
	local errors = {}
	for index, hotkey in ipairs(keys) do
		local ok, result = pcall(function()
			return hotkey[method](hotkey)
		end)
		if not ok or (method == "enable" and not result) then
			errors[#errors + 1] = "hotkey " .. index .. ": " .. (ok and "could not enable" or tostring(result))
		end
	end
	assert(#errors == 0, table.concat(errors, "\n"))
end

local function createHotkeys(bindings)
	validateBindings(bindings)
	local keys = {}
	local ok, message = xpcall(function()
		for _, binding in ipairs(bindings) do
			local key = hs.hotkey.new(binding.mods, binding.key, binding.action, nil,
				binding.repeatable and binding.action or nil)
			assert(key, "Could not create hotkey: " .. binding.key)
			keys[#keys + 1] = key
		end
	end, debug.traceback)
	if not ok then
		pcall(changeHotkeys, keys, "delete")
		error(message, 0)
	end
	return keys
end

local function stopModule(record)
	if record.hotkeys then
		attempt(record.name .. " hotkeys cleanup", function()
			changeHotkeys(record.hotkeys, "delete")
		end)
	end
	if record.module and record.module.stop then
		attempt(record.name .. " stop", record.module.stop)
	end
end

local function startModule(name, isApp)
	local record = { name = name }
	local ok = attempt(name, function()
		local module = require(name)
		assert(type(module) == "table", "module must return a table")
		assert(module.start == nil or type(module.start) == "function", "start must be a function")
		assert(module.stop == nil or type(module.stop) == "function", "stop must be a function")
		assert((module.start == nil) == (module.stop == nil), "start and stop must be provided together")
		record.module = module

		if isApp then
			assert(type(module.bundleID) == "string" and module.bundleID ~= "", "bundleID must be a non-empty string")
			assert(not config.apps[module.bundleID], "duplicate bundleID: " .. module.bundleID)
			record.bundleID = module.bundleID
		end
		record.hotkeys = createHotkeys(module.hotkeys == nil and {} or module.hotkeys)
		if module.start then
			module.start()
		end
		if not isApp then
			changeHotkeys(record.hotkeys, "enable")
		end
	end)
	if not ok then
		stopModule(record)
		return
	end
	config.modules[#config.modules + 1] = record
	if isApp then
		config.apps[record.bundleID] = record
	end
end

local function startGroup(group)
	local directory = hs.configdir .. "/" .. group
	local names = {}
	for filename in hs.fs.dir(directory) do
		local path = directory .. "/" .. filename
		local mode = hs.fs.attributes(path, "mode")
		local name
		if mode == "file" then
			name = filename:match("^([%w_-]+)%.lua$")
		elseif mode == "directory" and filename:match("^[%w_-]+$")
			and hs.fs.attributes(path .. "/init.lua", "mode") == "file" then
			name = filename
		end
		if name then
			assert(not names[name], "duplicate module: " .. group .. "." .. name)
			names[name] = true
		end
	end
	local sorted = {}
	for name in pairs(names) do
		sorted[#sorted + 1] = name
	end
	table.sort(sorted)
	for _, name in ipairs(sorted) do
		startModule(group .. "." .. name, group == "apps")
	end
end

local function switchToApp(bundleID)
	if bundleID == config.activeBundleID then
		return
	end
	local previous = config.apps[config.activeBundleID]
	if previous then
		attempt(previous.name .. " disable", function()
			changeHotkeys(previous.hotkeys, "disable")
		end)
	end
	config.activeBundleID = bundleID
	local current = config.apps[bundleID]
	if current then
		local ok = attempt(current.name .. " enable", function()
			changeHotkeys(current.hotkeys, "enable")
		end)
		if not ok then
			attempt(current.name .. " disable", function()
				changeHotkeys(current.hotkeys, "disable")
			end)
		end
	end
end

local function collectLuaFiles(directory, result, visited)
	local attributes = assert(hs.fs.attributes(directory), "Could not read directory: " .. directory)
	local identity = tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
	if visited[identity] then
		return
	end
	visited[identity] = true
	for filename in hs.fs.dir(directory) do
		if filename:sub(1, 1) ~= "." then
			local path = directory .. "/" .. filename
			local mode = hs.fs.attributes(path, "mode")
			if mode == "directory" then
				collectLuaFiles(path, result, visited)
			elseif filename:sub(-4) == ".lua" and mode == "file" then
				result[#result + 1] = path
			end
		end
	end
end

local function reloadIfValid()
	local ok, files = attempt("reload file discovery", function()
		local result = {}
		collectLuaFiles(hs.configdir, result, {})
		table.sort(result)
		return result
	end)
	if not ok then
		return
	end
	for _, path in ipairs(files) do
		-- Compile only: preserve the current configuration if any file has a syntax error.
		local chunk, message = loadfile(path, "t")
		if not chunk then
			config.errors.reload = message
			log.e("Reload skipped: " .. path .. "\n" .. tostring(message))
			hs.notify.new({
				title = "Hammerspoon reload skipped",
				informativeText = path:sub(#hs.configdir + 2) .. "\n" .. tostring(message),
			}):send()
			return
		end
	end
	hs.reload()
end

function config.start()
	if config.running then
		return
	end
	config.running = true
	config.errors = {}
	for _, group in ipairs({ "global", "apps" }) do
		attempt(group .. " discovery", function()
			startGroup(group)
		end)
	end
	attempt("application watcher", function()
		config.appWatcher = hs.application.watcher.new(function(_, event, app)
			if event == hs.application.watcher.activated then
				switchToApp(app and app:bundleID())
			end
		end)
		config.appWatcher:start()
		local app = hs.application.frontmostApplication()
		switchToApp(app and app:bundleID())
	end)
	attempt("reload watcher", function()
		config.reloadTimer = hs.timer.delayed.new(0.2, reloadIfValid)
		config.reloadWatcher = hs.pathwatcher.new(hs.configdir, function(files)
			for _, path in ipairs(files) do
				if path:sub(-4) == ".lua" then
					config.reloadTimer:start()
					break
				end
			end
		end)
		config.reloadWatcher:start()
	end)
end

function config.stop()
	config.running = false
	for _, field in ipairs({ "reloadWatcher", "reloadTimer", "appWatcher" }) do
		local resource = config[field]
		if resource then
			attempt(field .. " cleanup", function()
				resource:stop()
			end)
			config[field] = nil
		end
	end
	for index = #config.modules, 1, -1 do
		stopModule(config.modules[index])
	end
	config.modules = {}
	config.apps = {}
	config.activeBundleID = nil
end

hs.shutdownCallback = config.stop
config.start()
hs.notify.new({
	title = "Hammerspoon",
	informativeText = next(config.errors) and "Config loaded with errors. See Hammerspoon Console." or "Config loaded",
}):send()
