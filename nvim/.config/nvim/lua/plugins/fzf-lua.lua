vim.pack.add({
  { src = "https://github.com/ibhagwan/fzf-lua" },
  { src = "https://github.com/nvim-tree/nvim-web-devicons" },
})

vim.schedule(function()
  require("nvim-web-devicons").setup()
  require("fzf-lua").setup()
end)

vim.keymap.set("n", "<leader>fh", "<cmd>FzfLua helptags<CR>", { desc = "Find help" })
vim.keymap.set("n", "<leader>fb", "<cmd>FzfLua lgrep_curbuf<CR>", { desc = "Find in current buffer" })
vim.keymap.set("n", "<leader>ff", "<cmd>FzfLua files<CR>", { desc = "Find files" })
vim.keymap.set("n", "<leader>fg", "<cmd>FzfLua live_grep<CR>", { desc = "Find live grep" })
