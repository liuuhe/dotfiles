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

local function capture(target, kind, save, rect)
	if not target then
		reportError(save, "Screenshot failed", "No " .. kind .. " is available.")
		return
	end
	if not canCapture(save) then
		return
	end

	local captured, image = pcall(function()
		local result
		if kind == "window" then
			result = hs.window.snapshotForID(target)
		else
			result = target:snapshot()
		end
		if result and rect then
			local frame = target:fullFrame()
			local size = result:size()
			result = result:croppedCopy({
				x = rect.x * size.w / frame.w,
				y = rect.y * size.h / frame.h,
				w = rect.w * size.w / frame.w,
				h = rect.h * size.h / frame.h,
			})
		end
		return result
	end)

	if not captured or not image then
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

local function captureSelection(result, kind, save)
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
		capture(result.windowID, "window", save)
	else
		local screen = type(result.screenID) == "number" and hs.screen.find(result.screenID)
		if not screen then
			selectionError(save, "The selected display is no longer available.")
			return
		end
		local frame = screen:fullFrame()
		if
			rect.x < frame.x - 0.01
			or rect.y < frame.y - 0.01
			or rect.x + rect.w > frame.x + frame.w + 0.01
			or rect.y + rect.h > frame.y + frame.h + 0.01
		then
			selectionError(save, "The display layout changed. Please select the area again.")
			return
		end
		capture(screen, "area", save, screen:absoluteToLocal(rect))
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
		capture(hs.screen.mainScreen(), "screen", save)
		return
	end
	if not hs.fs.attributes(executable) then
		selectionError(save, "Rebuild the screenshot picker using global/screenshot/build.sh.")
		return
	end

	local session = {}
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
				captureSelection(result, kind, save)
			end, debug.traceback)
			if not ok then
				selectionError(save, "Could not finish the screenshot. See Hammerspoon Console.", message)
			end
		end)
	end, { kind })
	if not session.task or not session.task:start() then
		picker = nil
		selectionError(save, "Could not start the screenshot picker.")
	end
end

local function stopPicking()
	local previous = picker
	picker = nil
	if previous then
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
