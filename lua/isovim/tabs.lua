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
-- LazyVim's buffer and window keys work on these as on files (M.bufdelete, M.close_window, which
-- the starter maps <leader>bd, <leader>bD, <leader>bo, <leader>wd and bufferline's close to): from
-- a composer, a queue or an input box they act on its chat or view. Closing an agent's tab (or a
-- placeholder's) closes its chat, composer and queue (isovim.acp.chat), and the agent's tab stays
-- out of the bar, its agent running, until you open it again (Enter on its row, a picker,
-- <leader>ib). A composer or queue whose chat shows nowhere closes, and nothing brings it back
-- until the chat is shown again.
--
-- Nothing opens a split by itself: a chat's window, a surface's or a placeholder's is where Snacks
-- pickers open what they pick (b:snacks_main; the changes view, the explorer, <leader>ff), replacing
-- it as :b does, and a composer whose chat another buffer replaced closes; picking the chat's tab
-- brings both back.
local store = require("isovim.store")

local M = {}

local GROUP = vim.api.nvim_create_augroup("isovim_tabs", { clear = true })

-- Agents whose tab you closed ("<ws>/<agent>"): no placeholder for them until their chat opens. In
-- _G, so a hot reload keeps them closed.
_G.isovim_tabs_dismissed = _G.isovim_tabs_dismissed or {}
M.dismissed = _G.isovim_tabs_dismissed

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
-- A window that belongs to the buffer above it: a chat's composer or queue, a surface's input box.
local function slot_buffer(buf)
  return vim.b[buf].isovim_composer or vim.b[buf].isovim_queue or vim.b[buf].isovim_surface_input
end

-- An empty, nameless, unmodified buffer, as nvim starts with.
local function blank(buf)
  return vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

-- The windows you edit in: not the sidebar, a float, a composer, a queue or an input box.
local function editing_windows()
  local isovim = require("isovim")
  return vim.tbl_filter(function(win)
    return not isovim.is_sidebar(win) and not slot_buffer(vim.api.nvim_win_get_buf(win))
  end, vim.api.nvim_tabpage_list_wins(0))
end

-- win shows your last tab not on screen, or the landing when there's none.
local function show_last(win)
  local recent = vim.tbl_filter(function(info)
    return not blank(info.bufnr) and #info.windows == 0
  end, vim.fn.getbufinfo({ buflisted = 1 }))
  table.sort(recent, function(a, b)
    return a.lastused > b.lastused
  end)
  if recent[1] then
    vim.api.nvim_win_set_buf(win, recent[1].bufnr)
  else
    vim.api.nvim_win_call(win, require("isovim.landing").open)
  end
end

-- A window a close or delete left blank shows your last tab instead, or the landing.
local function fill_blank()
  for _, win in ipairs(editing_windows()) do
    if blank(vim.api.nvim_win_get_buf(win)) then
      return show_last(win)
    end
  end
end

-- The buffer a composer, a queue or an input box belongs to: its chat's, its view's; else buf.
function M.owner(buf)
  local chat_mod = package.loaded["isovim.acp.chat"]
  if vim.b[buf].isovim_composer and chat_mod then
    local chat = chat_mod.of_buf(buf)
    return chat and chat.buf or buf
  elseif vim.b[buf].isovim_queue and chat_mod then
    local ws, agent = vim.api.nvim_buf_get_name(buf):match("^isovim%-acp://(.*)/([^/]+)/queue$")
    local chat = ws and chat_mod.get(ws, agent)
    return chat and chat.buf or buf
  elseif vim.b[buf].isovim_surface_input and package.loaded["isovim.surface_view"] then
    local view = require("isovim.surface_view").views[vim.b[buf].isovim_surface_input]
    return view and view.buf or buf
  end
  return buf
end

-- A composer or queue (also a closed chat's) whose chat shows nowhere: closed. Its chat's window
-- took another tab, or was closed.
local function close_stray_composers()
  local closed = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].isovim_composer or vim.b[buf].isovim_queue then
      local owner = M.owner(buf)
      if (owner == buf or vim.fn.bufwinid(owner) == -1) and #editing_windows() == 0 then
        -- The last window beside the sidebar (:bd or :q on its chat closed the chat's): it shows your
        -- last tab, rather than close and leave isovim an empty one.
        vim.w[win].isovim_slot = nil
        show_last(win)
        closed = true
      elseif owner == buf or vim.fn.bufwinid(owner) == -1 then
        closed = pcall(vim.api.nvim_win_close, win, false) or closed
      end
    end
  end
  return closed
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

-- Marks the windows showing one (w:isovim_slot), so a tab picked in one is caught: bufferline's
-- click and :buffer put the tab's buffer in the current window, and from the composer that put a
-- chat into the composer's six rows, which then got a composer of its own under it, and the
-- composer's snap-back moved what was left between beside the chat: more windows each switch.
local function mark_slots()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if slot_buffer(vim.api.nvim_win_get_buf(win)) and not vim.w[win].isovim_slot then
      vim.w[win].isovim_slot = true
    end
  end
end

-- A tab's buffer that landed in a slot goes to the main window instead (an agent's chat opened there,
-- as its tab does) and the slot closes, so the main area stays one chat and its composer, or one
-- other buffer.
local function redirect(slot_win, buf)
  if not vim.api.nvim_win_is_valid(slot_win) or vim.api.nvim_win_get_buf(slot_win) ~= buf then
    return
  end
  local isovim = require("isovim")
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= slot_win and not isovim.is_sidebar(win) and not vim.w[win].isovim_slot then
      target = target or win
    end
  end
  vim.cmd.stopinsert()
  if not target then
    -- The only editing window: it's the main one now.
    vim.w[slot_win].isovim_slot = nil
    return
  end
  local ws, agent = M.agent_of(buf)
  pcall(vim.api.nvim_win_close, slot_win, true)
  vim.api.nvim_set_current_win(target)
  if ws then
    open_in(target, ws, agent)
  elseif vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_win_set_buf(target, buf)
  end
  close_stray_composers()
