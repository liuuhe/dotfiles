vim.loader.enable()

require("config.options")
require("config.keymaps")
require("config.autocmds")

vim.cmd.colorscheme("habamax")

local plugin_path = vim.fn.stdpath("config") .. "/lua/plugins"

for _, file in ipairs(vim.fn.glob(plugin_path .. "/*.lua", false, true)) do
  local module = file:match("([^/]+)%.lua$")
  require("plugins." .. module)
end
