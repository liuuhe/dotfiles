vim.pack.add({
  { src = "https://github.com/stevearc/oil.nvim" },
  { src = "https://github.com/nvim-tree/nvim-web-devicons" },
})

require("nvim-web-devicons").setup()
require("oil").setup({
  keymaps = {
    ["h"] = { "actions.parent", mode = "n" },
    ["l"] = { "actions.select", mode = "n" },
  },
  delete_to_trash = true,
  skip_confirm_for_simple_edits = true,
  watch_for_changes = true,
})

vim.keymap.set("n", "<leader>e", function()
  local oil = require("oil")
  if vim.bo.filetype == "oil" then
    oil.close()
  else
    oil.open(nil, { preview = {} })
  end
end, { desc = "Toggle Oil" })
