local M = {}

local pictures = os.getenv("HOME") .. "/Pictures"
local directory = pictures .. "/Screenshot"
local openDirectoryTag = "open-screenshot-directory"
local started = false

local function notify(title, message, callbackTag)
	hs.notify
		.new(callbackTag, {
			title = title,
			informativeText = message,
		})
		:send()
end

local function capture(target, kind, rect)
	if not target then
		notify("Screenshot failed", "No " .. kind .. " is available.")
		return
	end

	if not hs.screenRecordingState() then
		notify(
			"Screen Recording permission required",
			"Enable Hammerspoon in System Settings, then restart Hammerspoon."
		)
		return
	end

	local captured, image = pcall(function()
		local result = target:snapshot()
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
		notify("Screenshot failed", "Could not capture the " .. kind .. ".")
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

local picker = nil
local dimAlpha = 0.5

local function createMasks(state)
	state.masks = {}

	for _, screen in ipairs(hs.screen.allScreens()) do
		local frame = screen:fullFrame()
		local canvas = hs.canvas
			.new(frame)
			:level("overlay")
			:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
			:clickActivating(false)

		-- Four rectangles shade the screen around a transparent selection.
		for index = 1, 4 do
			canvas:appendElements({
				type = "rectangle",
				action = index == 1 and "fill" or "skip",
				frame = { x = 0, y = 0, w = frame.w, h = frame.h },
				fillColor = { white = 0, alpha = dimAlpha },
			})
		end
		canvas:appendElements({
			type = "rectangle",
			action = "skip",
			strokeColor = { red = 0.2, green = 0.6, blue = 1, alpha = 1 },
			strokeWidth = 2,
		})

		table.insert(state.masks, { canvas = canvas, frame = frame })
		canvas:show()
	end
end

local function updateMasks(state, selection)
	for _, mask in ipairs(state.masks) do
		local f = mask.frame
		local regions = { { x = 0, y = 0, w = f.w, h = f.h } }
		local borderFrame

		if selection then
			local left = math.max(f.x, selection.x) - f.x
			local top = math.max(f.y, selection.y) - f.y
			local right = math.min(f.x + f.w, selection.x + selection.w) - f.x
			local bottom = math.min(f.y + f.h, selection.y + selection.h) - f.y

			if right > left and bottom > top then
				-- Keep the actual selection edges when it spans multiple screens.
				borderFrame = {
					x = selection.x - f.x,
					y = selection.y - f.y,
					w = selection.w,
					h = selection.h,
				}
				regions = {
					{ x = 0, y = 0, w = f.w, h = top },
					{ x = 0, y = bottom, w = f.w, h = f.h - bottom },
					{ x = 0, y = top, w = left, h = bottom - top },
					{ x = right, y = top, w = f.w - right, h = bottom - top },
				}
			end
		end

		for index = 1, 4 do
			local region = regions[index]
			if region and region.w > 0 and region.h > 0 then
				mask.canvas[index].frame = region
				mask.canvas[index].action = "fill"
			else
				mask.canvas[index].action = "skip"
			end
		end

		if borderFrame then
			mask.canvas[5].frame = borderFrame
			mask.canvas[5].action = "stroke"
		else
			mask.canvas[5].action = "skip"
		end
	end
end

local function hideMasks(state)
	for _, mask in ipairs(state.masks) do
		mask.canvas:hide()
	end
end

local function stopPicking()
	if not picker then
		return
	end

	if picker.tap then
		picker.tap:stop()
	end
	if picker.masks then
		for _, mask in ipairs(picker.masks) do
			mask.canvas:delete()
		end
	end
	if picker.timer then
		picker.timer:stop()
	end

	picker = nil
end

function M.window()
	-- Clear any previous selection session.
	stopPicking()

	-- Cache windows before creating the screen overlays.
	local windows = {}

	for _, win in ipairs(hs.window.orderedWindows()) do
		if win:isStandard() then
			table.insert(windows, {
				window = win,
				frame = win:frame(),
			})
		end
	end

	if #windows == 0 then
		notify("Screenshot failed", "No selectable windows are available.")
		return
	end

	local state = {}
	picker = state
	createMasks(state)

	local function updateSelection(point)
		-- Windows are ordered from front to back.
		for _, item in ipairs(windows) do
			local f = item.frame

			if point.x >= f.x and point.x < f.x + f.w and point.y >= f.y and point.y < f.y + f.h then
				updateMasks(state, f)
				return item.window
			end
		end

		updateMasks(state)
	end

	local types = hs.eventtap.event.types

	state.tap = hs.eventtap
		.new({
			types.mouseMoved,
			types.leftMouseDown,
			types.leftMouseDragged,
			types.leftMouseUp,
			types.keyDown,
		}, function(event)
			local kind = event:getType()

			if kind == types.keyDown then
				if event:getKeyCode() == hs.keycodes.map.escape then
					stopPicking()
					return true
				end

				return false
			end

			local target = updateSelection(event:location())

			if kind == types.mouseMoved then
				return false
			elseif kind == types.leftMouseDown then
				state.pressedWindow = target
			elseif kind == types.leftMouseUp then
				if target and target == state.pressedWindow then
					state.tap:stop()
					hideMasks(state)

					-- Let the overlays disappear before taking the snapshot.
					state.timer = hs.timer.doAfter(0.05, function()
						stopPicking()
						capture(target, "window")
					end)
				else
					state.pressedWindow = nil
				end
			end

			-- Prevent the selection click from reaching the application.
			return true
		end)
		:start()

	if not state.tap:isEnabled() then
		stopPicking()
		notify("Window selection failed", "Could not start the mouse listener.")
		return
	end

	updateSelection(hs.mouse.absolutePosition())
end

function M.area()
	stopPicking()

	local state = {}
	picker = state
	createMasks(state)

	local function updateRectangle(point)
		local f = state.screenFrame
		local x = math.max(f.x, math.min(point.x, f.x + f.w))
		local y = math.max(f.y, math.min(point.y, f.y + f.h))
		local rect = {
			x = math.min(state.start.x, x),
			y = math.min(state.start.y, y),
			w = math.abs(x - state.start.x),
			h = math.abs(y - state.start.y),
		}
		state.rect = rect

		updateMasks(state, rect)
	end

	local types = hs.eventtap.event.types
	state.tap = hs.eventtap
		.new({
			types.leftMouseDown,
			types.leftMouseDragged,
			types.leftMouseUp,
			types.keyDown,
		}, function(event)
			local kind = event:getType()
			if kind == types.keyDown then
				if event:getKeyCode() == hs.keycodes.map.escape then
					stopPicking()
					return true
				end
				return false
			end

			if kind == types.leftMouseDown then
				state.screen = hs.mouse.getCurrentScreen()
				if state.screen then
					state.screenFrame = state.screen:fullFrame()
					state.start = event:location()
					updateRectangle(state.start)
				end
			elseif kind == types.leftMouseDragged and state.start then
				updateRectangle(event:location())
			elseif kind == types.leftMouseUp and state.start then
				updateRectangle(event:location())
				local rect = state.rect
				if rect.w < 2 or rect.h < 2 then
					state.start = nil
					updateMasks(state)
					return true
				end

				local screen = state.screen
				local localRect = screen:absoluteToLocal(rect)
				state.tap:stop()
				hideMasks(state)
				state.timer = hs.timer.doAfter(0.05, function()
					stopPicking()
					capture(screen, "area", localRect)
				end)
			end

			return true
		end)
		:start()

	if not state.tap:isEnabled() then
		stopPicking()
		notify("Area selection failed", "Could not start the mouse listener.")
	end
end

function M.screen()
	stopPicking()
	capture(hs.screen.mainScreen(), "screen")
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
	stopPicking()
	if started then
		hs.notify.unregister(openDirectoryTag)
		started = false
	end
end

return M
