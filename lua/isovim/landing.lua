-- The home page: empty, but for n, which opens a new chat.
local M = {}

local buf ---@type integer?

function M.buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "isovim_home"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "isovim://home")
  vim.keymap.set("n", "n", function()
    require("isovim").new_chat()
  end, { buffer = buf, nowait = true })
  return buf
end

return M
