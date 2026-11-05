-- The home page, the whole screen: one line in its middle saying n opens a new chat, which it does.
local M = {}

local NAME = "icarus://home"
local TEXT = "press n for a new chat"
local NS = vim.api.nvim_create_namespace("icarus_home")

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
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = vim.api.nvim_create_augroup("icarus_home", { clear = true }),
    callback = function()
      require("icarus.landing").draw()
    end,
  })
  return buf
end

-- The line in the middle of the window showing home.
function M.draw()
  local buf = M.buf()
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return
  end
  local lines = {}
  for _ = 1, math.floor(vim.api.nvim_win_get_height(win) / 2) do
    lines[#lines + 1] = ""
  end
  local pad = math.max(0, math.floor((vim.api.nvim_win_get_width(win) - #TEXT) / 2))
  lines[#lines] = (" "):rep(pad) .. TEXT
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, NS, #lines - 1, pad, { end_col = pad + #TEXT, hl_group = "IcarusAcpNotice" })
end

return M
