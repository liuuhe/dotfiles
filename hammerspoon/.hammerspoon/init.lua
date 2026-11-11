local hotkeys = require("hotkeys")
local log = hs.logger.new("config", "info")
local config = { running = false, modules = {}, apps = {}, errors = {} }
hammerspoonConfig = config

local function reportError(name, trace)
	config.errors[name] = trace
	log.e(name .. "\n" .. tostring(trace))
	hs.notify
		.new({
			title = "Hammerspoon configuration error",
			informativeText = name .. " failed. See Hammerspoon Console for details.",
		})
		:send()
end

local function attempt(name, action)
	local ok, result = xpcall(action, debug.traceback)
	if not ok then
		reportError(name, result)
	end
	return ok, result
end

local function stopModule(record)
	if record.hotkeys then
		attempt(record.name .. " hotkeys cleanup", function()
			hotkeys.delete(record.hotkeys)
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
		if not isApp then
			assert(module.start and module.stop, "resource modules must provide start and stop")
		end
		record.module = module

		if isApp then
			assert(type(module.bundleID) == "string" and module.bundleID ~= "", "bundleID must be a non-empty string")
			assert(not config.apps[module.bundleID], "duplicate bundleID: " .. module.bundleID)
			record.bundleID = module.bundleID
			record.hotkeys = hotkeys.create(module.hotkeys, name)
		end
		if module.start then
			record.state = module.start()
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

local function startApps()
	local directory = hs.configdir .. "/apps"
	local names = {}
	for filename in hs.fs.dir(directory) do
		local name = filename:match("^([%w_-]+)%.lua$")
		if name and hs.fs.attributes(directory .. "/" .. filename, "mode") == "file" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		startModule("apps." .. name, true)
	end
end

local function switchToApp(bundleID)
	if bundleID == config.activeBundleID then
		return
	end
	local previous = config.apps[config.activeBundleID]
	if previous then
		attempt(previous.name .. " disable", function()
			hotkeys.disable(previous.hotkeys)
		end)
	end
	config.activeBundleID = bundleID
	local current = config.apps[bundleID]
	if current then
		local ok = attempt(current.name .. " enable", function()
			hotkeys.enable(current.hotkeys)
		end)
		if not ok then
			attempt(current.name .. " disable", function()
				hotkeys.disable(current.hotkeys)
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
			-- Track directory identities so symlinked modules are checked without cycles.
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
		-- Compile only: no module code runs until every file passes.
		local chunk, message = loadfile(path, "t")
		if not chunk then
			config.errors.reload = message
			log.e("Reload skipped: " .. path .. "\n" .. tostring(message))
			hs.notify
				.new({
					title = "Hammerspoon reload skipped",
					informativeText = path:sub(#hs.configdir + 2) .. "\n" .. tostring(message),
				})
				:send()
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
	startModule("screenshot")
	startModule("global")
	attempt("apps discovery", startApps)
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
hs.notify
	.new({
		title = "Hammerspoon",
		informativeText = next(config.errors) and "Config loaded with errors. See Hammerspoon Console."
			or "Config loaded",
	})
	:send()
