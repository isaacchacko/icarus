-- Loaded after LazyVim's own keymaps, so these replace them.

-- ctrl+/ toggles the workspace's own terminal (isovim.toggle_terminal) instead of LazyVim's.
local function toggle_terminal()
  require("isovim").toggle_terminal()
end
vim.keymap.set({ "n", "t" }, "<C-/>", toggle_terminal, { desc = "isovim: toggle the workspace's terminal" })
vim.keymap.set({ "n", "t" }, "<C-_>", toggle_terminal, { desc = "which_key_ignore" })
