vim.pack.add({ "https://github.com/rafamadriz/friendly-snippets" })
vim.pack.add({ "https://github.com/saghen/blink.lib", "https://github.com/saghen/blink.cmp" })

vim.schedule(function()
  local cmp = require("blink.cmp")
  cmp.build():wait()

  vim.api.nvim_create_autocmd("PackChanged", {
    group = vim.api.nvim_create_augroup("blink_build", { clear = true }),
    callback = function(ev)
      if ev.data.spec.name == "blink.cmp" and ev.data.kind == "update" then
        cmp.build()
      end
    end,
  })

  cmp.setup({
    completion = {
      documentation = {
        auto_show = true,
      },
    },
    sources = {
      default = { "lsp", "path", "snippets" },
    },
    signature = { enabled = true },
    cmdline = {
      completion = {
        menu = {
          auto_show = true,
        },
      },
    },
    keymap = {
      ["<C-j>"] = { "select_next" },
      ["<C-k>"] = { "select_prev" },
    },
  })
end)
