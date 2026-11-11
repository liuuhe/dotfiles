vim.pack.add({
  "https://github.com/OXY2DEV/markview.nvim",
})

require("markview").setup({})

vim.api.nvim_set_keymap("n", "<leader>m", "<CMD>Markview<CR>", { desc = "Toggles `markview` previews globally." })
