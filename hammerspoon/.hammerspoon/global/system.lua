return {
	hotkeys = {
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
	},
}
