-- The tab bar (bufferline): what each tab is called and its glyph, their order, and a tab for every
-- agent of the current scope, opened or not.
--
-- An agent whose chat isn't open yet is a placeholder: a listed, empty buffer in the agent's scope
-- (b:isovim_placeholder "<ws>/<agent>") that attaches to nothing. Shown in a window (picked from the
-- tab bar, <S-h>/<S-l>, [b ]b), it opens the agent's chat there as Enter on its sidebar row does, and,
-- wiped once hidden, gives way to the chat's own buffer. M.sync keeps one tab per agent of the scope:
-- a placeholder for each agent with no chat buffer, none for one gone or hidden. Picking an ACP
-- chat's own tab opens it the same way, so its composer comes with it and the last chat's goes.
--
-- Order: the router first, then the scope's other agents by number, then surfaces (isovim.surface_view),
-- the landing, and anything else (files) as bufferline had it.
--
-- Nothing opens a split by itself: a chat's window, a surface's or a placeholder's is where Snacks
-- pickers open what they pick (b:snacks_main; the changes view, the explorer, <leader>ff), replacing
-- it as :b does, and a composer whose chat another buffer replaced closes; picking the chat's tab
-- brings both back.
local store = require("isovim.store")

local M = {}

local GROUP = vim.api.nvim_create_augroup("isovim_tabs", { clear = true })

-- The agent a buffer is the tab of: a chat's or a placeholder's.
---@return string? ws, string? agent
function M.agent_of(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local placeholder = vim.b[buf].isovim_placeholder
  if placeholder then
    return placeholder:match("^(.*)/([^/]+)$")
  end
  local ws = vim.b[buf].isovim_id
  if ws and not vim.b[buf].isovim_composer then
    return ws, vim.b[buf].isovim_agent or "main"
  end
end

-- A tab's name: an agent's with its status mark as the sidebar shows it (working, finished unread,
-- waiting on you), a surface's or the landing's own (b:isovim_tab); nil leaves bufferline's.
function M.name(buf)
  local ws, agent = M.agent_of(buf)
  if ws then
    local status = require("isovim.status").get(ws, agent)
    local mark = ({ working = " …", unread = " ●", attention = " ●!" })[status or ""]
    return (vim.b[buf].isovim_agent_name or agent) .. (mark or "")
  end
  local tab = vim.b[buf].isovim_tab
  return tab and tab.name
end

-- A tab's glyph and its color, by its buffer's name (bufferline gives a tab's icon function only
-- that); nil leaves bufferline's.
---@return string? icon, string? hl
function M.icon(path)
  if not path:match("^isovim") then
    return nil
  end
  local buf = vim.fn.bufnr(path)
  if buf <= 0 then
    return nil
  end
  if M.agent_of(buf) then
    return require("isovim.icons").get(vim.b[buf].isovim_agent_kind or "claude")
  end
  local tab = vim.b[buf].isovim_tab
  if tab then
    return tab.icon, tab.hl
  end
end

local function number(agent)
  return tonumber(agent:match("^a(%d+)$")) or math.huge
end

-- Where a tab sorts: its group, then within it.
local function rank(buf)
  local ws, agent = M.agent_of(buf)
  if ws then
    local spec = store.agent(ws, agent)
    local router = spec and store.role(spec) == "router"
    return { 1, router and 0 or 1, number(agent), vim.b[buf].isovim_agent_name or agent }
  elseif vim.b[buf].isovim_surface then
    return { 2, 0, 0, vim.b[buf].isovim_surface }
  elseif vim.bo[buf].filetype == "isovim_landing" then
    return { 3, 0, 0, "" }
  end
  return { 4, 0, buf, "" }
end

-- bufferline's sort_by: whether tab a goes before tab b.
function M.before(a, b)
  local ra, rb = rank(a.id), rank(b.id)
  for i = 1, 4 do
    if ra[i] ~= rb[i] then
      return ra[i] < rb[i]
    end
  end
  return a.id < b.id
end

-- A composer whose chat shows nowhere: left behind when its chat's window took another tab.
local function close_stray_composers()
  local chat_mod = package.loaded["isovim.acp.chat"]
  if not chat_mod then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local chat = vim.b[buf].isovim_composer and chat_mod.of_buf(buf)
    if chat and chat.composer == buf and vim.fn.bufwinid(chat.buf) == -1 then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end

-- An agent's tab picked: its chat opened in that window, as Enter on its sidebar row does.
local opening = false
local function open_in(win, ws, agent)
  if opening or not vim.api.nvim_win_is_valid(win) or require("isovim").is_sidebar(win) then
    return
  end
  opening = true
  local ok, err = pcall(require("isovim").open, ws, agent, win)
  opening = false
  close_stray_composers()
  if not ok then
    vim.notify("isovim: could not open " .. ws .. "/" .. agent .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Where Snacks pickers open a file: a chat's window, a surface's or a placeholder's, not a split.
local function main_buffer(buf)
  if (M.agent_of(buf) or vim.b[buf].isovim_surface) and not vim.b[buf].snacks_main then
    vim.b[buf].snacks_main = true
  end
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = GROUP,
  callback = function(ev)
    main_buffer(ev.buf)
    local placeholder = vim.b[ev.buf].isovim_placeholder
    -- An ACP chat entering a window without its composer: picked from the tab bar.
    local acp = not placeholder and vim.b[ev.buf].isovim_acp
    if not (placeholder or acp) or opening then
      -- Anything else in a chat's window: its composer goes with it.
      return vim.schedule(close_stray_composers)
    end
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= ev.buf then
        return
      end
      local ws, agent = M.agent_of(ev.buf)
      if not ws then
        return
      end
      if acp then
        local chat = require("isovim.acp.chat").of_buf(ev.buf)
        if chat and vim.fn.bufwinid(chat.composer) ~= -1 then
          return close_stray_composers()
        end
      end
      open_in(win, ws, agent)
    end)
  end,
})

