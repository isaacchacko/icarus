local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local scope = require("isovim.scope")
local prs = require("isovim.prs")
local icons = require("isovim.icons")
local stream = require("isovim.stream")
local layout = require("isovim.layout")
local diffstat = require("isovim.diffstat")
local remote = require("isovim.remote")

local M = {}

M.current = nil ---@type string? id of the workspace last focused
M.sort = "created" ---@type "created"|"active"
M.show_hidden = false
M.show_prs = false -- every workspace lists its PRs instead of its agents
M.show_ports = false -- rows show the ports their agents and terminals listen on
M.explorer_roots = {} ---@type table<string, {cwd: string, file?: string}> workspace id -> where its explorer was left
M.recent = {} ---@type string[] workspace ids, most recently selected first (<leader>aw)

-- Persisted so a hot reload picks up where the old code left off.
local function remember(key, value)
  M[key] = value
  store.write_session({
    current = M.current,
    sort = M.sort,
    show_hidden = M.show_hidden,
    show_prs = M.show_prs,
    show_ports = M.show_ports,
    explorer_roots = M.explorer_roots,
    recent = M.recent,
  })
end

-- The sidebar is a non-floating snacks_layout_box holding floating picker windows.
local function is_sidebar(win)
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return (ft:match("^snacks_") and ft ~= "snacks_dashboard") or vim.api.nvim_win_get_config(win).relative ~= ""
end

-- Pickers, grep and :e work in the workspace's project, as in a normal nvim session there; with
-- none selected, in ~.
local function enter_dir(id)
  local dir = id and store.dir(id) or vim.fs.normalize("~")
  if vim.fn.getcwd() ~= dir then
    vim.cmd.cd({ vim.fn.fnameescape(dir), mods = { silent = true } })
  end
end

-- Selecting a workspace scopes the buffer list to it and brings back its splits, keeping the
-- buffer just opened on screen; the sidebar's cursor follows (M.follow).
local function select(id)
  local switching = id ~= M.current
  if id then
    M.recent = vim.list_extend({ id }, vim.tbl_filter(function(other)
      return other ~= id
    end, M.recent))
  end
  remember("current", id)
  enter_dir(id)
  -- The terminal's tab or window title says which workspace isovim is on.
  vim.o.title = true
  vim.o.titlestring = id and ("isovim · " .. store.name(id)) or "isovim"
  scope.apply(id, is_sidebar)
  if switching and id then
    local buf = vim.api.nvim_get_current_buf()
    local want = vim.b[buf].isovim_ws == id and buf or nil
    -- Its splits from this session, else from its layout.json (moved in, unarchived, not yet visited).
    if not layout.restore(id, is_sidebar, want) then
      layout.resume(id, is_sidebar, M.open_leaf(id), want)
    end
  end
  if M.follow then
    M.follow()
  end
end

local function main_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not is_sidebar(win) then
      return win
    end
  end
  vim.cmd("botright vnew")
  return vim.api.nvim_get_current_win()
end

-- A chat buffer is an agent's terminal (isovim.stream): b:isovim_id is its workspace, b:isovim_agent the agent id.
local function chat_bufs()
  return vim.tbl_filter(function(buf)
    return vim.b[buf].isovim_id ~= nil and vim.bo[buf].buftype == "terminal"
  end, vim.api.nvim_list_bufs())
end

---@return integer? live, integer[] stale chats for the agent whose stream has ended
local function chat_buf(ws, agent)
  local live, stale = nil, {}
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      if stream.alive(buf) then
        live = buf
      else
        table.insert(stale, buf)
      end
    end
  end
  return live, stale
end

-- Whichever the sidebar is showing: Workspaces or the explorer.
local function focus_sidebar()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if sidebar then
    vim.cmd.stopinsert()
    sidebar:focus("list")
  end
end

-- Claude runs no hook when Esc interrupts it, so its spinner would spin on until the next prompt.
-- Esc reaches it only through ctrl+q, so look for its "Interrupted" line then.
local function watch_interrupt(ws, agent)
  local tries = 0
  local function check()
    tries = tries + 1
    if status.state(ws, agent) ~= "working" then
      return
    elseif panes.capture(ws, agent, 0):find("Interrupted", 1, true) then
      status.set_state(ws, agent, "idle")
    elseif tries < 10 then
      vim.defer_fn(check, 300)
    end
  end
  vim.defer_fn(check, 300)
end

-- Esc leaves the chat like any other mode, to scroll and search it; ctrl+q (unbound in Claude Code)
-- sends Claude its Esc. ctrl+h goes to the sidebar; ctrl+l to a split on the right, if any.
-- The terminal flattens shift+enter to enter, so it goes as meta+enter, Claude's other newline.
-- {key, rhs or fn(buf), description}; `?` in the sidebar lists them too.
local CHAT_KEYS = {
  { "<Esc>", [[<C-\><C-n>]], "leave the chat to normal mode" },
  {
    "<C-q>",
    function(buf)
      stream.send(buf, "\27")
      watch_interrupt(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main")
    end,
    "send Esc to the agent",
  },
  {
    "<S-CR>",
    function(buf)
      stream.send(buf, "\27\r")
    end,
    "newline in the chat",
  },
  {
    "<C-h>",
    function()
      focus_sidebar()
    end,
    "go to the sidebar",
  },
  { "<C-l>", [[<C-\><C-n><C-w>l]], "go to the right window" },
}

-- A file opens beside the chat rather than in place of it: in the other editing split, or a new
-- one on the right.
local function open_beside(chat_win, path, lnum)
  local chat = vim.api.nvim_win_get_buf(chat_win)
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= chat_win and not is_sidebar(win) and vim.api.nvim_win_get_buf(win) ~= chat then
      target = target or win
    end
  end
  local file_buf = vim.fn.bufadd(path)
  vim.bo[file_buf].buflisted = true
  if target then
    vim.api.nvim_win_set_buf(target, file_buf)
    vim.api.nvim_set_current_win(target)
  else
    vim.api.nvim_open_win(file_buf, true, { split = "right", win = chat_win })
  end
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), 0 })
    vim.cmd("normal! zz")
  end
end

-- A file the agent mentioned (src/x.py, src/x.py:12, src/x.py:12:5), beside its chat.
local function open_mentioned()
  local file = vim.fn.expand("<cfile>")
  local line = vim.api.nvim_get_current_line()
  local start = line:find(file, 1, true)
  local lnum = start and line:sub(start + #file):match("^:(%d+)")
  local path = vim.fn.findfile(file, ".;") ~= "" and vim.fn.fnamemodify(vim.fn.findfile(file, ".;"), ":p") or file
  if vim.fn.filereadable(path) == 0 then
    return Snacks.notify.warn("No file " .. file)
  end
  open_beside(vim.api.nvim_get_current_win(), path, lnum)
end

-- Normal mode in a chat; `?` lists them too.
local CHAT_NORMAL_KEYS = {
  { "gf", open_mentioned, "open file(:line) beside the chat" },
  { "gF", open_mentioned, "same as gf" },
}

local function map_chat_keys(buf)
  for _, key in ipairs(CHAT_NORMAL_KEYS) do
    vim.keymap.set("n", key[1], function()
      key[2](buf)
    end, { buffer = buf, desc = "isovim: " .. key[3] })
  end
  for _, key in ipairs(CHAT_KEYS) do
    local rhs = key[2]
    if type(rhs) == "function" then
      local fn = rhs
      rhs = function()
        fn(buf)
      end
    end
    vim.keymap.set("t", key[1], rhs, { buffer = buf, desc = "isovim: " .. key[3] })
  end
end

-- Named "<workspace> · <agent>" for :ls and pickers; the ids keep same-named ones apart.
local function name_chat(buf)
  local ws, agent = vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main"
  local spec = store.agent(ws, agent)
  vim.b[buf].isovim_agent_name = spec and spec.name or agent
  vim.b[buf].isovim_agent_kind = spec and spec.kind or "claude"
  local name = store.name(ws):gsub("/", "-")
  vim.api.nvim_buf_set_name(buf, ("isovim://%s/%s/%s · %s"):format(ws, agent, name, vim.b[buf].isovim_agent_name))
end

-- The agent a workspace opens to: its first one you can see.
local function default_agent(ws)
  local agents = store.agents(ws)
  for _, agent in ipairs(agents) do
    if not agent.hidden then
      return agent.id
    end
  end
  return agents[1] and agents[1].id
end

---@param agent? string defaults to the workspace's first visible agent
---@param win? integer where to show it (default: the first editing window)
function M.open(ws, agent, win)
  agent = agent or default_agent(ws)
  local spec = store.agent(ws, agent)
  if not spec then
    Snacks.notify.error(("No agent %s in %s"):format(agent, store.name(ws)))
    return
  end
  if not panes.running(ws, agent) then
    local result = panes.start(ws, spec, store.dir(ws))
    if result.code ~= 0 then
      Snacks.notify.error("Could not start " .. spec.name .. ":\n" .. result.stderr)
      return
    end
  end
  -- Before the chat enters its window, so the statusline reads the project's git branch.
  enter_dir(ws)
  win = win or main_win()
  vim.api.nvim_set_current_win(win)
  local buf, stale = chat_buf(ws, agent)
  if buf then
    vim.api.nvim_win_set_buf(win, buf)
  else
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    -- After the swap, so wiping them can't close the window; before naming, which they'd clash with.
    for _, old in ipairs(stale) do
      vim.api.nvim_buf_delete(old, { force = true })
    end
    stream.attach(buf, ws, agent)
    vim.b[buf].isovim_id = ws
    vim.b[buf].isovim_ws = ws
    vim.b[buf].isovim_agent = agent
    name_chat(buf)
    map_chat_keys(buf)
  end
  status.mark_seen(ws, agent)
  select(ws)
  -- The workspace's splits may have come back around it; the chat opened is the one to focus.
  local shown = vim.fn.bufwinid(buf)
  if shown ~= -1 then
    vim.api.nvim_set_current_win(shown)
  end
end

-- A chat on screen counts as read, even while the sidebar has focus.
-- Only while you're in the TUI: a chat that finishes on screen while you're in another app stays
-- unread (and notifies) until you come back.
local function mark_visible_seen()
  if not M.focused then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].isovim_id then
      status.mark_seen(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main")
    end
  end
end

-- Restarts an agent (Claude on the same conversation), e.g. to pick up new hooks.
-- The chat comes back on screen only if it was there.
function M.restart(ws, agent)
  agent = agent or default_agent(ws)
  panes.stop(ws, agent)
  local shown = false
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      shown = shown or vim.fn.bufwinid(buf) ~= -1
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if shown then
    M.open(ws, agent)
  else
    panes.start(ws, assert(store.agent(ws, agent)), store.dir(ws))
  end
end

local function needs_you(agent)
  return not agent.hidden and (agent.status == "unread" or agent.status == "attention")
end

local refresh -- below: refreshes keep the cursor on its item

local function refresh_sidebar()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1]
  if sidebar then
    refresh(sidebar)
  end
