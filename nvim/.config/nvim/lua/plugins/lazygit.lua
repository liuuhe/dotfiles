vim.pack.add({
  "https://github.com/nvim-lua/plenary.nvim",
  "https://github.com/kdheepak/lazygit.nvim",
})

vim.keymap.set("n", "<Leader>gg", "<cmd>LazyGit<CR>", { desc = "Open LazyGit" })