-- An empty, nameless, unmodified buffer, as nvim starts with.
local function blank(buf)
  return vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function placeholder(ws, agent, spec, scope_name)
  local name = ("isovim-agent://%s/%s"):format(ws, agent)
  local buf = vim.fn.bufnr(name)
  if buf > 0 and vim.b[buf].isovim_placeholder then
    return buf
  end
  buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].modifiable = false
  vim.b[buf].isovim_placeholder = ws .. "/" .. agent
  vim.b[buf].snacks_main = true
  vim.b[buf].isovim_scope = scope_name
  vim.b[buf].isovim_agent_name, vim.b[buf].isovim_agent_kind = spec.name or agent, spec.kind or "claude"
  return buf
end

-- One tab per agent of the scope (default: the current one): a placeholder for each that has no
-- chat buffer, none for an agent gone or hidden; and the nameless empty buffer nvim starts with
-- goes once nothing shows it, so it isn't a stray [No Name] tab.
function M.sync(scope_name)
  local isovim = require("isovim")
  scope_name = scope_name or isovim.current_scope
  local scope = require("isovim.scope")
  local chats, placeholders = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].isovim_placeholder then
      placeholders[vim.b[buf].isovim_placeholder] = buf
    else
      local ws, agent = M.agent_of(buf)
      main_buffer(buf)
      if ws and vim.api.nvim_buf_is_loaded(buf) then
        chats[ws .. "/" .. agent] = true
      elseif blank(buf) and vim.bo[buf].buflisted and #vim.fn.win_findbuf(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, {})
      end
    end
  end
  local wanted = {}
  if scope_name then
    for _, ws in ipairs(store.list()) do
      for _, spec in ipairs(store.agents(ws.id)) do
        local id = ws.id .. "/" .. spec.id
        if not spec.hidden and not chats[id] and scope.of_agent(ws.id, spec.id) == scope_name then
          wanted[id] = placeholder(ws.id, spec.id, spec, scope_name)
        end
      end
    end
  end
  -- A placeholder of another scope stays (unlisted) until its agent goes or opens.
  for id, buf in pairs(placeholders) do
    local ws, agent = id:match("^(.*)/([^/]+)$")
    local spec = store.agent(ws, agent)
    if not wanted[id] and (not spec or spec.hidden or chats[id] or vim.b[buf].isovim_scope == scope_name)
      and #vim.fn.win_findbuf(buf) == 0 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.cmd.redrawtabline()
end

return M
