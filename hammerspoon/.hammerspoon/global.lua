local hotkeys = require("hotkeys")
local screenshot = require("screenshot")
local M = {}
local keys

local bindings = {
	{
		mods = { "alt" },
		key = "f",
		action = function()
			local win = hs.window.focusedWindow()
			if win then
				win:setFrame(win:screen():frame())
			end
		end,
	},
	{
		mods = { "alt" },
		key = "i",
		action = function()
			local app = hs.application.frontmostApplication()
			if app then
				local bundleID = app:bundleID()
				local copied = bundleID and hs.pasteboard.setContents(bundleID)
				hs.notify
					.new({
						title = copied and "Bundle ID copied" or "Check Bundle ID",
						informativeText = bundleID or "Unknown Bundle ID",
					})
					:send()
			end
		end,
	},
	{
		mods = { "ctrl" },
		key = "a",
		action = screenshot.area,
	},
	{
		mods = { "ctrl" },
		key = "w",
		action = screenshot.window,
	},
	{
		mods = { "ctrl" },
		key = "s",
		action = screenshot.screen,
	},
}

function M.start()
	if not keys then
		keys = hotkeys.create(bindings, "Global")
		hotkeys.enable(keys)
	end
	return keys
end

function M.stop()
	if keys then
		local previous = keys
		keys = nil
		hotkeys.delete(previous)
	end
end

return M
