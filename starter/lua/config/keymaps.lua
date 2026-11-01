-- Loaded after LazyVim's own keymaps, so these replace them.

-- ctrl+/ toggles the workspace's own terminal (isovim.toggle_terminal) instead of LazyVim's.
local function toggle_terminal()
  require("isovim").toggle_terminal()
end
vim.keymap.set({ "n", "t" }, "<C-/>", toggle_terminal, { desc = "isovim: toggle the workspace's terminal" })
vim.keymap.set({ "n", "t" }, "<C-_>", toggle_terminal, { desc = "which_key_ignore" })

-- LazyVim's buffer and window keys, on isovim's buffers too (isovim.tabs): from a queue or an input
-- box they act on its chat or view, an agent's closed tab stays closed until you open it again, and
-- its queue goes with it.
vim.keymap.set("n", "<leader>bd", function()
  require("isovim.tabs").bufdelete()
end, { desc = "Delete Buffer" })
vim.keymap.set("n", "<leader>bD", function()
  require("isovim.tabs").bufdelete(nil, { window = true })
end, { desc = "Delete Buffer and Window" })
vim.keymap.set("n", "<leader>bo", function()
  require("isovim.tabs").bufdelete_others()
end, { desc = "Delete Other Buffers" })
vim.keymap.set("n", "<leader>wd", function()
  require("isovim.tabs").close_window()
end, { desc = "Delete Window" })
