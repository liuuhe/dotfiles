vim.pack.add({ "https://github.com/j-hui/fidget.nvim" })

vim.schedule(function()
  require("fidget").setup()
end)
