-- isovim's whole config: this checkout on the runtimepath, a few options, and the sidebar and home.
vim.opt.runtimepath:prepend(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.mouse = "a"
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.laststatus = 3
vim.o.statusline = " %{fnamemodify(getcwd(), ':~')}"
vim.o.showtabline = 0
vim.o.fillchars = "eob: "
vim.o.clipboard = "unnamedplus"
require("isovim").setup()
