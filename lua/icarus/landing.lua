-- The home page: empty, but for n, which opens a new chat.
local M = {}

local NAME = "icarus://home"

-- Its buffer, made the first time; its key set each time, so after a hot reload it runs the new code.
function M.buf()
  local buf = vim.fn.bufnr("^" .. NAME .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "icarus_home"
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_set_name(buf, NAME)
  end
  vim.keymap.set("n", "n", function()
    require("icarus").new_chat()
  end, { buffer = buf, nowait = true })
  return buf
end

return M
