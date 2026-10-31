-- Only the selected workspace's buffers are listed; the rest stay loaded but drop out of the
-- tab bar and :bnext until their workspace is selected again.
local store = require("isovim.store")

local M = {}

local function scoped(buf)
  if vim.b[buf].isovim_ws then
    return true
  end
  local buftype = vim.bo[buf].buftype
  return vim.bo[buf].buflisted and (buftype == "" or buftype == "terminal") and vim.api.nvim_buf_get_name(buf) ~= ""
end

-- The workspace whose dir (own or project) holds the file: the current one if it does, since
-- workspaces may share a project; else the deepest.
local function workspace_of_path(name, current)
  local path = vim.uv.fs_realpath(name) or name
  local best, depth = nil, 0
  for _, ws in ipairs(store.list()) do
    for _, dir in ipairs({ store.path(ws.id), ws.dir }) do
      local root = (vim.uv.fs_realpath(dir) or dir) .. "/"
      if vim.startswith(path, root) then
        if ws.id == current then
          return current
        elseif #root > depth then
          best, depth = ws.id, #root
        end
      end
    end
  end
  return best
end

-- A chat belongs to its workspace, a file to the workspace whose dir holds it, anything else
-- to the workspace selected when it was opened ("" when none was).
function M.tag(buf, current)
  if vim.b[buf].isovim_ws or not scoped(buf) then
    return
  end
  vim.b[buf].isovim_ws = vim.b[buf].isovim_id or workspace_of_path(vim.api.nvim_buf_get_name(buf), current) or current or ""
end

---@param is_sidebar fun(win: integer): boolean
function M.apply(current, is_sidebar)
  current = current or ""
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.tag(buf, current)
    local ws = vim.b[buf].isovim_ws
    if ws then
      local mine = ws == current
      if vim.bo[buf].buflisted ~= mine then
        vim.bo[buf].buflisted = mine
      end
    end
  end
  -- Splits showing another workspace's buffers close, except one editing window: the
  -- current one, or the first when the sidebar has focus.
  local wins = vim.tbl_filter(function(win)
    return not is_sidebar(win)
  end, vim.api.nvim_tabpage_list_wins(0))
  local keep = vim.tbl_contains(wins, vim.api.nvim_get_current_win()) and vim.api.nvim_get_current_win() or wins[1]
  for _, win in ipairs(wins) do
    local ws = vim.b[vim.api.nvim_win_get_buf(win)].isovim_ws
    if win ~= keep and ws and ws ~= current then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  vim.cmd.redrawtabline()
end

return M
