vim.pack.add({
  { src = "https://github.com/andrewferrier/wrapping.nvim" },
})

require("wrapping").setup()

vim.keymap.set("n", "<leader>us", "<CMD>SoftWrapMode<CR>", { desc = "Soft Wrap Mode" })
vim.keymap.set("n", "<leader>uh", "<CMD>HardWrapMode<CR>", { desc = "Hard Wrap Mode" })
vim.keymap.set("n", "<leader>ut", "<CMD>ToggleWrapMode<CR>", { desc = "Toggle Wrap Mode" })
