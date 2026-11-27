local M = {}

local pictures = os.getenv("HOME") .. "/Pictures"
local directory = pictures .. "/Screenshot"
local openDirectoryTag = "open-screenshot-directory"
local started = false
local executable = os.getenv("HOME")
	.. "/Library/Application Support/Hammerspoon/ScreenshotPicker.app/Contents/MacOS/ScreenshotPicker"
local log = hs.logger.new("screenshot", "info")

local function notify(title, message, callbackTag)
	hs.notify
		.new(callbackTag, {
			title = title,
			informativeText = message,
		})
		:send()
end

local function reportError(save, title, message)
	if save then
		notify(title, message)
	else
		log.e(title .. ": " .. message)
	end
end

local function canCapture(save)
	if not hs.screenRecordingState() then
		reportError(
			save,
			"Screen Recording permission required",
			"Enable Hammerspoon in System Settings, then restart Hammerspoon."
		)
		return false
	end
	return true
end

local function snapshot(capture, ...)
	local ok, image = pcall(capture, ...)
	return ok and image or nil
end

local function outputImage(image, kind, save)
	if not image then
		reportError(save, "Screenshot failed", "Could not capture the " .. kind .. ".")
		return
	end

	if not save then
		if not hs.pasteboard.writeObjects(image) then
			log.e("Could not copy the screenshot to the clipboard.")
		end
		return
	end

	-- Create the output directory if needed.
	for _, path in ipairs({ pictures, directory }) do
		if hs.fs.attributes(path, "mode") ~= "directory" then
			local created = hs.fs.mkdir(path)
			if not created then
				notify("Screenshot failed", "Could not create: " .. path)
				return
			end
		end
	end

	-- Add a suffix when multiple screenshots share the same timestamp.
	local stem = string.format("%s/Screenshot-%s", directory, os.date("%Y-%m-%d_%H-%M-%S"))

	local path = stem .. ".png"
	local index = 1

	while hs.fs.attributes(path) do
		path = stem .. "-" .. index .. ".png"
		index = index + 1
	end

	local completed, saved = pcall(function()
		return image:saveToFile(path)
	end)

	if not completed or not saved then
		notify("Screenshot failed", "Could not save: " .. path)
		return
	end

	if hs.pasteboard.writeObjects(image) then
		local filename = path:match("[^/]+$")
		notify("Screenshot saved and copied", filename, openDirectoryTag)
	else
		notify("Screenshot saved", "Could not copy to clipboard.\n" .. path, openDirectoryTag)
	end
end

local picker

local function selectionError(save, message, detail)
	if detail and detail ~= "" then
		log.e(detail)
	end
	reportError(save, "Screenshot selection failed", message)
end

local function snapshotDisplays()
	local displays = {}
	for _, screen in ipairs(hs.screen.allScreens()) do
		local frame = screen:fullFrame()
		local image = snapshot(screen.snapshot, screen)
		if image then
			displays[screen:id()] = { frame = frame, image = image }
		end
	end
	return displays
end