end

vim.api.nvim_create_autocmd("WinEnter", { group = GROUP, callback = mark_slots })

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = GROUP,
  callback = require("isovim.safe").wrap("the tab bar", function(ev)
    main_buffer(ev.buf)
    if slot_buffer(ev.buf) then
      return mark_slots()
    end
    for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
      if vim.w[win].isovim_slot then
        return require("isovim.safe").schedule("moving a tab out of a composer", function()
          redirect(win, ev.buf)
        end)
      end
    end
    local placeholder = vim.b[ev.buf].isovim_placeholder
    -- An ACP chat entering a window without its composer: picked from the tab bar.
    local acp = not placeholder and vim.b[ev.buf].isovim_acp
    if not (placeholder or acp) or opening then
      -- Anything else in a chat's window: its composer goes with it.
      return require("isovim.safe").schedule("closing a stray composer", close_stray_composers)
    end
    local win = vim.fn.bufwinid(ev.buf)
    require("isovim.safe").schedule("opening a tab's chat", function()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= ev.buf or vim.w[win].isovim_slot then
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
  end),
})

-- Placeholders sync deletes itself don't count as closed by you.
local quiet = false

vim.api.nvim_create_autocmd("BufDelete", {
  group = GROUP,
  callback = function(ev)
    local ws, agent = M.agent_of(ev.buf)
    if ws and not quiet then
      M.dismissed[ws .. "/" .. agent] = true
    end
    if ws or vim.b[ev.buf].isovim_surface or vim.bo[ev.buf].filetype == "isovim_landing" then
      require("isovim.safe").schedule("tidying after a closed tab", function()
        close_stray_composers()
        fill_blank()
      end)
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = GROUP,
  callback = function()
    require("isovim.safe").schedule("closing a stray composer", function()
      if close_stray_composers() then
        fill_blank()
      end
    end)
  end,
})

-- <leader>bd, bufferline's close (and <leader>bD with window): closes the tab of buf (default: the
-- current one, or what its composer, queue or input box belongs to) as Snacks.bufdelete does, the
-- window showing what you used before; with window, its windows close too while another editing
-- window remains.
function M.bufdelete(buf, opts)
  buf = M.owner((buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf)
  if opts and opts.window then
    local mine = vim.fn.win_findbuf(buf)
    local others = vim.tbl_filter(function(win)
      return not vim.tbl_contains(mine, win)
    end, editing_windows())
    if #others > 0 then
      vim.cmd.stopinsert()
      for _, win in ipairs(mine) do
        pcall(vim.api.nvim_win_close, win, false)
      end
    end
  end
  Snacks.bufdelete(buf)
end

-- <leader>bo: every tab but the current one's (its chat's, from a composer) closes.
function M.bufdelete_others()
  local keep = M.owner(vim.api.nvim_get_current_buf())
  Snacks.bufdelete({ filter = function(buf)
    return buf ~= keep
  end })
end

-- <leader>wd: the window closes, with its chat's composer and queue (from either, the chat's
-- window), while another editing window remains; else it stays, as vim's last window does.
function M.close_window(win)
  win = win or vim.api.nvim_get_current_win()
  local owner = M.owner(vim.api.nvim_win_get_buf(win))
  if owner ~= vim.api.nvim_win_get_buf(win) and vim.fn.bufwinid(owner) ~= -1 then
    win = vim.fn.bufwinid(owner)
  end
  if #vim.tbl_filter(function(each)
    return each ~= win
  end, editing_windows()) == 0 then
    return vim.api.nvim_echo({ { "E444: Cannot close last window", "ErrorMsg" } }, true, {})
  end
  vim.cmd.stopinsert()
  vim.api.nvim_win_close(win, false)
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
  mark_slots()
  local chats, placeholders = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].isovim_placeholder then
      placeholders[vim.b[buf].isovim_placeholder] = buf
    else
      local ws, agent = M.agent_of(buf)
      main_buffer(buf)
      if ws and vim.api.nvim_buf_is_loaded(buf) then
        chats[ws .. "/" .. agent] = true
        -- Opened again: its tab is back for good.
        M.dismissed[ws .. "/" .. agent] = nil
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
        if not spec.hidden and not chats[id] and not M.dismissed[id] and scope.of_agent(ws.id, spec.id) == scope_name then
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
      quiet = true
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      quiet = false
    end
  end
  vim.cmd.redrawtabline()
end

return M
