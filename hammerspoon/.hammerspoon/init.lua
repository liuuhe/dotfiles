local modules = {
	"global.mouse",
	"global.rime",
	"global.screenshot",
	"global.system",
	"apps.chrome",
	"apps.skim",
}

local log = hs.logger.new("config", "info")
local loaded, apps = {}, {}
local activeApp, appWatcher, reloadWatcher, reloadTimer
local hadErrors = false

local function attempt(name, action)
	local ok, result = xpcall(action, debug.traceback)
	if not ok then
		hadErrors = true
		log.e(name .. "\n" .. tostring(result))
		hs.notify
			.new({
				title = "Hammerspoon configuration error",
				informativeText = name .. " failed. See Hammerspoon Console for details.",
			})
			:send()
	end
	return ok
end

local function changeHotkeys(keys, method)
	local errors = {}
	for index, key in ipairs(keys) do
		local ok, result = pcall(key[method], key)
		if not ok or (method == "enable" and not result) then
			errors[#errors + 1] = "hotkey " .. index .. ": " .. (ok and "could not enable" or tostring(result))
		end
	end
	assert(#errors == 0, table.concat(errors, "\n"))
end

local function stopModule(record)
	attempt(record.name .. " hotkeys cleanup", function()
		changeHotkeys(record.hotkeys, "delete")
	end)
	if record.module and record.module.stop then
		attempt(record.name .. " stop", record.module.stop)
	end
end

local function startModule(name)
	local record = { name = name, hotkeys = {} }
	local ok = attempt(name, function()
		local module = require(name)
		assert(type(module) == "table", "module must return a table")
		record.module = module
		for _, binding in ipairs(module.hotkeys or {}) do
			local key = hs.hotkey.new(
				binding.mods,
				binding.key,
				binding.action,
				nil,
				binding.repeatable and binding.action or nil
			)
			assert(key, "Could not create hotkey: " .. binding.key)
			record.hotkeys[#record.hotkeys + 1] = key
		end
		if module.start then
			module.start()
		end
		if not module.bundleID then
			changeHotkeys(record.hotkeys, "enable")
		end
	end)
	if not ok then
		stopModule(record)
		return
	end
	loaded[#loaded + 1] = record
	if record.module.bundleID then
		apps[record.module.bundleID] = record
	end
end

local function switchToApp(bundleID)
	local current = apps[bundleID]
	if current == activeApp then
		return
	end
	if activeApp then
		attempt(activeApp.name .. " disable", function()
			changeHotkeys(activeApp.hotkeys, "disable")
		end)
	end
	activeApp = current
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

local function checkLuaFiles(directory)
	for filename in hs.fs.dir(directory) do
		if filename:sub(1, 1) ~= "." then
			local path = directory .. "/" .. filename
			-- Do not follow directory symlinks outside the configuration tree.
			local mode = hs.fs.symlinkAttributes(path, "mode")
			if mode == "directory" then
				checkLuaFiles(path)
			elseif mode == "file" and filename:sub(-4) == ".lua" then
				assert(loadfile(path, "t"))
			end
		end
	end
end

local function reloadIfValid()
	if
		attempt("reload syntax check", function()
			assert(loadfile(hs.configdir .. "/init.lua", "t"))
			checkLuaFiles(hs.configdir .. "/global")
			checkLuaFiles(hs.configdir .. "/apps")
		end)
	then
		hs.reload()
	end
end

hs.shutdownCallback = function()
	for _, resource in pairs({ reloadWatcher, reloadTimer, appWatcher }) do
		attempt("watcher cleanup", function()
			resource:stop()
		end)
	end
	for index = #loaded, 1, -1 do
		stopModule(loaded[index])
	end
end

for _, name in ipairs(modules) do
	startModule(name)
end

attempt("application watcher", function()
	appWatcher = hs.application.watcher.new(function(_, event, app)
		if event == hs.application.watcher.activated then
			switchToApp(app and app:bundleID())
		end
	end)
	appWatcher:start()
	local app = hs.application.frontmostApplication()
	switchToApp(app and app:bundleID())
end)

attempt("reload watcher", function()
	reloadTimer = hs.timer.delayed.new(0.2, reloadIfValid)
	reloadWatcher = hs.pathwatcher.new(hs.configdir, function(files)
		for _, path in ipairs(files) do
			if path:sub(-4) == ".lua" then
				reloadTimer:start()
				break
			end
		end
	end)
	reloadWatcher:start()
end)

hs.notify
	.new({
		title = "Hammerspoon",
		informativeText = hadErrors and "Config loaded with errors. See Hammerspoon Console." or "Config loaded",
	})
	:send()