end

M.queue = {} ---@type {ws: string, ws_name: string, agent: string, name: string, status: isovim.Status}[]

-- A path as the sidebar names it: relative to the workspace's project dir when inside it.
local function short_path(ws, path)
  local dir = store.dir(ws)
  if dir and vim.startswith(path, dir .. "/") then
    return path:sub(#dir + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- Rows: each workspace with its agents, or its PRs while P is on. Hidden agents show only
-- while show_hidden is on. Unread/attention agents also go to M.queue, the "Needs you" pane.
-- Another host's agent that newly needs you toasts here too (its own notification shows on that
-- host's screen). A host's first listing only sets what counts as new.
local remote_notified = {} ---@type table<string, table<string, string|false>>
local function notify_remote(host, rows)
  local first = remote_notified[host] == nil
  local seen = remote_notified[host] or {}
  remote_notified[host] = seen
  for _, row in ipairs(rows) do
    local now = (row.status == "unread" or row.status == "attention") and row.status or false
    if not first and not row.hidden and now and seen[row.id] ~= now then
      local message = ("%s · %s · %s %s"):format(host, row.workspace, row.agent, now == "attention" and "needs you" or "finished")
      Snacks.notify(message, { level = now == "attention" and "warn" or "info", title = "isovim" })
      if not M.focused then
        vim.system({ panes.hook_script, "desktop", message })
      end
    end
    seen[row.id] = now
  end
end

local function sidebar_items()
  mark_visible_seen()
  local sessions = panes.sessions()
  local titles = panes.titles()
  local workspaces = store.list()
  local queue = {}
  local working = false
  for _, ws in ipairs(workspaces) do
    local running = sessions[ws.id] or {}
    ws.active = ws.modified
    ws.agents = {}
    for _, agent in ipairs(store.agents(ws.id)) do
      agent.running = running[agent.id] ~= nil
      agent.status = status.get(ws.id, agent.id)
      ws.active = math.max(ws.active, running[agent.id] or 0)
      if not agent.hidden or M.show_hidden then
        ws.agents[#ws.agents + 1] = agent
        working = working or agent.status == "working"
      end
      if needs_you(agent) then
        queue[#queue + 1] =
          { ws = ws.id, ws_name = ws.name, agent = agent.id, name = agent.name, kind = agent.kind, status = agent.status }
      end
    end
  end
  -- The other hosts' agents, by host then workspace, as their `iso ls` lists them.
  local hosts = {}
  for name, host in pairs(remote.peers()) do
    local rows = remote.list(name, host, refresh_sidebar)
    if rows then
      notify_remote(name, rows)
    end
    if remote.down(name) then
      hosts[#hosts + 1] = { name = name, ssh = host, order = {}, by_ws = {}, down = true }
    elseif rows and #rows > 0 then
      local by_ws, order = {}, {}
      for _, row in ipairs(rows) do
        local ws_id = row.id:match("^[^/]+")
        local state = row.status ~= "idle" and row.status ~= "stopped" and row.status or nil
        local agent = { id = row.id, name = row.agent, kind = row.kind, status = state, running = row.status ~= "stopped", hidden = row.hidden, doing = row.doing }
        if not by_ws[ws_id] then
          by_ws[ws_id] = { name = row.workspace, agents = {} }
          order[#order + 1] = ws_id
        end
        if not agent.hidden or M.show_hidden then
          table.insert(by_ws[ws_id].agents, agent)
        end
        if needs_you(agent) then
          queue[#queue + 1] = { host = name, ssh = host, remote_id = row.id, ws_name = name .. ":" .. row.workspace, name = row.agent, kind = row.kind, status = state }
        end
      end
      hosts[#hosts + 1] = { name = name, ssh = host, order = order, by_ws = by_ws }
    end
  end
  table.sort(hosts, function(a, b)
    return a.name < b.name
  end)

  status.animate(working)
  table.sort(workspaces, function(a, b)
    return a[M.sort] > b[M.sort]
  end)
  table.sort(queue, function(a, b)
    return (a.status == "attention" and 0 or 1) < (b.status == "attention" and 0 or 1)
  end)
  M.queue = queue

  local items = {}
  local function agent_item(ws, agent)
    items[#items + 1] = {
      kind = "agent",
      text = ws.name .. " " .. agent.name,
      ws = ws.id,
      ws_name = ws.name,
      agent = agent.id,
      name = agent.name,
      agent_kind = agent.kind,
      status = agent.status,
      running = agent.running,
      hidden = agent.hidden,
      subtitle = agent.running and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id]) or nil,
      ports = agent.running and require("isovim.ports").of(ws.id, agent.id) or nil,
    }
  end
  for _, ws in ipairs(workspaces) do
    local running = vim.iter(ws.agents):any(function(agent)
      return agent.running
    end)
    local base = { ws = ws.id, ws_name = ws.name }
    local added, removed = diffstat.get(ws.dir, refresh_sidebar)
    items[#items + 1] = vim.tbl_extend(
      "force",
      base,
      { kind = "workspace", text = ws.name, running = running, added = added, removed = removed }
    )
    if M.show_prs then
      local list = prs.list(ws.id, refresh_sidebar)
      for _, pr in ipairs(list) do
        local text = ws.name .. " " .. (pr.title or pr.url)
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "pr", text = text, pr = pr })
      end
      if #list == 0 then
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "empty", text = ws.name .. " no PRs yet" })
      end
    else
      for _, agent in ipairs(ws.agents) do
        agent_item(ws, agent)
      end
      for _, entry in ipairs(store.pinned(ws.id)) do
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "path",
          text = ws.name .. " " .. (entry.label or entry.path),
          path = entry.path,
          label = entry.label or short_path(ws.id, entry.path),
          is_dir = vim.fn.isdirectory(entry.path) == 1,
        })
      end
    end
  end
  if #workspaces == 0 then
    items[#items + 1] = { kind = "hint", text = "no workspaces · a new · ? keys" }
  end
  if not M.show_prs then
    for _, host in ipairs(hosts) do
      items[#items + 1] = { kind = "host", text = host.name, host = host.name, ws = "@" .. host.name, down = host.down }
      for _, ws_id in ipairs(host.order) do
        local ws = host.by_ws[ws_id]
        local base = { host = host.name, ssh = host.ssh, ws = host.name .. ":" .. ws_id, ws_name = ws.name, remote_ws = ws_id }
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "workspace",
          text = host.name .. " " .. ws.name,
          running = vim.iter(ws.agents):any(function(agent)
            return agent.running
          end),
        })
        for _, agent in ipairs(ws.agents) do
          items[#items + 1] = vim.tbl_extend("force", base, {
            kind = "agent",
            text = host.name .. " " .. ws.name .. " " .. agent.name,
            agent = agent.id,
            remote_id = agent.id,
            name = agent.name,
            agent_kind = agent.kind,
            status = agent.status,
            running = agent.running,
            hidden = agent.hidden,
            subtitle = agent.doing,
          })
        end
      end
    end
  end
  return items
