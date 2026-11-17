local M = {}

local scrollAmount = 48 -- Fixed vertical amount per mouse scroll event.
local executable = os.getenv("HOME") .. "/Library/Application Support/Hammerspoon/MouseScroll"
local log = hs.logger.new("mouse", "info")
local helper

function M.start()
	if helper then
		return
	end
	assert(
		type(scrollAmount) == "number" and scrollAmount >= 1 and scrollAmount <= 10000 and scrollAmount % 1 == 0,
		"scrollAmount must be an integer between 1 and 10000"
	)
	assert(hs.fs.attributes(executable, "mode") == "file", "Build the mouse scroll helper using global/mouse/build.sh.")

	local session = {}
	helper = session
	session.task = hs.task.new(executable, function(exitCode, stdout, stderr)
		if helper ~= session then
			return
		end
		helper = nil
		log.e("Mouse scroll helper stopped (exit " .. exitCode .. ").\n" .. stderr .. stdout)
		hs.notify
			.new({
				title = "Mouse scrolling stopped",
				informativeText = "See Hammerspoon Console for details.",
			})
			:send()
	end, { tostring(scrollAmount) })
	if not session.task or not session.task:start() then
		helper = nil
		error("Could not start the mouse scroll helper.")
	end
end

function M.stop()
	local session = helper
	helper = nil
	if session and session.task then
		session.task:terminate()
	end
end

return M
