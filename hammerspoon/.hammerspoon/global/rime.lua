local M = {}
local log = hs.logger.new("rime", "info")
local timer, wakeWatcher, startupTimer, task
local running = false

local function reportError(message)
	log.e(message)
	hs.notify
		.new({ title = "Rime update failed", informativeText = "See Hammerspoon Console. Will retry later." })
		:send()
end

function M.start()
	if running then
		return
	end
	running = true
	local configDirectory = assert(hs.fs.pathToAbsolute(hs.configdir))
	local script = assert(hs.fs.pathToAbsolute(configDirectory .. "/../../scripts/update-rime.sh"))
	local function check()
		if task and task:isRunning() then
			return
		end
		task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
			task = nil
			if not running then
				return
			end
			if exitCode ~= 0 then
				reportError(stderr .. "\n" .. stdout)
			elseif stdout ~= "" then
				log.i(stdout)
			end
		end, { script, "--if-due" })
		if not task or not task:start() then
			task = nil
			reportError("Could not start the Rime update script.")
		end
	end
	timer = hs.timer.doEvery(3600, check)
	wakeWatcher = hs.caffeinate.watcher.new(function(event)
		if event == hs.caffeinate.watcher.systemDidWake then
			check()
		end
	end)
	wakeWatcher:start()
	startupTimer = hs.timer.doAfter(10, check)
end

function M.stop()
	running = false
	for _, resource in pairs({ timer, wakeWatcher, startupTimer }) do
		resource:stop()
	end
	if task then
		task:terminate()
	end
	timer, wakeWatcher, startupTimer, task = nil, nil, nil, nil
end

return M