end

-- Agents are indented under their workspace with a status icon.
-- Anything not running is dimmed; hidden agents are italic.
local function format_item(item)
  if item.kind == "hint" then
    return { { "  " .. item.text, "Comment" } }
  elseif item.kind == "host" then
    -- A divider: what follows is on that machine.
    if item.down then
      return { { "── ", "Comment" }, { icons.get("host"), "Comment" }, { " " .. item.host .. " unreachable ", "Comment" }, { ("─"):rep(40), "Comment" } }
    end
    return { { "── ", "Comment" }, { icons.get("host") }, { " " }, { item.host, "Title" }, { " " .. ("─"):rep(40), "Comment" } }
  elseif item.kind == "workspace" then
    local folder, folder_hl = icons.get(item.ws == M.current and "workspace_current" or "workspace")
    local row = { { folder, folder_hl }, { " " }, { item.ws_name, item.running and "Directory" or "Comment" } }
    if item.added and item.added + item.removed > 0 then
      vim.list_extend(row, { { " +" .. item.added, "Added" }, { " −" .. item.removed, "Removed" } })
    end
    return row
  elseif item.kind == "empty" then
    return { { "    no PRs yet", "Comment" } }
  elseif item.kind == "path" then
    local icon, hl = "\u{f07b}", "Directory"
    if not item.is_dir then
      local ok, mini = pcall(require, "mini.icons")
      icon, hl = "\u{f15b}", "Comment"
      if ok then
        icon, hl = mini.get("file", item.path)
      end
    end
    return { { "  " }, { " " }, { " " }, { icon, hl }, { " " }, { item.label, item.is_dir and "Directory" or nil } }
  elseif item.kind == "pr" then
    local icon, hl = prs.icon(item.pr)
    local label = item.pr.number and ("#%d %s"):format(item.pr.number, item.pr.title) or item.pr.url
    -- The CI mark before the title, which the sidebar's width often cuts.
    local row = vim.list_extend({ { "  " }, { icon, hl } }, prs.marks(item.pr))
    return vim.list_extend(row, { { " " }, { label, item.pr.state ~= "OPEN" and "Comment" or nil } })
  end
  local icon, hl = status.icon(item.status)
  local kind_icon, kind_hl = icons.get(item.agent_kind)
  local name_hl = item.hidden and "Comment" or (not item.running and "Comment" or nil)
  local row = {
    { "  " },
    { icon, hl },
    { " " },
    { kind_icon, kind_hl },
    { " " },
    { item.name, name_hl },
  }
  if item.hidden then
    row[#row + 1] = { " (hidden)", "Comment" }
  end
  -- What it's on: the task title Claude gives its terminal, or the command a terminal runs.
  -- The ports it serves on first: the subtitle is often long enough to be cut off.
  if M.show_ports and item.ports and #item.ports > 0 then
    row[#row + 1] = { "  :" .. table.concat(item.ports, " :"), "Special" }
  end
  if item.subtitle and item.subtitle ~= item.name then
    row[#row + 1] = { "  " .. item.subtitle, "Comment" }
  end
  return row
end

-- The sidebar's cursor sits on what you're looking at: the agent in the focused window, or else the
-- current workspace. Left alone while you're moving around the sidebar yourself.
local function follow(picker)
  if picker.closed or is_sidebar(vim.api.nvim_get_current_win()) then
    return
  end
  local shown = vim.api.nvim_get_current_buf()
  local agent = vim.b[shown].isovim_id == M.current and vim.b[shown].isovim_agent
  local target
  for i = 1, picker.list:count() do
    local item = picker.list:get(i)
    if item.ws == M.current then
      if item.kind == "agent" and item.agent == agent then
        target = i
        break
      elseif item.kind == "workspace" then
        target = target or i
      end
    end
  end
  if target then
    picker.list:view(target)
  end
end

local function same_row(a, b)
  return a.kind == b.kind and a.ws == b.ws and a.agent == b.agent and a.path == b.path
    and (a.pr and a.pr.url) == (b.pr and b.pr.url)
end

local queue_ns = vim.api.nvim_create_namespace("isovim_queue")

-- The "Needs you" pane is the picker's preview window: rendered from M.queue whatever the
-- list's cursor is on, and hidden while the queue is empty.
local function render_queue(preview)
  local lines, marks = {}, {}
  for i, entry in ipairs(M.queue) do
    local icon, hl = status.icon(entry.status)
    local kind_icon, kind_hl = icons.get(entry.kind)
    lines[i] = (" %s %s %s · %s"):format(icon, kind_icon, entry.ws_name, entry.name)
    marks[i] = { { 1, #icon, hl }, { 2 + #icon, #kind_icon, kind_hl } }
  end
  preview:set_lines(lines)
  vim.api.nvim_buf_clear_namespace(preview.win.buf, queue_ns, 0, -1)
  for i, row in ipairs(marks) do
    for _, mark in ipairs(row) do
      local col, len, hl = unpack(mark)
      vim.api.nvim_buf_set_extmark(preview.win.buf, queue_ns, i - 1, col, { end_col = col + len, hl_group = hl })
    end
  end
  preview:wo({ cursorline = true, number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0" })
end

-- The pane is as tall as the queue, so it never shows empty rows.
local function size_queue(picker)
  local function find(box)
    if box.win == "preview" then
      return box
    end
    for _, child in ipairs(box) do
      local found = type(child) == "table" and find(child)
      if found then
        return found
      end
    end
  end
  local box = find(picker.layout.opts.layout)
  local height = math.min(#M.queue, 10)
  if box and box.height ~= height then
    box.height = height
    picker.layout:update()
  end
end

local function update_queue(picker)
  if picker.closed then
    return
  end
  local want = #M.queue > 0
  if want then
    size_queue(picker)
  end
  if picker.layout:is_hidden("preview") == want then
    picker:toggle("preview", { enable = want })
  end
  if want and picker.preview.win:valid() then
    render_queue(picker.preview)
  end
end

-- Rows can shift (activity sort, the queue, subtitles), so the cursor keeps its item, not its row number.
-- Rebuilding the list resets the cursor to row 1 until the finder is done; a target holds the view
-- where it is meanwhile. Bursts of refreshes (the poll, hooks, PR updates) run once.
function refresh(picker)
  if picker.isovim_refresh_pending then
    return
  end
  picker.isovim_refresh_pending = true
  vim.defer_fn(function()
    picker.isovim_refresh_pending = nil
    if not picker.closed then
      M.refresh_now(picker)
    end
  end, 30)
end

function M.refresh_now(picker)
  local before = picker.list:current()
  picker.list:set_target(picker.list.cursor, picker.list.top, { force = true })
  picker:find({
    refresh = true,
    on_done = function()
      update_queue(picker)
      if not is_sidebar(vim.api.nvim_get_current_win()) or not before then
        return follow(picker)
      end
      for i = 1, picker.list:count() do
        if same_row(picker.list:get(i), before) then
          return picker.list:view(i)
        end
      end
    end,
  })
end

function M.follow()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1]
  if sidebar then
    follow(sidebar)
  end
end

-- An isovim toast for news from outside the TUI, e.g. a workspace moved in from another host.
function M.toast(message)
  Snacks.notify(message, { title = "isovim" })
end

-- Picks up changes made outside the TUI, e.g. by the `iso` CLI.
-- Workspaces archived or moved away (here or by the CLI) leave no chats or selection behind.
local function drop_gone()
  local here = {}
  for _, ws in ipairs(store.list()) do
    here[ws.id] = true
  end
  for _, buf in ipairs(chat_bufs()) do
    if not here[vim.b[buf].isovim_id] then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if M.current and not here[M.current] then
    select(nil)
  end
end

function M.refresh()
  drop_gone()
  for _, buf in ipairs(chat_bufs()) do
    name_chat(buf)
  end
  local sidebar = Snacks.picker.get({ source = "isovim" })[1]
  if sidebar then
    refresh(sidebar)
  end
end

M.focused = true
local notified = {} ---@type table<string, isovim.Status>

-- Toast when an agent off screen finishes or needs you; a desktop notification too while
-- the TUI isn't focused. Hidden agents never notify. The first pass after setup only
-- records, so reloads stay quiet.
local function notify_changes(quiet)
  mark_visible_seen()
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local key = ws.id .. "/" .. agent.id
      local now = status.get(ws.id, agent.id)
      if not quiet and not agent.hidden and now ~= notified[key] and (now == "unread" or now == "attention") then
        local message = ("%s · %s %s"):format(ws.name, agent.name, now == "attention" and "needs you" or "finished")
        Snacks.notify(message, { level = now == "attention" and "warn" or "info", title = "isovim" })
        if not M.focused then
          vim.system({ panes.hook_script, "desktop", message })
        end
      end
      notified[key] = now
    end
  end
end

-- Stops the agent, closes its chat and drops it from the workspace.
function M.remove_agent(ws, agent)
  panes.stop(ws, agent)
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  store.remove_agent(ws, agent)
  M.refresh()
end

-- Terminals whose shell exited (panes.start's pane-exited hook): gone, with their chats.
local function drop_exited()
  local dropped = false
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local exited = status.state(ws.id, agent.id) == "exited"
      if exited and panes.running(ws.id, agent.id) then
        -- The hook can beat tmux closing the session; look again once it has.
        vim.defer_fn(function()
          if drop_exited() then
            M.refresh()
          end
        end, 500)
      elseif exited then
        for _, buf in ipairs(chat_bufs()) do
          if vim.b[buf].isovim_id == ws.id and vim.b[buf].isovim_agent == agent.id then
            -- Its split closes; the last window shows another buffer.
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
              local mains = vim.tbl_filter(function(w)
                return not is_sidebar(w)
              end, vim.api.nvim_tabpage_list_wins(0))
              if #mains > 1 then
                vim.api.nvim_win_close(win, true)
              end
            end
            Snacks.bufdelete({ buf = buf, force = true })
          end
        end
        vim.cmd.stopinsert()
        store.remove_agent(ws.id, agent.id)
        os.remove(store.state_file(ws.id, agent.id))
        dropped = true
      end
    end
  end
  return dropped
end

local function add_agent(ws, spec)
  local agent = store.add_agent(ws, spec)
  M.open(ws, agent.id)
  M.refresh()
end

-- H, P and L show in the sidebar's title as badges, like the explorer's hidden-files toggle:
-- snacks draws a badge for each `toggles` entry whose picker option is on.
local TOGGLES = { isovim_hidden = "h", isovim_prs = "p", isovim_ports = "l" }

local function show_toggles(picker)
  picker.opts.isovim_hidden, picker.opts.isovim_prs, picker.opts.isovim_ports = M.show_hidden, M.show_prs, M.show_ports
  picker:update_titles()
end

local actions = {
  isovim_open = function(_, item)
    if not item or item.kind == "empty" or item.kind == "hint" then
      return
    elseif item.kind == "pr" then
      vim.ui.open(item.pr.url)
    elseif item.kind == "path" then
      M.reveal(item.ws, item.path)
    elseif item.host then
      if item.remote_id then
        M.open_remote(item.host, item.ssh, item.remote_id, item.ws_name, item.name)
      end
    else
      M.open(item.ws, item.agent)
    end
  end,
  isovim_open_queued = function(picker)
    local row = vim.api.nvim_win_get_cursor(picker.preview.win.win)[1]
    local entry = M.queue[row]
    if entry and entry.host then
      M.open_remote(entry.host, entry.ssh, entry.remote_id, entry.ws_name, entry.name)
    elseif entry then
      M.open(entry.ws, entry.agent)
    end
  end,
  isovim_focus_queue = function(picker)
    if not picker.layout:is_hidden("preview") then
      picker:focus("preview")
    end
  end,
  isovim_focus_list = function(picker)
    picker:focus("list")
  end,
  isovim_toggle_prs = function(picker)
    remember("show_prs", not M.show_prs)
    show_toggles(picker)
    refresh(picker)
  end,
  isovim_add = function(picker)
    vim.ui.input({ prompt = "New workspace: " }, function(name)
      if not name or name == "" then
        return
      end
      -- Where it works: the project you're in, then the ones workspaces used, a path, or none.
      local choices = {}
      local here = vim.fn.getcwd()
      local home = vim.fs.normalize("~")
      if here ~= home and not vim.startswith(here, store.root) then
        choices[1] = vim.fn.fnamemodify(here, ":~")
      end
      for _, project in ipairs(store.projects()) do
        if not vim.tbl_contains(choices, project) then
          choices[#choices + 1] = project
        end
      end
      local TYPE, NONE = "another dir…", "none: its own dir"
      vim.list_extend(choices, { TYPE, NONE })
      local function with_dir(dir)
        if dir == nil then
          return
        end
        dir = dir ~= "" and vim.fs.normalize(dir) or nil
        if dir and vim.fn.isdirectory(dir) == 0 then
          Snacks.notify.error(dir .. " is not a directory")
          return
        end
        local function create(worktree)
          -- Making a worktree fetches the default branch first, which can take a few seconds.
          if worktree then
            Snacks.notify.info("Making " .. name .. "'s worktree…", { title = "isovim", id = "isovim_worktree" })
            vim.cmd.redraw()
          end
          local id, err = store.create(name, dir, worktree)
          Snacks.notifier.hide("isovim_worktree")
          if not id then
            Snacks.notify.error("Could not make the worktree:\n" .. err)
            return
          end
          -- A fresh worktree runs the repo's setup script (deps, .env) in a terminal of its own.
          if worktree and require("isovim.scripts").start(id, "setup") then
            Snacks.notify.info("Running " .. name .. "'s setup script", { title = "isovim" })
          end
          M.open(id)
          M.refresh()
        end
        local worktree = require("isovim.worktree")
        if not dir or not worktree.is_repo(dir) then
          return create(false)
        end
        -- A repo: a worktree of its own by default, or the checkout itself.
        local choices = {
          "New worktree on " .. worktree.branch_for(name),
          "Worktree of a branch or PR…",
          "Work in " .. vim.fn.fnamemodify(dir, ":~") .. " itself",
        }
        vim.ui.select(choices, { prompt = name }, function(_, i)
          if i == 2 then
            vim.ui.input({ prompt = "Branch, or PR number or URL: " }, function(ref)
              if ref and vim.trim(ref) ~= "" then
                create(vim.trim(ref))
              end
            end)
          elseif i then
            create(i == 1)
          end
        end)
      end
      vim.ui.select(choices, { prompt = "Project for " .. name }, function(choice)
        if choice == TYPE then
          vim.ui.input({ prompt = "Project dir: ", completion = "dir" }, with_dir)
        elseif choice == NONE then
          with_dir("")
        elseif choice then
          with_dir(choice)
        end
      end)
    end)
  end,
  isovim_add_agent = function(_, item)
    if not item or not item.ws then
      return
    end
    local format = function(kind)
      return icons.get(kind) .. " " .. kind
    end
    vim.ui.select(panes.kinds, { prompt = "New agent in " .. item.ws_name, format_item = format }, function(kind)
      if kind == "command" then
        vim.ui.input({ prompt = "Command: " }, function(cmd)
          if cmd and cmd ~= "" then
            add_agent(item.ws, { kind = kind, name = cmd:match("^%S+"), cmd = cmd })
          end
        end)
      elseif kind then
        add_agent(item.ws, { kind = kind })
      end
    end)
  end,
  isovim_find = function()
    M.find()
  end,
  isovim_open_port = function(_, item)
    if item and item.ws and not item.host then
      M.open_port(item.ws, item.kind == "agent" and item.agent or nil)
    end
  end,
  isovim_changes = function(_, item)
    if item and item.ws and not item.host then
      M.changes(item.ws)
    end
  end,
  isovim_restart = function(_, item)
    if item and item.kind == "agent" and not item.host then
      Snacks.picker.util.confirm(("Restart %s?"):format(item.name), function()
        M.restart(item.ws, item.agent)
        M.refresh()
      end)
    end
  end,
  -- t opens a new terminal in the workspace under the cursor; it outlives the TUI like the agents.
  isovim_terminal = function(_, item)
    local ws = item and item.ws or M.current
    if ws then
      add_agent(ws, { kind = "terminal" })
    end
  end,
  isovim_rename = function(picker, item)
    if not item or not item.ws then
      return
    end
    -- On an agent row it renames the agent, e.g. a terminal after what runs in it.
    if item.kind == "agent" then
      return vim.ui.input({ prompt = "Rename agent: ", default = item.name }, function(name)
        if name and name ~= "" then
          store.update_agent(item.ws, item.agent, { name = name })
          M.refresh()
        end
      end)
    end
    vim.ui.input({ prompt = "Rename workspace: ", default = item.ws_name }, function(name)
      if name and name ~= "" then
        store.rename(item.ws, name)
        M.refresh()
      end
    end)
  end,
  -- d on an agent removes it (its process and chat go too); on a workspace, archives it.
  isovim_delete = function(picker, item)
    if not item or not item.ws then
      return
    elseif item.kind == "path" then
      store.unpin(item.ws, item.path)
      return refresh(picker)
    elseif item.kind == "agent" then
      Snacks.picker.util.confirm(("Remove %s from %s?"):format(item.name, item.ws_name), function()
        M.remove_agent(item.ws, item.agent)
      end)
      return
    end
    Snacks.picker.util.confirm("Archive " .. item.ws_name .. "?", function()
      panes.stop_all(item.ws)
      local ok, err, note = store.archive_workspace(item.ws)
      if not ok then
        Snacks.notify.error("Could not archive " .. item.ws_name .. ":\n" .. err)
      elseif note then
        Snacks.notify.warn(item.ws_name .. " archived; " .. note, { title = "isovim" })
      end
      M.refresh()
    end)
  end,
  -- m moves the workspace to another host; its agents resume there (iso move).
  isovim_move = function(picker, item)
    if not item or not item.ws then
      return
    elseif item.host then
      return M.move_here(item)
    end
    local peers = remote.peers()
    local hosts = vim.tbl_keys(peers)
    if #hosts == 0 then
      Snacks.notify.error("No other hosts in " .. require("isovim.config").path)
      return
    end
    local ws, name = item.ws, item.ws_name
    vim.ui.select(hosts, { prompt = "Move " .. name .. " to" }, function(host)
      if not host then
        return
      end
      local function move(force)
        Snacks.notify.info(("Moving %s to %s…"):format(name, host), { title = "isovim" })
        local cmd = { panes.bin, "move", ws, peers[host], force and "--force" or nil }
        vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
          local busy = result.stderr:match("iso: (.- is working)")
          if busy then
            Snacks.picker.util.confirm(busy .. ". Move anyway?", function()
              move(true)
            end)
            return
          elseif result.code ~= 0 then
            Snacks.notify.error(vim.trim(result.stderr))
            return
          end
          remote.invalidate(host)
          M.toast(("%s moved to %s"):format(name, host))
          M.refresh()
        end))
      end
      move(false)
    end)
  end,
  isovim_toggle_hidden = function(picker)
    remember("show_hidden", not M.show_hidden)
    show_toggles(picker)
    refresh(picker)
  end,
  isovim_toggle_ports = function(picker)
    remember("show_ports", not M.show_ports)
    show_toggles(picker)
    refresh(picker)
  end,
  isovim_explorer = function()
    M.show_explorer()
  end,
  isovim_focus_chat = function()
    vim.api.nvim_set_current_win(main_win())
  end,
  isovim_last_workspace = function()
    M.last_workspace()
  end,
  isovim_help = function()
    M.help()
  end,
  isovim_sort = function(picker)
    remember("sort", M.sort == "created" and "active" or "created")
    Snacks.notify.info("Sorted by " .. (M.sort == "created" and "creation time" or "recent activity"))
    refresh(picker)
  end,
}

-- {key, action, description}: the sidebar list's and the Needs-you pane's keys, which `?` lists.
local LIST_KEYS = {
  { "<cr>", "isovim_open", "open the agent or PR; a pinned file beside the chat, a folder in the explorer" },
  { "a", "isovim_add", "new workspace" },
  { "A", "isovim_add_agent", "new agent in this workspace" },
  { "t", "isovim_terminal", "new terminal in this workspace" },
  { "r", "isovim_rename", "rename the workspace or agent" },
  { "d", "isovim_delete", "remove the agent or pinned path, or archive the workspace" },
  { "c", "isovim_changes", "its changes since its base" },
  { "o", "isovim_open_port", "open its dev server (the port it listens on) in the browser" },
  { "f", "isovim_find", "find the agent that was on something, on any host (iso find)" },
  { "R", "isovim_restart", "restart the agent (it resumes)" },
  { "m", "isovim_move", "move it to another host, or here" },
  { "s", "isovim_sort", "sort by creation or by recent activity" },
  { "H", "isovim_toggle_hidden", "show or hide hidden agents" },
  { "L", "isovim_toggle_ports", "show or hide the ports agents listen on" },
  { "P", "isovim_toggle_prs", "agents or PRs" },
  { "b", "isovim_last_workspace", "back to the last workspace" },
  { "E", "isovim_explorer", "file explorer (W comes back)" },
  { "<c-k>", "isovim_focus_queue", "into Needs you" },
  { "<c-l>", "isovim_focus_chat", "to the chat" },
  { "?", "isovim_help", "this help" },
}
local QUEUE_KEYS = {
  { "<cr>", "isovim_open_queued", "open that agent" },
  { "<c-j>", "isovim_focus_list", "back to the list" },
  { "<c-l>", "isovim_focus_chat", "to the chat" },
}

local function keys_of(spec)
  local keys = {}
  for _, key in ipairs(spec) do
    if key[1] ~= "<cr>" or key[2] ~= "isovim_open" then
      keys[key[1]] = key[2]
    end
  end
  return keys
end

-- A float listing every isovim key, built from the tables above and the live <leader> maps.
function M.help()
  local lines = {}
  local function section(title, keys)
    lines[#lines + 1] = "# " .. title
    for _, key in ipairs(keys) do
      lines[#lines + 1] = ("  %-12s %s"):format(key[1], key[#key])
    end
    lines[#lines + 1] = ""
  end
  section("Sidebar", LIST_KEYS)
  section("Needs you", QUEUE_KEYS)
  section("Chat (terminal mode)", CHAT_KEYS)
  section("Chat (normal mode)", CHAT_NORMAL_KEYS)
  local leader = {}
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.desc and map.desc:match("^isovim: ") then
      leader[#leader + 1] = { (map.lhs:gsub("^" .. vim.pesc(vim.g.mapleader or "\\"), "<leader>")), map.desc:sub(6) }
    end
  end
  table.sort(leader, function(a, b)
    return a[1] < b[1]
  end)
  section("Anywhere (normal mode)", leader)
  lines[#lines] = nil
  Snacks.win({
    text = lines,
    ft = "markdown",
    title = " isovim keys ",
    title_pos = "center",
    border = "rounded",
    width = 64,
    height = #lines,
    wo = { wrap = false, conceallevel = 2 },
    keys = { q = "close", ["?"] = "close" },
  })
end

-- Another host's rows only open; changing them is that host's business.
for _, name in ipairs({ "isovim_add_agent", "isovim_terminal", "isovim_rename", "isovim_delete" }) do
  local action = actions[name]
  actions[name] = function(picker, item)
    if item and item.host then
      return Snacks.notify.info(("That's on %s; change it there"):format(item.host), { title = "isovim" })
    end
    return action(picker, item)
  end
end

---@param opts? {enter?: boolean}
function M.open_sidebar(opts)
  Snacks.picker.pick({
    source = "isovim",
    enter = not opts or opts.enter ~= false,
    title = "Workspaces",
    toggles = TOGGLES,
    isovim_hidden = M.show_hidden,
    isovim_prs = M.show_prs,
    isovim_ports = M.show_ports,
    finder = sidebar_items,
    format = format_item,
    focus = "list",
    show_empty = true,
    auto_close = false,
    jump = { close = false },
    layout = {
      layout = {
        backdrop = false,
        width = 40,
        min_width = 40,
        height = 0,
        position = "left",
        border = "none",
        box = "vertical",
        { win = "input", height = 1, border = true, title = "{title} {live} {flags}", title_pos = "center" },
        { win = "preview", title = "Needs you", title_pos = "center", height = 6, border = true },
        { win = "list", border = "none" },
      },
    },
    preview = function(ctx)
      render_queue(ctx.preview)
    end,
    matcher = { sort_empty = false },
    confirm = "isovim_open",
    actions = actions,
    on_show = refresh,
    win = {
      list = {
        keys = keys_of(LIST_KEYS),
      },
      preview = {
        keys = keys_of(QUEUE_KEYS),
      },
    },
  })
end

-- The sidebar shows Workspaces (W) or a file explorer rooted at the current workspace (E).
-- Opening is deferred a tick: snacks errors if a picker opens while the closed one is still resizing.
---@param opts? {cwd?: string, reveal?: string} reveal: a file to select once it's open
function M.show_explorer(opts)
  opts = opts or {}
  M.view = "explorer"
  for _, source in ipairs({ "isovim", "explorer" }) do
    local open = Snacks.picker.get({ source = source })[1]
    if open then
      open:close()
    end
  end
  vim.schedule(function()
    -- Each workspace's explorer reopens where it was left: its root (a jump, <BS>, .) and the item
    -- the cursor was on; a workspace never moved around in opens at its dir.
    local key = M.current or ""
    local last = type(M.explorer_roots[key]) == "table" and M.explorer_roots[key] or {}
    if last.cwd and vim.fn.isdirectory(last.cwd) == 0 then
      last = {}
    end
    local reveal = opts.reveal or (not opts.cwd and last.file and vim.uv.fs_stat(last.file) and last.file) or nil
    Snacks.explorer({
      cwd = opts.cwd or last.cwd or (M.current and store.dir(M.current)) or store.workspaces,
      on_close = function(picker)
        local item = picker:current()
        M.explorer_roots[key] = { cwd = picker:cwd(), file = item and item.file }
        remember("explorer_roots", M.explorer_roots)
      end,
      actions = {
        isovim_workspaces = M.show_workspaces,
        isovim_focus_chat = function()
          vim.api.nvim_set_current_win(main_win())
        end,
      },
      win = { list = { keys = { ["W"] = "isovim_workspaces", ["<c-l>"] = "isovim_focus_chat" } } },
      on_show = reveal and function(picker)
        require("snacks.explorer.tree"):open(reveal)
        require("snacks.explorer.actions").update(picker, { target = reveal, refresh = true })
      end or nil,
    })
  end)
end

-- A pinned file opens beside the workspace's chat and the sidebar stays put; a pinned folder
-- becomes the explorer's root.
function M.reveal(ws, path)
  select(ws)
  if vim.fn.isdirectory(path) == 1 then
    return M.show_explorer({ cwd = path })
  end
  local chat_win = vim.tbl_filter(function(win)
    return not is_sidebar(win) and vim.b[vim.api.nvim_win_get_buf(win)].isovim_id == ws
  end, vim.api.nvim_tabpage_list_wins(0))[1]
  open_beside(chat_win or main_win(), path)
end

function M.show_workspaces()
  M.view = "workspaces"
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    explorer:close()
  end
  vim.schedule(M.open_sidebar)
end

-- Focuses the sidebar (Workspaces or the file explorer), or closes it when already there.
-- Reopening shows the view it had.
function M.sidebar()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if not sidebar then
    if M.view == "explorer" then
      M.show_explorer()
    else
      M.open_sidebar()
    end
  elseif is_sidebar(vim.api.nvim_get_current_win()) then
    sidebar:close()
  else
    sidebar:focus("list")
  end
end

-- The sidebar's file explorer, focused; from inside it, back to Workspaces. LazyVim's own explorer
-- keys come here too, rather than opening a second explorer beside the sidebar.
function M.files()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer then
    M.show_explorer()
  elseif is_sidebar(vim.api.nvim_get_current_win()) then
    M.show_workspaces()
  else
    explorer:focus("list")
  end
end

---@param opts? {reload?: boolean}
function M.setup(opts)
  local reloading = opts and opts.reload
  local session = store.read_session()
  if session.current and vim.uv.fs_stat(store.path(session.current)) then
    M.current = session.current
  end
  M.sort = session.sort or M.sort
  M.show_hidden = session.show_hidden or false
  M.show_prs = session.show_prs or false
  M.show_ports = session.show_ports or false
  M.explorer_roots = session.explorer_roots or {}
  M.recent = session.recent or {}

  icons.setup()
  vim.keymap.set("n", "<leader>e", M.sidebar, { desc = "isovim: focus or close the sidebar" })
  for _, lhs in ipairs({ "<leader>E", "<leader>fe", "<leader>fE" }) do
    vim.keymap.set("n", lhs, M.files, { desc = "isovim: the workspace's files in the sidebar" })
  end
  -- The sidebar's actions from anywhere, on the current workspace.
  local function on_current(action)
    return function()
      if not M.current then
        Snacks.notify.warn("No workspace selected")
        return
      end
      actions[action](nil, { ws = M.current, ws_name = store.name(M.current), kind = "workspace" })
    end
  end
  for lhs, map in pairs({
    ["<leader>at"] = { on_current("isovim_terminal"), "new terminal" },
    ["<leader>aa"] = { on_current("isovim_add_agent"), "new agent" },
    ["<leader>am"] = { on_current("isovim_move"), "move the workspace to another host" },
    ["<leader>an"] = { actions.isovim_add, "new workspace" },
    ["<leader>aj"] = { M.next_needs_you, "jump to what needs you" },
    ["<leader>ar"] = { M.run_script, "run the workspace's run script" },
    ["<leader>aw"] = { M.switch_workspace, "switch workspace" },
    ["<leader>ab"] = { M.last_workspace, "back to the last workspace" },
    ["<leader>au"] = { M.unarchive, "unarchive a workspace" },
    ["<leader>ad"] = { M.changes, "the workspace's changes since its base" },
    ["<leader>af"] = { function()
      M.find()
    end, "find the agent that was on something, on any host" },
    ["<leader>ao"] = { function()
      M.open_port(M.current)
    end, "open the workspace's dev server in the browser" },
  }) do
    vim.keymap.set("n", lhs, map[1], { desc = "isovim: " .. map[2] })
  end

  pcall(function()
    require("which-key").add({ { "<leader>a", group = "isovim" } })
  end)
  local group = vim.api.nvim_create_augroup("isovim", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local ws = vim.b[ev.buf].isovim_id
      if ws then
        status.mark_seen(ws, vim.b[ev.buf].isovim_agent or "main")
      end
      -- Reaching another workspace's buffer (e.g. with :b) selects that workspace.
      scope.tag(ev.buf, M.current)
      local tagged = vim.b[ev.buf].isovim_ws
      if tagged and tagged ~= "" and tagged ~= M.current then
        select(tagged)
      elseif ws then
        M.follow()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "WinResized", "WinEnter", "BufWinEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        layout.save(M.current, is_sidebar)
      end)
    end,
  })
  -- The sidebar never fills the screen alone: :q on the last editing window quits isovim as it would
  -- quit nvim (agents keep running), and losing it any other way (a chat wiped) puts back an empty one.
  local quitting = false
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      quitting = true
      vim.schedule(function()
        quitting = false
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      local by_quit = quitting
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if not is_sidebar(win) then
            return
          end
        end
        if by_quit then
          vim.cmd("confirm qall")
        else
          local sidebar_focused = is_sidebar(vim.api.nvim_get_current_win())
          local current = vim.api.nvim_get_current_win()
          main_win()
          if sidebar_focused then
            vim.api.nvim_set_current_win(current)
          end
        end
      end)
    end,
  })
  -- A prompt (new workspace, rename, ...) left behind is a float you can't reach: leaving one
  -- cancels it. (Snacks sets the prompt's filetype with events off, so FileType never fires.)
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "snacks_input" then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
    group = group,
    callback = function(ev)
      M.focused = ev.event == "FocusGained"
      if M.focused then
        M.refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      status.stop()
      store.release_lock()
    end,
  })

  -- The `iso` CLI and the agents' hooks find this instance by its socket.
  if not vim.tbl_contains(vim.fn.serverlist(), store.socket) then
    pcall(vim.fn.serverstart, store.socket)
  end

  enter_dir(M.current)
  scope.apply(M.current, is_sidebar)
  notify_changes(true)
  -- Files agents edit reload in their buffers (autoread) as an agent's state moves and, while one
  -- works, every second; nvim alone only looks on focus and buffer events.
  local function reload_files()
    if not vim.api.nvim_get_mode().mode:match("^[cr]") then
      pcall(vim.cmd.checktime)
    end
  end
  local ticks = 0
  drop_exited()
  status.start(function()
    if drop_exited() then
      return M.refresh()
    end
    notify_changes()
    reload_files()
    vim.cmd.redrawtabline()
    -- An agent that just went quiet has finished drawing: its chat must match its pane.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].isovim_id and status.state(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main") ~= "working" then
        vim.defer_fn(function()
          stream.check(buf)
        end, 500)
      end
    end
    local sidebar = Snacks.picker.get({ source = "isovim" })[1]
    if sidebar then
      refresh(sidebar)
    end
  end, function()
    ticks = ticks + 1
    if ticks % 10 == 0 then
      reload_files()
    end
    local sidebar = Snacks.picker.get({ source = "isovim" })[1]
    if sidebar then
      sidebar.list:update({ force = true })
    else
      status.animate(false)
    end
  end)

  -- PRs are watched in the background, not only in the P view, to tell you when checks finish
  -- or one merges.
  prs.on_news = function(ws, pr, news)
    local message = ("%s · #%s %s"):format(store.name(ws), pr.number or "?", news)
    Snacks.notify(message, { level = news == "checks failed" and "warn" or "info", title = "isovim" })
    if not M.focused then
      vim.system({ panes.hook_script, "desktop", message })
    end
  end
  if not _G.isovim_pr_timer then
    _G.isovim_pr_timer = vim.uv.new_timer()
    _G.isovim_pr_timer:start(5000, 60000, vim.schedule_wrap(function()
      require("isovim").poll_prs()
    end))
  end
  -- Timers call through require, so after a hot reload they run the new code; one an older isovim
  -- started with its own closure is replaced.
  if _G.isovim_title_timer and not _G.isovim_title_timer_polls then
    _G.isovim_title_timer:close()
    _G.isovim_title_timer = nil
  end
  _G.isovim_title_timer_polls = true
  if not _G.isovim_title_timer then
    _G.isovim_title_timer = vim.uv.new_timer()
    _G.isovim_title_timer:start(3000, 3000, vim.schedule_wrap(function()
      require("isovim").poll()
    end))
  end
  if not _G.isovim_idle_timer then
    _G.isovim_idle_timer = vim.uv.new_timer()
    _G.isovim_idle_timer:start(60000, 60000, vim.schedule_wrap(function()
      require("isovim.hooks").check_idle()
    end))
  end
  if reloading then
    for _, buf in ipairs(chat_bufs()) do
      map_chat_keys(buf)
      name_chat(buf)
    end
    -- The open sidebar's actions still point at the old code, in either view; the explorer's W
    -- would bring back an old Workspaces. Reopening it must not move the cursor: put back the
    -- window and mode (terminal/insert) the reload interrupted.
    local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
    if sidebar then
      local win = vim.api.nvim_get_current_win()
      -- Only the sidebar's own windows; a prompt you're typing in keeps the cursor.
      local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      local in_sidebar = ft:match("^snacks_picker") ~= nil or ft == "snacks_layout_box"
      local typing = vim.api.nvim_get_mode().mode:match("^[ti]") ~= nil
      local explorer = sidebar.opts.source == "explorer"
      sidebar:close()
      local function put_back_cursor()
        if not in_sidebar and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_set_current_win(win)
          if typing then
            vim.cmd.startinsert()
          end
        end
      end
      vim.schedule(function()
        if explorer then
          -- The old explorer saved where it was as it closed.
          M.explorer_roots = store.read_session().explorer_roots or {}
          M.show_explorer()
          vim.schedule(put_back_cursor)
        else
          M.open_sidebar({ enter = in_sidebar })
          put_back_cursor()
        end
      end)
    end
    return
  end
  require("isovim.reload").watch()
  if vim.fn.argc() == 0 then
    M.open_sidebar()
    vim.schedule(M.resume)
  end
end

-- Another host's agent, attached over ssh in a terminal here; reopening shows the same one.
function M.open_remote(host, ssh, id, ws_name, agent_name)
  local name = ("isovim://%s/%s · %s"):format(host, ws_name, agent_name)
  local buf = vim.fn.bufnr(name)
  local win = main_win()
  vim.api.nvim_set_current_win(win)
  if buf ~= -1 and vim.b[buf].terminal_job_id and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0)[1] == -1 then
    vim.api.nvim_win_set_buf(win, buf)
    return
  elseif buf ~= -1 then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)
  vim.fn.jobstart(remote.attach_cmd(ssh, id), { term = true })
  vim.api.nvim_buf_set_name(buf, name)
  vim.b[buf].isovim_agent_name = host .. " · " .. agent_name
  vim.b[buf].isovim_agent_kind = "host"
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { buffer = buf, desc = "isovim: leave the chat to normal mode" })
  vim.keymap.set("t", "<C-q>", function()
    vim.fn.chansend(vim.b[buf].terminal_job_id, "\27")
  end, { buffer = buf, desc = "isovim: send Esc to the agent" })
  vim.keymap.set("t", "<C-h>", focus_sidebar, { buffer = buf, desc = "isovim: go to the sidebar" })
  vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], { buffer = buf, desc = "isovim: go to the right window" })
end

-- ctrl+/ as in LazyVim, but the terminal is the workspace's own (it outlives the TUI and shows in
-- the sidebar): a bottom split shows it, or hides it if it's on screen. Without a workspace,
-- LazyVim's.
function M.toggle_terminal()
  local ws = M.current
  if not ws then
    return Snacks.terminal()
  end
  local is_terminal = function(kind)
    return kind == "terminal" or kind == "shell"
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].isovim_id == ws and is_terminal(vim.b[buf].isovim_agent_kind) and #vim.tbl_filter(function(w)
      return not is_sidebar(w)
    end, vim.api.nvim_tabpage_list_wins(0)) > 1 then
      vim.cmd.stopinsert()
      return vim.api.nvim_win_close(win, false)
    end
  end
  local agent
  for _, spec in ipairs(store.agents(ws)) do
    if is_terminal(spec.kind) and not agent then
      agent = spec.id
    end
  end
  agent = agent or store.add_agent(ws, { kind = "terminal" }).id
  local above = is_sidebar(vim.api.nvim_get_current_win()) and main_win() or vim.api.nvim_get_current_win()
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(placeholder, true, { split = "below", win = above, height = 15 })
  M.open(ws, agent, win)
  M.refresh()
