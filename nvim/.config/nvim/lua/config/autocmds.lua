-- Auto create directory
vim.api.nvim_create_autocmd({ "BufWritePre" }, {
  pattern = "*",
  group = vim.api.nvim_create_augroup("auto_create_dir", { clear = true }),
  callback = function(ctx)
    local buf = ctx.buf
    local file = vim.api.nvim_buf_get_name(buf)
    if file:match("^oil://") then
      return
    end
    local dir = vim.fn.fnamemodify(ctx.file, ":p:h")
    vim.fn.mkdir(dir, "p")
  end,
})

-- Highlight on yanking
vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Highlight when yanking (copying) text",
  group = vim.api.nvim_create_augroup("highlight_on_yank", { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})
