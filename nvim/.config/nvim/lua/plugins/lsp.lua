vim.pack.add({
  { src = "https://github.com/mason-org/mason.nvim" },
  { src = "https://github.com/mason-org/mason-lspconfig.nvim" },
  { src = "https://github.com/neovim/nvim-lspconfig" },
  { src = "https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim" },
  { src = "https://github.com/b0o/SchemaStore.nvim" },
})

require("mason").setup({
  firewall = {
    enabled = true,
  },
})

require("mason-lspconfig").setup()
vim.lsp.enable("sourcekit")

require("mason-tool-installer").setup({
  ensure_installed = {
    "clangd", -- c lsp
    "lua_ls", -- lua lsp
    "stylua", -- lua formatter
    "basedpyright", -- python lsp
    "ruff", -- python formatter
    "jsonls", -- json lsp
    "jq", -- json formatter
    "yamlls", -- yaml lsp
    "html", -- html lsp
    "ts_ls", -- js/ts lsp
    "eslint", -- js/ts linter
    "prettierd", -- js/ts/html formatter
    "svelte", -- svelte lsp
    "tailwindcss", -- tailwindcss
    "marksman", -- markdown lsp
    "taplo", -- toml lsp
    "texlab", -- latex lsp
    "tex-fmt", -- latex formatter
  },
  auto_update = true,
  start_delay = 3000,
})

vim.diagnostic.config({
  virtual_text = true,
})