end

-- Pick an archived workspace to bring back, and open it.
function M.unarchive()
  vim.ui.select(store.archived(), {
    prompt = "Unarchive",
    format_item = function(ws)
      return ws.name .. "  " .. os.date("%b %d %H:%M", ws.archived)
    end,
  }, function(ws)
    if not ws then
      return
    end
    local ok, err = store.unarchive(ws.id)
    if not ok then
      return Snacks.notify.error(err)
    elseif err then
      Snacks.notify.warn(err, { title = "isovim" })
    end
    M.open(ws.id)
    M.refresh()
  end)
end

-- m on another host's workspace: that host moves it here (iso move there, to this host's name),
-- and it opens once it lands.
function M.move_here(item)
  if not item.remote_ws then
    return
  end
  local me = remote.self()
  local function move(force)
    Snacks.notify.info(("Moving %s here from %s…"):format(item.ws_name, item.host), { title = "isovim" })
    local args = item.remote_ws .. " " .. me .. (force and " --force" or "")
    local cmd = ("%s %s %s"):format(remote.ssh, vim.fn.shellescape(item.ssh), vim.fn.shellescape(remote.remote_bin .. " move " .. args))
    vim.system({ "bash", "-c", cmd }, { text = true }, vim.schedule_wrap(function(result)
      local busy = (result.stderr or ""):match("iso: (.- is working)")
      if busy then
        return Snacks.picker.util.confirm(busy .. ". Move anyway?", function()
          move(true)
        end)
      elseif result.code ~= 0 then
        return Snacks.notify.error(vim.trim(result.stderr))
      end
      remote.invalidate(item.host)
      M.refresh()
      if vim.uv.fs_stat(store.path(item.remote_ws)) then
        M.open(item.remote_ws)
      end
    end))
  end
  move(false)
