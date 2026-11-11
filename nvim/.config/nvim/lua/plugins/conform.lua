vim.pack.add({
  { src = "https://github.com/stevearc/conform.nvim" },
})
vim.schedule(function()
  require("conform").setup({
    formatters_by_ft = {
      lua = { "stylua" },
      python = { "ruff_fix", "ruff_organize_imports", "ruff_format" },
      javascript = { "prettierd" },
      typescript = { "prettierd" },
      svelte = { "prettierd" },
      html = { "prettierd" },
      json = { "jq" },
      tex = { "tex-fmt" },
    },
    formatters = {
      jq = {
        args = { "--indent", "2" },
      },
    },
    format_on_save = {
      timeout_ms = 500,
      lsp_format = "fallback",
    },
  })
end)
