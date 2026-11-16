local bundleID = "net.sourceforge.skim-app.skim"
local log = hs.logger.new("skim", "info")
local M = { bundleID = bundleID }
local state = { enabled = true, running = false, cache = {}, errors = {}, versions = {}, pendingUpdate = false }
local updateSmartInvert

local function notify(message)
	hs.notify.new({ title = "Skim", informativeText = message }):send()
end

local function reportError(message, detail)
	if not state.errors[message] then
		state.errors[message] = true
		log.e(message .. (detail and ("\n" .. tostring(detail)) or ""))
		notify(message)
	end
end

local function isFrontmost()
	local app = hs.application.frontmostApplication()
	return app and app:bundleID() == bundleID
end

local function requestUpdate()
	if state.running then
		state.pendingUpdate = true
		if not state.request then
			state.refresh:start()
		end
	end
end

-- Serialize AppleScript work without blocking Hammerspoon's Lua event loop.
local function runScript(script, arguments, timeout, callback, cleanup)
	if not state.running or state.request then
		if state.running then
			requestUpdate()
		end
		if cleanup then
			cleanup()
		end
		return
	end
	local request = {}
	state.request = request

	local function clean()
		if cleanup then
			local ok, message = pcall(cleanup)
			if not ok then
				log.e("PDF analysis cleanup failed.\n" .. tostring(message))
			end
		end
	end

	local function finish(exitCode, stdout, stderr)
		if request.finished then
			-- A terminated exporter may finish after its first cleanup.
			clean()
			return
		end
		request.finished = true
		if request.deadline then
			request.deadline:stop()
		end
		if state.request == request then
			state.request = nil
		end
		if state.running and not request.cancelled then
			local ok, message = xpcall(function()
				callback(exitCode, stdout or "", request.timedOut and "AppleScript timed out." or (stderr or ""))
			end, debug.traceback)
			if not ok then
				reportError("Smart Invert encountered an error. See Hammerspoon Console.", message)
			end
		end
		clean()
		-- Replay events received during the query/analysis/write sequence once idle.
		if state.running and state.pendingUpdate and not state.request then
			state.refresh:start()
		end
	end
	request.finish = finish

	local taskArguments = { "-e", script }
	for _, argument in ipairs(arguments or {}) do
		taskArguments[#taskArguments + 1] = argument
	end
	local created, task = pcall(hs.task.new, "/usr/bin/osascript", finish, taskArguments)
	if not created or not task then
		finish(-1, "", created and "Could not create AppleScript task." or tostring(task))
		return
	end
	request.task = task
	request.deadline = hs.timer.doAfter(timeout, function()
		request.timedOut = true
		task:terminate()
		finish(-1, "", "AppleScript timed out.")
	end)
	local started, result = pcall(function()
		return task:start()
	end)
	if not started or not result then
		finish(-1, "", started and "Could not start AppleScript task." or tostring(result))
	end
end

local function cancelRequest()
	local request = state.request
	if request then
		request.cancelled = true
		if request.task then
			request.task:terminate()
		end
		request.finish(-1, "", "Cancelled")
	end
end

local queryScript = [[
with timeout of 1 seconds
    tell application id "net.sourceforge.skim-app.skim"
        if not frontmost then return ""
        if (count of documents) is 0 then return ""
        set doc to front document
        if not (containing PDF of doc) then return ""
        set documentPath to path of doc
        if documentPath is missing value then return ""
        set prefs to (get preferences for normal mode)
        return ((count of pages of doc) as text) & linefeed & ((get inverted of prefs) as text) & linefeed & documentPath
    end tell
end timeout
]]

local inversionScript = [[
on run argv
    set wantedInversion to ((item 1 of argv) is "true")
    set expectedPath to item 2 of argv
    with timeout of 2 seconds
        tell application id "net.sourceforge.skim-app.skim"
            if not frontmost then return false
            if expectedPath is not "" then
                if (count of documents) is 0 then return false
                if (path of front document) is not expectedPath then return false
            end if
            set prefs to (get preferences for normal mode)
            if (get inverted of prefs) is not wantedInversion then set inverted of prefs to wantedInversion
            return true
        end tell
    end timeout
end run
]]

local function fileVersion(doc)
	local attributes = hs.fs.attributes(doc.path)
	if attributes then
		return table.concat(
			{ attributes.modification, attributes.change, attributes.size, attributes.ino, doc.pages },
			":"
		)
	end
end

local function setInversion(enabled, doc)
	if not state.running or not isFrontmost() then
		return
	end
	if doc and doc.inverted == enabled then
		return
	end
	runScript(inversionScript, { tostring(enabled), doc and doc.path or "" }, 4, function(exitCode, stdout, stderr)
		if exitCode ~= 0 then
			reportError("Could not update color inversion. Switch documents or return to Skim to retry.", stderr)
		elseif stdout:match("^true%s*$") then
			if not enabled then
				state.pendingDisable = false
			end
		else
			-- Skim or its front document changed before the write.
			requestUpdate()
		end
	end)
end

local function samplePages(count)
	if count <= 3 then
		local pages = {}
		for index = 1, count do
			pages[index] = index
		end
		return pages
	end
	-- Skip the cover and sample the beginning, middle, and end of the body.
	return { 2, math.floor((count + 2) / 2), count }
end

local function hasLightBackground(path)
	local image = hs.image.imageFromPath(path)
	if not image then
		error("Could not load PDF sample: " .. path)
	end
	image = image:bitmapRepresentation({ w = 64, h = 64 })
	if not image then
		error("Could not decode PDF sample: " .. path)
	end

	local light, dark, edgeLight, edgeCount, innerLight, innerCount = 0, 0, 0, 0, 0, 0
	local size = image:size()
	if not size or size.w <= 0 or size.h <= 0 then
		error("PDF sample has no readable pixels: " .. path)
	end
	for row = 0, 15 do
		for column = 0, 15 do
			local color = image:colorAt({ x = (column + 0.5) * size.w / 16, y = (row + 0.5) * size.h / 16 })
			color = color and hs.drawing.color.asRGB(color)
			if
				type(color) ~= "table"
				or type(color.red) ~= "number"
				or type(color.green) ~= "number"
				or type(color.blue) ~= "number"
				or (color.alpha ~= nil and type(color.alpha) ~= "number")
			then
				error("Could not read PDF sample colors: " .. path)
			end
			local alpha = color.alpha or 1
			local brightness = alpha * (0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue) + 1 - alpha
			local isLight = brightness >= 0.65
			light = light + (isLight and 1 or 0)
			dark = dark + (brightness <= 0.35 and 1 or 0)
			if row < 3 or row > 12 or column < 3 or column > 12 then
				edgeCount = edgeCount + 1
				edgeLight = edgeLight + (isLight and 1 or 0)
			else
				innerCount = innerCount + 1
				innerLight = innerLight + (isLight and 1 or 0)
			end
		end
	end

	-- Only a successfully decoded page can produce a light/dark result.
	return light / 256 >= 0.65
		and dark / 256 <= 0.25
		and innerLight / innerCount >= 0.6
		and (edgeLight / edgeCount >= 0.6 or light / 256 >= 0.8)
end

local exportScript = [[
on writeImage(imageData, outputPath)
    set outputFile to open for access (POSIX file outputPath) with write permission
    try
        set eof outputFile to 0
        write imageData to outputFile
        close access outputFile
    on error errorMessage number errorNumber
        try
            close access outputFile
        end try
        error errorMessage number errorNumber
    end try
end writeImage

on run argv
    set expectedPath to item 1 of argv
    with timeout of 10 seconds
        tell application id "net.sourceforge.skim-app.skim"
            if not frontmost then return false
            if (count of documents) is 0 then return false
            set doc to front document
            if (path of doc) is not expectedPath then return false
            repeat with argumentIndex from 2 to (count of argv) by 2
                if (path of doc) is not expectedPath then return false
                set pageNumber to (item argumentIndex of argv) as integer
                set outputPath to item (argumentIndex + 1) of argv
                set sampledPage to page pageNumber of doc
                set pageBounds to bounds of sampledPage
                set imageData to grab sampledPage for pageBounds as TIFF picture
                my writeImage(imageData, outputPath)
            end repeat
            return true
        end tell
    end timeout
end run
]]

local function failedAnalysis(detail)
	-- Cache successful classifications only; a later event can retry a failure.
	reportError("Could not analyze this PDF. Switch documents or return to Skim to retry.", detail)
end

local function analyzeDocument(doc, version)
	local prepared, directory = pcall(os.tmpname)
	if not prepared then
		failedAnalysis(directory)
		return
	end
	os.remove(directory)
	if not hs.fs.mkdir(directory) then
		failedAnalysis("Could not prepare the PDF analysis directory.")
		return
	end
	local files = {}
	local arguments = { doc.path }
	for _, page in ipairs(samplePages(doc.pages)) do
		local path = string.format("%s/page-%d.tiff", directory, page)
		files[#files + 1] = path
		arguments[#arguments + 1] = tostring(page)
		arguments[#arguments + 1] = path
	end
	local function cleanup()
		for _, path in ipairs(files) do
			os.remove(path)
		end
		hs.fs.rmdir(directory)
	end

	runScript(exportScript, arguments, 12, function(exitCode, stdout, stderr)
		if fileVersion(doc) ~= version then
			requestUpdate()
			return
		end
		if exitCode ~= 0 then
			failedAnalysis(stderr)
			return
		end
		if not stdout:match("^true%s*$") then
			requestUpdate()
			return
		end
		local ok, invert = xpcall(function()
			local lightPages = 0
			for _, path in ipairs(files) do
				if hasLightBackground(path) then
					lightPages = lightPages + 1
				end
			end
			return lightPages > #files / 2
		end, debug.traceback)
		if not ok then
			failedAnalysis(invert)
			return
		end
		state.cache[doc.path] = { version = version, invert = invert }
		if state.enabled then
			setInversion(invert, doc)
		end
	end, cleanup)
end

local function processDocument(doc)
	local version = fileVersion(doc)
	if not version then
		return
	end
	local now = hs.timer.secondsSinceEpoch()
	local observed = state.versions[doc.path]
	if not observed or observed.version ~= version then
		-- New documents can be analyzed immediately; updated files must settle.
		observed = { version = version, readyAt = observed and (now + 0.75) or now }
		state.versions[doc.path] = observed
	end
	local cached = state.cache[doc.path]
	if cached and cached.version == version then
		setInversion(cached.invert, doc)
		return
	end
	-- Keep the current appearance until the final document result is available.
	if now >= observed.readyAt then
		analyzeDocument(doc, version)
	else
		-- One follow-up for this file change; no periodic polling is needed.
		state.refresh:start(observed.readyAt - now)
	end
end

updateSmartInvert = function()
	if not state.running then
		return
	end
	state.refresh:stop()
	if state.request then
		state.pendingUpdate = true
		return
	end
	state.pendingUpdate = false
	if not isFrontmost() then
		return
	end
	if not state.enabled then
		if state.pendingDisable then
			setInversion(false)
		end
		return
	end
	runScript(queryScript, {}, 3, function(exitCode, stdout, stderr)
		if exitCode ~= 0 then
			reportError("Could not read the current PDF. Switch documents or return to Skim to retry.", stderr)
			return
		end
		if not state.enabled or not isFrontmost() then
			return
		end
		-- Remove osascript's final newline only; the path may contain newlines.
		local output = stdout:gsub("\n$", "")
		if output == "" then
			return
		end
		local pages, inverted, path = output:match("^(%d+)\n(%a+)\n(.*)$")
		pages = tonumber(pages)
		if not pages or pages < 1 or not path or path == "" or (inverted ~= "true" and inverted ~= "false") then
			reportError(
				"Could not read the current PDF. Switch documents or return to Skim to retry.",
				"Unexpected AppleScript response."
			)
			return
		end
		processDocument({ path = path, pages = pages, inverted = inverted == "true" })
	end)
end

local function toggleSmartInvert()
	if not state.running then
		return
	end
	state.pendingUpdate = false
	cancelRequest()
	state.enabled = not state.enabled
	state.errors = {}
	state.pendingDisable = not state.enabled
	updateSmartInvert()
	notify(state.enabled and "Smart Invert enabled" or "Smart Invert disabled")
end

function M.start()
	if state.running then
		return state
	end
	state.running = true
	state.errors = {}
	state.pendingUpdate = false
	state.pendingDisable = not state.enabled
	state.refresh = hs.timer.delayed.new(0.05, updateSmartInvert)

	-- Defer event callbacks briefly so Skim can update its front document.
	local events = hs.window.filter
	state.windowFilter = events.new(function(win)
		local app = win:application()
		return app and app:bundleID() == bundleID and win:isStandard()
	end)
	state.windowFilter:subscribe({
		events.windowCreated,
		events.windowFocused,
		events.windowTitleChanged,
	}, requestUpdate)
	state.appWatcher = hs.application.watcher.new(function(_, event, app)
		if event == hs.application.watcher.activated and app and app:bundleID() == bundleID then
			requestUpdate()
		end
	end)
	state.appWatcher:start()

	requestUpdate()
	return state
end

function M.stop()
	state.running = false
	state.pendingUpdate = false
	cancelRequest()
	for _, field in ipairs({ "refresh", "appWatcher" }) do
		if state[field] then
			state[field]:stop()
			state[field] = nil
		end
	end
	if state.windowFilter then
		state.windowFilter:unsubscribeAll()
		state.windowFilter = nil
	end
end

local function pageKey(key)
	return function()
		local app = hs.application.frontmostApplication()
		if app and app:bundleID() == bundleID then
			-- Send only Option, with no default keystroke delay.
			hs.eventtap.keyStroke({ "alt" }, key, 0, app)
		end
	end
end

M.hotkeys = {
	{ mods = { "cmd" }, key = "d", action = toggleSmartInvert },
	{ mods = { "cmd" }, key = "j", action = pageKey("down"), repeatable = true },
	{ mods = { "cmd" }, key = "k", action = pageKey("up"), repeatable = true },
	{
		mods = { "cmd" },
		key = "t",
		action = function()
			local app = hs.application.frontmostApplication()
			if not app then
				return
			end
			if not app:selectMenuItem({ "View", "Show Contents Pane" }) then
				app:selectMenuItem({ "View", "Hide Contents Pane" })
			end
		end,
	},
}

return M