end

-- The workspace's changes: every hunk the workspace changed since its branch left the remote default
-- branch, committed or not, to read through and jump into; just the uncommitted ones without one.
---@param ws? string default: the current workspace
function M.changes(ws)
  ws = ws or M.current
  if not ws then
    return Snacks.notify.warn("No workspace selected")
  end
  local dir = store.dir(ws)
  local has_base = vim.system({ "git", "-C", dir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD" }):wait().code == 0
  Snacks.picker.git_diff({ cwd = dir, base = has_base and "origin/HEAD" or nil, title = store.name(ws) .. " changes" })
end

function M.new_workspace()
  actions.isovim_add()
end

-- Fuzzy-pick a workspace to switch to, most recently selected first.
-- The workspace you were in before this one, splits and all; again flips back, like vim's <C-^>.
function M.last_workspace()
  for _, id in ipairs(M.recent) do
    if id ~= M.current and vim.uv.fs_stat(store.path(id)) then
      return M.open(id)
    end
  end
  Snacks.notify.info("No other workspace yet", { title = "isovim" })
end

function M.switch_workspace()
  local sessions = panes.sessions()
  local workspaces = store.list()
  for _, ws in ipairs(workspaces) do
    ws.active = ws.modified
    for _, at in pairs(sessions[ws.id] or {}) do
      ws.active = math.max(ws.active, at)
    end
  end
  -- Alt-tab order: the ones you selected, most recent first, then the rest by activity.
  local rank = {}
  for i, id in ipairs(M.recent) do
    rank[id] = i
  end
  table.sort(workspaces, function(a, b)
    local ra, rb = rank[a.id] or math.huge, rank[b.id] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a.active > b.active
  end)
  workspaces = vim.tbl_filter(function(ws)
    return ws.id ~= M.current
  end, workspaces)
  vim.ui.select(workspaces, {
    prompt = "Workspace",
    format_item = function(ws)
      return ws.name .. "  " .. vim.fn.fnamemodify(ws.dir, ":~")
    end,
  }, function(ws)
    if ws then
      M.open(ws.id)
    end
  end)
end

-- The repo's run script (.isovim or .superset config.json), in a "run" terminal; again restarts it.
function M.run_script()
  if not M.current then
    return Snacks.notify.warn("No workspace selected")
  end
  local agent = require("isovim.scripts").start(M.current, "run")
  if not agent then
    return Snacks.notify.warn("No run script in .isovim/config.json or .superset/config.json")
  end
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == M.current and vim.b[buf].isovim_agent == agent then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.open(M.current, agent)
  M.refresh()
end

-- Opens the agent that has waited longest for you: questions before finished work.
function M.next_needs_you()
  local best
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      agent.status = status.get(ws.id, agent.id)
      if needs_you(agent) then
        local rank = agent.status == "attention" and 0 or 1
        local since = vim.fn.getftime(store.state_file(ws.id, agent.id))
        if not best or rank < best.rank or (rank == best.rank and since < best.since) then
          best = { ws = ws.id, agent = agent.id, rank = rank, since = since }
        end
      end
    end
  end
  if best then
    M.open(best.ws, best.agent)
  else
    Snacks.notify.info("Nothing needs you", { title = "isovim" })
  end
end

function M.poll_prs()
  for _, ws in ipairs(store.list()) do
    local branch = store.branch(ws.id)
    if branch and ws.dir ~= store.path(ws.id) then
      prs.discover(ws.id, ws.dir, branch, refresh_sidebar)
    end
    if #store.prs(ws.id) > 0 then
      prs.list(ws.id, refresh_sidebar)
    end
  end
end

-- iso find as a live picker, like <leader>/: each keystroke searches every host; the preview
-- shows the agent's transcript at the match, or where else the query turned up. iso find prints one JSON array; jq makes it a row per agent.
function M.find()
  local self = remote.self()
  Snacks.picker.pick({
    source = "isovim_find",
    title = "Find agents",
    -- Chat lines are long; the preview wraps them so the match's sentence reads whole.
    win = { preview = { wo = { wrap = true, linebreak = true } } },
    live = true,
    supports_live = true,
    finder = function(opts, ctx)
      if ctx.filter.search == "" then
        return function() end
      end
      return require("snacks.picker.source.proc").proc(
        ctx:opts({
          cmd = "sh",
          args = { "-c", '"$0" find --json "$1" | jq -c ".[]"', panes.bin, ctx.filter.search },
          notify = false,
          transform = function(item)
            local ok, row = pcall(vim.json.decode, item.text)
            if not ok or type(row) ~= "table" then
              return false
            end
            item.row = row
            item.text = ("%s %s %s"):format(row.workspace, row.agent, row.match or "")
            -- A local transcript previews at the match, highlighted; anything else shows the hit.
            if row.file and row.host == self then
              item.file, item.pos = row.file, { row.line, row.col - 1 }
            end
            item.preview = {
              ft = "markdown",
              text = ("# %s · %s\n\n%s, found in its %s\n\n> %s\n"):format(
                row.workspace,
                row.agent,
                row.host == self and "here" or ("on " .. row.host),
                row.where,
                (row.match or row.workspace):gsub("\n", " ")
              ),
            }
          end,
        }),
        ctx
      )
    end,
    format = function(item)
      local row = item.row
      local icon, hl = icons.get(row.kind)
      local line = { { icon, hl }, { " " } }
      if row.host ~= self then
        line[#line + 1] = { row.host .. ": ", "Comment" }
      end
      vim.list_extend(line, { { row.workspace .. " · " .. row.agent }, { "  " .. row.where, "Comment" } })
      return line
    end,
    preview = function(ctx)
      if ctx.item.file then
        return Snacks.picker.preview.file(ctx)
      end
      return Snacks.picker.preview.preview(ctx)
    end,
    confirm = function(picker, item)
      picker:close()
      local row = item and item.row
      if not row then
        return
      end
      local id = row.id:gsub("^[^:]+:", "")
      if row.host == self then
        local ws, agent = id:match("^([^/]+)/(.+)$")
        M.open(ws, agent)
      else
        M.open_remote(row.host, remote.host_of(row.host), id, row.host .. ":" .. row.workspace, row.agent)
      end
    end,
  })
end

-- http://localhost:<port> for what an agent (or any of the workspace's) listens on; with several,
-- pick one.
function M.open_port(ws, agent)
  if not ws then
    return Snacks.notify.warn("No workspace selected")
  end
  local ports = require("isovim.ports").of(ws, agent)
  local function open(port)
    if port then
      vim.ui.open("http://localhost:" .. port)
    end
  end
  if #ports == 0 then
    Snacks.notify.warn(("Nothing in %s listens on a port"):format(store.name(ws)))
  elseif #ports == 1 then
    open(ports[1])
  else
    vim.ui.select(ports, { prompt = "Open port", format_item = function(port)
      return "localhost:" .. port
    end }, open)
  end
end

-- In a worktree workspace the agents commit as they go, so a file's git signs compare it with where
-- the branch left the default branch: everything the workspace changed.
-- Set after gitsigns' first update of the buffer, which would otherwise put its own base back.
function M.review_base(buf)
  local ws = M.current
  if not ws or not store.branch(ws) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local dir = store.dir(ws)
  if not vim.startswith(vim.api.nvim_buf_get_name(buf), dir .. "/") then
    return
  end
  local base = vim.system({ "git", "-C", dir, "merge-base", "HEAD", "refs/remotes/origin/HEAD" }, { text = true }):wait()
  if base.code ~= 0 then
    return
  end
  vim.api.nvim_create_autocmd("User", {
    pattern = "GitSignsUpdate",
    callback = function(ev)
      if ev.data and ev.data.buffer == buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_call(buf, function()
          require("gitsigns").change_base(vim.trim(base.stdout))
        end)
        return true
      end
    end,
  })
end

-- What changes with no hook to say so: titles and terminals' commands, the ports they serve on,
-- and the current workspace's +/- after a commit made in a terminal. The sidebar redraws when any does.
local last_titles, ticks = nil, 0
function M.poll()
  ticks = ticks + 1
  local now = vim.json.encode(panes.titles())
  if now ~= last_titles then
    last_titles = now
    M.refresh_titles()
  end
  -- lsof is the costly part, and a dev server's port can show a few seconds late.
  if ticks % 3 == 1 then
    require("isovim.ports").poll(M.refresh_titles)
  end
  -- Only the workspace you're in: a git diff per workspace every few seconds adds up. The others
  -- catch up when their agents next report.
  if M.current then
    diffstat.get(store.dir(M.current), M.refresh_titles)
  end
end

function M.refresh_titles()
  refresh_sidebar()
end

-- How a layout.json leaf comes back in its window: the agent's chat, or the file.
function M.open_leaf(ws)
  return function(win, leaf)
    if leaf.agent and store.agent(ws, leaf.agent) then
      M.open(ws, leaf.agent, win)
    elseif leaf.file and vim.fn.filereadable(leaf.file) == 1 then
      vim.api.nvim_win_call(win, function()
        vim.cmd.edit(vim.fn.fnameescape(leaf.file))
      end)
    end
  end
end

-- A fresh start picks up where the last one left off: the selected workspace's splits, chats and
-- files, or at least its chat if its agent is still running.
function M.resume()
  local ws = M.current
  if not ws then
    return
  end
  local resumed = layout.resume(ws, is_sidebar, M.open_leaf(ws))
  if not resumed and panes.running(ws, default_agent(ws)) then
    M.open(ws)
  end
end

return M
