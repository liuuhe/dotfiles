local selectMenu = require("hotkeys").selectMenu

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