local function snapshotWindows()
	local images, targets = {}, {}
	-- Keep Window Server order so hit testing starts with the frontmost window.
	for _, window in ipairs(hs.window.list(true) or {}) do
		local id = window.kCGWindowNumber
		local bounds = window.kCGWindowBounds
		if
			id
			and window.kCGWindowLayer == 0
			and (window.kCGWindowAlpha or 1) > 0
			and bounds
			and bounds.Width > 1
			and bounds.Height > 1
		then
			targets[#targets + 1] = { id = id, x = bounds.X, y = bounds.Y, w = bounds.Width, h = bounds.Height }
			images[id] = snapshot(hs.window.snapshotForID, id)
		end
	end
	return images, targets
end

local function outputSelection(result, kind, save, snapshots)
	if result.status == "cancelled" then
		if result.reason == "no-windows" then
			selectionError(save, "No selectable windows are available.")
		elseif result.reason == "no-display" then
			selectionError(save, "No display is available.")
		end
		return
	end
	if result.status ~= "selected" or result.mode ~= kind or result.coordinateSystem ~= "macOS-top-left-points" then
		selectionError(save, "The screenshot picker returned an invalid result.")
		return
	end
	local rect = result.rect
	for _, field in ipairs({ "x", "y", "w", "h" }) do
		local value = type(rect) == "table" and rect[field]
		if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
			selectionError(save, "The screenshot picker returned an invalid selection.")
			return
		end
	end
	if rect.w < 2 or rect.h < 2 then
		selectionError(save, "The selected area is too small.")
		return
	end

	if kind == "window" then
		if type(result.windowID) ~= "number" or result.windowID <= 0 or result.windowID % 1 ~= 0 then
			selectionError(save, "The screenshot picker returned an invalid window.")
			return
		end
		outputImage(snapshots[result.windowID], kind, save)
	else
		local display = type(result.screenID) == "number" and snapshots[result.screenID]
		if not display then
			selectionError(save, "Could not capture the selected display.")
			return
		end
		local frame = display.frame
		local screen = hs.screen.find(result.screenID)
		if
			not screen
			or screen:fullFrame() ~= frame
			or rect.x < frame.x - 0.01
			or rect.y < frame.y - 0.01
			or rect.x + rect.w > frame.x + frame.w + 0.01
			or rect.y + rect.h > frame.y + frame.h + 0.01
		then
			selectionError(save, "The display layout changed. Please select the area again.")
			return
		end
		local size = display.image:size()
		local image = display.image:croppedCopy({
			x = (rect.x - frame.x) * size.w / frame.w,
			y = (rect.y - frame.y) * size.h / frame.h,
			w = rect.w * size.w / frame.w,
			h = rect.h * size.h / frame.h,
		})
		outputImage(image, kind, save)
	end
end

local function requestCapture(kind, save)
	if not started or picker then
		return
	end
	if not canCapture(save) then
		return
	end
	if kind == "screen" then
		local screen = hs.screen.mainScreen()
		if screen then
			outputImage(snapshot(screen.snapshot, screen), kind, save)
		else
			reportError(save, "Screenshot failed", "No screen is available.")
		end
		return
	end
	if not hs.fs.attributes(executable) then
		selectionError(save, "Rebuild the screenshot picker using global/screenshot/build.sh.")
		return
	end

	-- Take every snapshot before the picker can cover the desktop or take focus.
	local snapshots, input
	if kind == "window" then
		local targets
		snapshots, targets = snapshotWindows()
		if #targets == 0 then
			selectionError(save, "No selectable windows are available.")
			return
		end
		input = hs.json.encode(targets)
	else
		snapshots = snapshotDisplays()
	end
	if not next(snapshots) then
		reportError(save, "Screenshot failed", "Could not capture any " .. (kind == "window" and "windows." or "displays."))
		return
	end
	if kind == "window" and not input then
		selectionError(save, "Could not prepare the window list.")
		return
	end

	local session = { snapshots = snapshots }
	picker = session
	session.task = hs.task.new(executable, function(exitCode, stdout, stderr)
		if picker ~= session then
			return
		end
		session.task = nil
		-- Keep ignoring requests until the overlays disappear and focus returns.
		session.timer = hs.timer.doAfter(0.1, function()
			if picker ~= session then
				return
			end
			picker = nil
			local images = session.snapshots
			session.snapshots = nil
			if exitCode ~= 0 then
				selectionError(
					save,
					"The screenshot picker exited unexpectedly. See Hammerspoon Console.",
					stderr ~= "" and stderr or ("Exit code: " .. exitCode)
				)
				return
			end
			local decoded, result = pcall(hs.json.decode, stdout)
			if not decoded or type(result) ~= "table" then
				selectionError(save, "The screenshot picker returned an invalid result.", stdout)
				return
			end
			local ok, message = xpcall(function()
				outputSelection(result, kind, save, images)
			end, debug.traceback)
			if not ok then
				selectionError(save, "Could not finish the screenshot. See Hammerspoon Console.", message)
			end
		end)
	end, input and { kind, "--targets-stdin" } or { kind })
	if session.task and input then
		session.task:setInput(input)
	end
	if not session.task or not session.task:start() then
		picker = nil
		session.snapshots = nil
		selectionError(save, "Could not start the screenshot picker.")
	end
end

local function stopPicking()
	local previous = picker
	picker = nil
	if previous then
		previous.snapshots = nil
		if previous.timer then
			previous.timer:stop()
		end
		if previous.task then
			previous.task:terminate()
		end
	end
end

function M.window(save)
	requestCapture("window", save ~= false)
end

function M.area(save)
	requestCapture("area", save ~= false)
end

function M.screen(save)
	requestCapture("screen", save ~= false)
end

function M.start()
	if not started then
		hs.notify.register(openDirectoryTag, function()
			hs.open(directory)
		end)
		started = true
	end
end

function M.stop()
	started = false
	stopPicking()
	hs.notify.unregister(openDirectoryTag)
end

M.hotkeys = {}
for _, binding in ipairs({
	{ key = "a", action = M.area },
	{ key = "w", action = M.window },
	{ key = "s", action = M.screen },
}) do
	M.hotkeys[#M.hotkeys + 1] = {
		mods = { "ctrl" },
		key = binding.key,
		action = function()
			binding.action(false)
		end,
	}
	M.hotkeys[#M.hotkeys + 1] = { mods = { "ctrl", "shift" }, key = binding.key, action = binding.action }
end

return M
