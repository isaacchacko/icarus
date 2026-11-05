-- icarus's whole config: this checkout on the runtimepath, and the rest is icarus's setup.
vim.opt.runtimepath:prepend(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.g.mapleader = " "
require("icarus").setup()
