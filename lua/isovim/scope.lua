-- Buffers are listed by scope: a repo ("owner/repo"), "root" (the host root's), "general" (agents in
-- no repo and files outside every repo) or "terminals" (terminals and repo script panes). Only the
-- current scope's buffers are listed; the rest stay loaded but drop out of the tab bar, :bnext and
-- <leader>, until their scope is current again. Splits still follow the workspace (b:isovim_ws):
-- selecting another workspace closes the splits showing the last one's buffers.
local store = require("isovim.store")

local M = {}

M.ROOT, M.GENERAL, M.TERMINALS = "root", "general", "terminals"
local LABELS = { root = "Root", general = "General", terminals = "Terminals" }

-- What a scope is called in pickers and toasts: a repo by its name.
function M.label(name)
  return LABELS[name] or name
end

function M.is_terminal(agent)
  return agent.kind == "terminal" or agent.kind == "shell" or require("isovim.scripts").of(agent) ~= nil
end

-- The host's root: the agent with the root role, or the one `iso root` named.
function M.is_root(ws, agent)
  local root = require("isovim.root")
  return store.role(agent) == "root" or root.is_root(root.address(ws, agent.id))
end

-- A workspace's scope: a new-layout repo key's repo (general and root are General's and Root's); a
-- workspace holding the host root is Root's; else the repo its dir is a checkout of, or General
-- outside git.
function M.of_workspace(ws)
  if store.v2(ws) then
    -- An old _/ whose move waits holds what general/ and root/ will: General's.
    return store.canon(ws) == store.OLD and M.GENERAL or store.canon(ws)
  end
  for _, agent in ipairs(store.agents(ws)) do
    if M.is_root(ws, agent) then
      return M.ROOT
    end
  end
  return require("isovim.repos").of(store.dir(ws)) or M.GENERAL
end

-- An agent's scope: Terminals for a terminal or script pane, Root for the root, else its workspace's.
function M.of_agent(ws, id)
  local agent = store.agent(ws, id)
  if agent and M.is_terminal(agent) then
    return M.TERMINALS
  elseif agent and M.is_root(ws, agent) then
    return M.ROOT
  end
  return M.of_workspace(ws)
end

local function scoped(buf)
  if vim.b[buf].isovim_ws then
    return true
  end
  local buftype = vim.bo[buf].buftype
  return vim.bo[buf].buflisted and (buftype == "" or buftype == "terminal") and vim.api.nvim_buf_get_name(buf) ~= ""
end

-- The workspace whose dir (own or project) holds the file: the current one if it does, since
-- workspaces may share a project; else the deepest. A dir of ~ holds everything, so it counts only
-- with with_home.
local function workspace_of_path(name, current, with_home)
  local path = vim.uv.fs_realpath(name) or name
  local home = vim.uv.fs_realpath(vim.fs.normalize("~")) or vim.fs.normalize("~")
  local best, depth = nil, 0
  for _, ws in ipairs(store.list()) do
    for _, dir in ipairs({ store.path(ws.id), ws.dir }) do
      local real = vim.uv.fs_realpath(dir) or dir
      local root = real .. "/"
      if vim.startswith(path, root) and (with_home or real ~= home) then
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

-- A file's scope: its workspace's, else the repo it's in, else General.
function M.of_path(name)
  local ws = workspace_of_path(name)
  if ws then
    return M.of_workspace(ws)
  end
  local dir = vim.fs.dirname(vim.uv.fs_realpath(name) or name)
  return vim.fn.isdirectory(dir) == 1 and require("isovim.repos").of(dir) or M.GENERAL
end

-- A chat belongs to its workspace, a file to the workspace whose dir holds it, anything else to the
-- workspace selected when it was opened ("" when none was). Its scope: a chat's agent's (looked up
-- again each time: an agent made root moves), an ACP composer's too, a file's path's; another
-- host's chat keeps the scope it was opened in.
function M.tag(buf, current, current_scope)
  if not scoped(buf) then
    return
  end
  if not vim.b[buf].isovim_ws then
    vim.b[buf].isovim_ws = vim.b[buf].isovim_id or workspace_of_path(vim.api.nvim_buf_get_name(buf), current, true) or current or ""
  end
  local chat = vim.b[buf].isovim_id or (vim.b[buf].isovim_composer and vim.b[buf].isovim_ws)
  if chat then
    vim.b[buf].isovim_scope = M.of_agent(chat, vim.b[buf].isovim_agent or "main")
  elseif not vim.b[buf].isovim_scope then
    local name = vim.api.nvim_buf_get_name(buf)
    vim.b[buf].isovim_scope = vim.startswith(name, "isovim://") and (current_scope or M.GENERAL) or M.of_path(name)
  end
end

-- Lists the scope's buffers and unlists the rest.
function M.list(current, current_scope)
  current_scope = current_scope or M.GENERAL
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.tag(buf, current or "", current_scope)
    local scope = vim.b[buf].isovim_scope
    if scope then
      local mine = scope == current_scope
      if vim.bo[buf].buflisted ~= mine then
        vim.bo[buf].buflisted = mine
      end
    end
  end
  vim.cmd.redrawtabline()
end

---@param is_sidebar fun(win: integer): boolean
function M.apply(current, current_scope, is_sidebar)
  current = current or ""
  M.list(current, current_scope)
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
end

return M
