-- Loaded by LazyVim after its own options (lazyvim.config.options), so these override its defaults.

-- No Trouble code-symbol breadcrumb in the statusline: it means nothing in a chat, and making it
-- (trouble.statusline) starts a libuv check that runs on every turn of nvim's loop, a third of the
-- TUI's Lua time while a chat streamed.
vim.g.trouble_lualine = false
