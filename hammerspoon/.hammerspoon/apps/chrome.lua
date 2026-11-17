local function selectMenu(menuPath)
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

return {
	bundleID = "com.google.Chrome",
	hotkeys = {
		{
			mods = { "cmd" },
			key = "j",
			action = selectMenu({ "Tab", "Select Next Tab" }),
		},
		{
			mods = { "cmd" },
			key = "k",
			action = selectMenu({ "Tab", "Select Previous Tab" }),
		},
	},
}
