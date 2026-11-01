-- The sidebar: a column of windows (the Inbox, one host's workspaces and agents, a footer) under its
-- title in the tab line, and the file explorer that can take its place.
-- init.lua requires this module only from inside functions, so requiring it back makes no cycle.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local prs = require("isovim.prs")
local icons = require("isovim.icons")
local diffstat = require("isovim.diffstat")
local remote = require("isovim.remote")
local repos = require("isovim.repos")
local isovim = require("isovim")

local M = {}

M.queue = {} ---@type {ws: string, ws_name: string, agent: string, name: string, status: isovim.Status}[]

-- Only what waits on you: a raised decision or a question. A finished turn (the green dot) doesn't.
function M.needs_you(agent)
  return not agent.hidden and agent.status == "attention"
end

-- A path as the sidebar names it: relative to the workspace's project dir when inside it.
local function short_path(ws, path)
  local dir = store.dir(ws)
  if dir and vim.startswith(path, dir .. "/") then
    return path:sub(#dir + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- What each kind of row does: how it's drawn, what Enter opens and d removes (nil: nothing), and
-- the fields that keep the cursor on it through refreshes. Another host's rows carry `host`.
local TASK_GLYPHS = {
  todo = { "○", "Comment" },
  doing = { "◐", "DiagnosticInfo" },
  waiting = { "\u{f051f}", "Comment" }, -- md-timer_sand
  blocked = { "⊘", "DiagnosticWarn" },
  done = { "✓", "DiagnosticOk" },
}

local KINDS = {
  hint = {
    format = function(item)
      return { { "  " .. item.text, "Comment" } }
    end,
    id = {},
  },
  workspace = {
    format = function(item)
      local folder, folder_hl = icons.get(item.ws == isovim.current and "workspace_current" or "workspace")
      if item.repo then
        folder, folder_hl = item.repo.glyph, item.repo.hl
      end
      local chevron = isovim.expanded[item.ws] and "▾ " or "▸ "
      local row = { { chevron, "Comment" }, { folder, folder_hl }, { " " }, { item.ws_name, item.running and "Directory" or "Comment" } }
      if item.added and item.added + item.removed > 0 then
        vim.list_extend(row, { { " +" .. item.added, "Added" }, { " −" .. item.removed, "Removed" } })
      end
      -- Collapsed, it still shows what its most urgent agent is up to.
      if not isovim.expanded[item.ws] and item.status then
        local icon, hl = status.icon(item.status)
        vim.list_extend(row, { { " " }, { icon, hl } })
      end
      return row
    end,
    open = function(item)
      if not item.host then
        isovim.open(item.ws)
      end
    end,
    delete = function(item)
      Snacks.picker.util.confirm("Archive " .. item.ws_name .. "?", function()
        panes.stop_all(item.ws)
        store.reparent(item.ws)
        local ok, err, note = store.archive_workspace(item.ws)
        if not ok then
          Snacks.notify.error("Could not archive " .. item.ws_name .. ":\n" .. err)
        elseif note then
          Snacks.notify.warn(item.ws_name .. " archived; " .. note, { title = "isovim" })
        end
        isovim.refresh()
      end)
    end,
    id = { "ws" },
  },
  -- An agent's task, under its row: subtasks one level further in; done ones dimmed. Enter opens the
  -- agent; the agent owns its tasks, so d leaves them alone.
  task = {
    format = function(item)
      local glyph, hl = unpack(TASK_GLYPHS[item.task.status] or TASK_GLYPHS.todo)
      local done = item.task.status == "done"
      local row = { { ("    " .. ("  "):rep(item.depth)) }, { glyph, hl }, { " " }, { item.task.title, done and "Comment" or nil } }
      for _, pr in ipairs(item.task.prs or {}) do
        row[#row + 1] = { " #" .. pr, "Comment" }
      end
      if item.task.detail and not done then
        row[#row + 1] = { "  " .. item.task.detail, "Comment" }
      end
      return row
    end,
    id = { "ws", "agent", "task_id" },
  },
  -- Indented under their workspace with a status icon. Anything not running is dimmed; hidden
  -- agents are italic.
  agent = {
    format = function(item)
      local icon, hl = status.icon(item.status)
      local kind_icon, kind_hl = icons.get(item.agent_kind)
      local name_hl = item.hidden and "Comment" or (not item.running and "Comment" or nil)
      local row = { { "  " }, { icon, hl }, { " " }, { kind_icon, kind_hl }, { " " }, { item.name, name_hl } }
      if item.hidden then
        row[#row + 1] = { " (hidden)", "Comment" }
      end
      if not item.host and require("isovim.root").is_root(require("isovim.root").address(item.ws, item.agent)) then
        row[#row + 1] = { " root", "Special" }
      end
      -- What it's on: the task title Claude gives its terminal, or the command a terminal runs.
      -- The ports it serves on first: the subtitle is often long enough to be cut off.
      if isovim.show_ports and item.ports and #item.ports > 0 then
        row[#row + 1] = { "  :" .. table.concat(item.ports, " :"), "Special" }
      end
      if item.subtitle and item.subtitle ~= item.name then
        row[#row + 1] = { "  " .. item.subtitle, "Comment" }
      end
      return row
    end,
    open = function(item)
      if item.host then
        isovim.open_remote(item.host, item.ssh, item.agent, item.ws_name, item.name)
      else
        isovim.open(item.ws, item.agent)
      end
    end,
    delete = function(item)
      Snacks.picker.util.confirm(("Remove %s from %s?"):format(item.name, item.ws_name), function()
        isovim.remove_agent(item.ws, item.agent)
      end)
    end,
    id = { "ws", "agent" },
  },
  path = {
    format = function(item)
      local icon, hl = "\u{f07b}", "Directory"
      if not item.is_dir then
        local ok, mini = pcall(require, "mini.icons")
        icon, hl = "\u{f15b}", "Comment"
        if ok then
          icon, hl = mini.get("file", item.path)
        end
      end
      return { { "  " }, { " " }, { " " }, { icon, hl }, { " " }, { item.label, item.is_dir and "Directory" or nil } }
    end,
    open = function(item)
      isovim.reveal(item.ws, item.path)
    end,
    delete = function(item)
      store.unpin(item.ws, item.path)
      M.refresh()
    end,
    id = { "ws", "path" },
  },
  pr = {
    format = function(item)
      local icon, hl = prs.icon(item.pr)
      local label = item.pr.number and ("#%d %s"):format(item.pr.number, item.pr.title) or item.pr.url
      -- The CI mark before the title, which the sidebar's width often cuts.
      local row = vim.list_extend({ { "  " }, { icon, hl } }, prs.marks(item.pr))
      return vim.list_extend(row, { { " " }, { label, item.pr.state ~= "OPEN" and "Comment" or nil } })
    end,
    open = function(item)
      vim.ui.open(item.pr.url)
    end,
    id = { "ws", "url" },
  },
  empty = {
    format = function()
      return { { "    no PRs yet", "Comment" } }
    end,
    id = { "ws" },
  },
}
KINDS.task.open = KINDS.agent.open

local URGENCY = { attention = 1, unread = 2, working = 3, waiting = 4 }

-- The status a collapsed workspace shows for its agents: the one that most wants you.
local function most_urgent(agents)
  local found
  for _, agent in ipairs(agents) do
    if URGENCY[agent.status] and (not found or URGENCY[agent.status] < URGENCY[found]) then
      found = agent.status
    end
  end
  return found
end

-- An agent's tasks, in tree order: each one's subtasks right under it.
local function add_tasks(items, base, agent)
  if not isovim.show_tasks then
    return
  end
  local tasks = agent.tasks or {}
  local function under(parent, depth)
    for _, task in ipairs(tasks) do
      if task.parent == parent then
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "task",
          agent = agent.id,
          name = agent.name,
          task = task,
          task_id = task.id,
          depth = depth,
        })
        under(task.id, depth + 1)
      end
    end
  end
  under(nil, 0)
end

-- How a workspace row draws its repo, from repos.style here or from another host's `iso ls`; hosts
-- from before repos send none, and their rows keep the folder.
local function repo_mark(style)
  local hl = type(style) == "table" and type(style.glyph) == "string" and repos.highlight(style.color)
  return hl and { glyph = style.glyph, hl = hl } or nil
end

-- This host's rows: each workspace with its agents, or its PRs while P is on; a collapsed workspace
-- (the default) only its own row.
local function local_rows(workspaces)
  local titles = panes.titles()
  local items = {}
  for _, ws in ipairs(workspaces) do
    local base = { ws = ws.id, ws_name = ws.name }
    local added, removed = diffstat.get(ws.dir, M.refresh)
    local row = { kind = "workspace", running = ws.running, added = added, removed = removed, status = most_urgent(ws.agents), repo = repo_mark(repos.for_dir(ws.dir)) }
    items[#items + 1] = vim.tbl_extend("force", base, row)
    local open = isovim.expanded[ws.id]
    if open and isovim.show_prs then
      local list = prs.list(ws.id, M.refresh)
      for _, pr in ipairs(list) do
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "pr", pr = pr, url = pr.url })
      end
      if #list == 0 then
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "empty" })
      end
    elseif open then
      for _, agent in ipairs(ws.agents) do
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "agent",
          agent = agent.id,
          name = agent.name,
          agent_kind = agent.kind,
          status = agent.status,
          running = agent.running,
          hidden = agent.hidden,
          subtitle = agent.running and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id]) or nil,
          ports = agent.running and require("isovim.ports").of(ws.id, agent.id) or nil,
        })
        add_tasks(items, base, agent)
      end
      for _, entry in ipairs(store.pinned(ws.id)) do
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "path",
          path = entry.path,
          label = entry.label or short_path(ws.id, entry.path),
          is_dir = vim.fn.isdirectory(entry.path) == 1,
        })
      end
    end
  end
  if #workspaces == 0 then
    items[1] = { kind = "hint", text = "no workspaces · a new · ? keys" }
  end
  return items
end

-- Another host's agent, from its row in that host's `iso ls`.
local function remote_agent(row)
  local state = row.status ~= "idle" and row.status ~= "stopped" and row.status or nil
  return { id = row.id, name = row.agent, kind = row.kind, status = state, running = row.status ~= "stopped", hidden = row.hidden, doing = row.doing, tasks = row.tasks }
end

-- Another host's rows, by workspace, as its `iso ls` lists them.
local function remote_rows(name, ssh, rows)
  local items = {}
  local by_ws, order = {}, {}
  for _, row in ipairs(rows) do
    local ws_id = row.id:match("^[^/]+")
    local agent = remote_agent(row)
    if not by_ws[ws_id] then
      by_ws[ws_id] = { name = row.workspace, agents = {}, repo = row.repo }
      order[#order + 1] = ws_id
    end
    if not agent.hidden or isovim.show_hidden then
      table.insert(by_ws[ws_id].agents, agent)
      by_ws[ws_id].running = by_ws[ws_id].running or agent.running
    end
  end
  for _, ws_id in ipairs(order) do
    local ws = by_ws[ws_id]
    local base = { host = name, ssh = ssh, ws = name .. ":" .. ws_id, ws_name = ws.name, remote_ws = ws_id }
    items[#items + 1] = vim.tbl_extend("force", base, { kind = "workspace", running = ws.running, status = most_urgent(ws.agents), repo = repo_mark(ws.repo) })
    for _, agent in ipairs(isovim.expanded[base.ws] and ws.agents or {}) do
      items[#items + 1] = vim.tbl_extend("force", base, {
        kind = "agent",
        agent = agent.id,
        name = agent.name,
        agent_kind = agent.kind,
        status = agent.status,
        running = agent.running,
        hidden = agent.hidden,
        subtitle = agent.doing,
      })
      add_tasks(items, base, agent)
    end
  end
  if #order == 0 then
    items[1] = { kind = "hint", text = "no agents" }
  end
  return items
end

-- The hosts the list can show: this one first, then the others by name.
local function hosts()
  local names = vim.tbl_keys(remote.peers())
  table.sort(names)
  return vim.list_extend({ remote.self() }, names)
end

-- The other host the list shows, or nil for this one. In vim.g, so a hot reload keeps it.
local function shown_host()
  local name = vim.g.isovim_sidebar_host
  return name and remote.peers()[name] and name or nil
end

-- Every host's agents waiting on you go to M.queue, the Inbox, this host's first; the rows returned
-- are the shown host's. Hidden agents show only while show_hidden is on.
local function collect()
  isovim.mark_visible_seen()
  local sessions = panes.sessions()
  local workspaces = store.list()
  local shown = shown_host()
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
      if not agent.hidden or isovim.show_hidden then
        ws.agents[#ws.agents + 1] = agent
        ws.running = ws.running or agent.running
        working = working or (not shown and agent.status == "working")
      end
      if M.needs_you(agent) then
        queue[#queue + 1] =
          { ws = ws.id, ws_name = ws.name, agent = agent.id, name = agent.name, kind = agent.kind, status = agent.status }
      end
    end
  end
  local items
  local peers = remote.peers()
  for _, name in ipairs(vim.list_slice(hosts(), 2)) do
    local ssh = peers[name]
    local rows = remote.list(name, ssh, M.refresh)
    if rows then
      isovim.notify_remote(name, rows)
    end
    for _, row in ipairs(rows or {}) do
      local agent = remote_agent(row)
      if M.needs_you(agent) then
        queue[#queue + 1] = { host = name, ssh = ssh, agent = row.id, ws_name = name .. ":" .. row.workspace, name = row.agent, kind = row.kind, status = agent.status }
      end
      working = working or (name == shown and agent.status == "working")
    end
    if name == shown then
      if remote.down(name) then
        items = { { kind = "hint", text = "unreachable" } }
      else
        items = rows and remote_rows(name, ssh, rows) or { { kind = "hint", text = "asking…" } }
      end
    end
  end

  status.animate(working)
  table.sort(workspaces, function(a, b)
    return a[isovim.sort] > b[isovim.sort]
  end)
  M.queue = queue
  return items or local_rows(workspaces)
end

-- The column's windows by role (inbox, list, footer), found by their buffers' b:isovim_sidebar.
local function windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local role = vim.b[vim.api.nvim_win_get_buf(win)].isovim_sidebar
    if role then
      wins[role] = win
    end
  end
  return wins
end

local ns = vim.api.nvim_create_namespace("isovim_sidebar")

-- Each line is a list of {text, highlight} chunks. Cursors stay on their line numbers.
local function draw(win, chunk_lines)
  local buf = vim.api.nvim_win_get_buf(win)
  local lines, marks = {}, {}
  for i, chunks in ipairs(chunk_lines) do
    local text, col = {}, 0
    for _, chunk in ipairs(chunks) do
      text[#text + 1] = chunk[1]
      if chunk[2] then
        marks[#marks + 1] = { i - 1, col, col + #chunk[1], chunk[2] }
      end
      col = col + #chunk[1]
    end
    lines[i] = table.concat(text)
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(cursor[1], #lines)), 0 })
end

local function set_height(win, height)
  if vim.api.nvim_win_get_height(win) ~= height then
    vim.api.nvim_win_set_height(win, height)
  end
end

-- What each window's lines stand for, line by line: the actions take the one under the cursor.
local rows = { list = {}, inbox = {}, footer = {} }

-- H, P, L and T show in the title as badges while they're on.
local TOGGLES = { { "show_hidden", "H" }, { "show_prs", "P" }, { "show_ports", "L" }, { "show_tasks", "T" } }

-- The column's title sits in the tab line, over the column (bufferline's offset for the sidebar's
-- filetype), so the column runs the screen's full height. width: the cells it has.
function M.title(width)
  local badges = ""
  for _, toggle in ipairs(TOGGLES) do
    if isovim[toggle[1]] then
      badges = badges .. " " .. toggle[2]
    end
  end
  return "ISOVIM" .. (" "):rep(width - 6 - #badges) .. badges
end

-- The Inbox: what waits on you on every host, under a title with the count. Collapsed, only the title.
local function inbox_lines()
  local count = #M.queue
  local lines = {
    { { isovim.inbox_collapsed and "▸ " or "▾ ", "Comment" }, { "Inbox", "Title" }, { " " .. count, count > 0 and "DiagnosticWarn" or "Comment" } },
  }
  rows.inbox = { { kind = "inbox" } }
  for _, entry in ipairs(isovim.inbox_collapsed and {} or M.queue) do
    local icon, hl = status.icon(entry.status)
    local kind_icon, kind_hl = icons.get(entry.kind)
    lines[#lines + 1] = { { "  " }, { icon, hl }, { " " }, { kind_icon, kind_hl }, { (" %s · %s"):format(entry.ws_name, entry.name) } }
    rows.inbox[#rows.inbox + 1] = entry
  end
  return lines
end

-- The shown host's name, with ‹ › when < and > have others to show.
local function host_bar()
  local name = shown_host() or remote.self()
  local bar = "%#Title# " .. icons.get("host") .. " " .. name:gsub("%%", "%%%%")
  if #hosts() > 1 then
    bar = "%#Comment# ‹" .. bar .. "%#Comment# ›"
  end
  return bar
end

local usage = {} ---@type table<string, {cpu: number, used: number, total: number, at: integer}|"busy"|false>
local version

-- How long ago, in its largest unit: "now", "5m", "2h", "3d".
local function age(at)
  local seconds = os.time() - at
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function footer_lines()
  local host = shown_host() or remote.self()
  local measured = usage[host]
  local first = { { "  cpu, ram: press u", "Comment" } }
  if measured == "busy" then
    first = { { "  measuring " .. host .. "…", "Comment" } }
  elseif measured == false then
    first = { { "  couldn't measure " .. host, "DiagnosticWarn" } }
  elseif measured then
    first = {
      { "  cpu " },
      { ("%d%%"):format(measured.cpu), measured.cpu >= 80 and "DiagnosticWarn" or "Special" },
      { "  ram " },
      { ("%.1f/%.0fG"):format(measured.used / 2 ^ 30, measured.total / 2 ^ 30), measured.used / measured.total >= 0.9 and "DiagnosticWarn" or "Special" },
      -- The short name, so the age fits: Mac.localdomain is Mac.
      { "  " .. host:match("^[^.]+") .. " " .. age(measured.at), "Comment" },
    }
  end
  rows.footer = { { kind = "usage" }, { kind = "settings" }, { kind = "about" } }
  return {
    first,
    { { "  " }, { "\u{f013}", "Special" }, { " Settings" } }, -- fa-cog
    { { ("  isovim %s · agents first, in nvim"):format(version or ""), "Comment" } },
  }
end

local shown_title

local function render(wins)
  -- A title window from before the title moved to the tab line.
  if wins.title then
    pcall(vim.api.nvim_win_close, wins.title, true)
  end
  local title = wins.list and M.title(vim.api.nvim_win_get_width(wins.list) - 2)
  if title ~= shown_title then
    shown_title = title
    vim.cmd.redrawtabline()
  end
  if wins.inbox then
    local lines = inbox_lines()
    draw(wins.inbox, lines)
    set_height(wins.inbox, math.min(#lines, 11))
  end
  if wins.list then
    draw(wins.list, vim.tbl_map(function(item)
      return KINDS[item.kind].format(item)
    end, rows.list))
    vim.wo[wins.list].winbar = host_bar()
  end
  if wins.footer then
    draw(wins.footer, footer_lines())
    set_height(wins.footer, 3)
  end
end

local function line_of(list, item, fields)
  for i, row in ipairs(list) do
    local same = row.kind == item.kind
    for _, field in ipairs(fields or KINDS[item.kind].id) do
      same = same and row[field] == item[field]
    end
    if same then
      return i
    end
  end
end

-- The list's cursor sits on what you're looking at: the agent in the focused window, or else the
-- current workspace. Left alone while you're moving around the sidebar yourself, or looking at
-- another host.
function M.follow()
  local list = windows().list
  if not list or shown_host() or isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    return
  end
  local shown = vim.api.nvim_get_current_buf()
  local agent = vim.b[shown].isovim_id == isovim.current and vim.b[shown].isovim_agent
  local target = agent and line_of(rows.list, { kind = "agent", ws = isovim.current, agent = agent })
    or line_of(rows.list, { kind = "workspace", ws = isovim.current })
  if target then
    vim.api.nvim_win_set_cursor(list, { target, 0 })
  end
end

-- Set by an action that wants the cursor on another row once the list redraws.
local keep

-- Rows can shift (activity sort, the Inbox, subtitles), so a cursor keeps its row's item, not its
-- line number.
local function refresh_now()
  local wins = windows()
  if not wins.list then
    return
  end
  local before = keep or rows.list[vim.api.nvim_win_get_cursor(wins.list)[1]]
  local queued = wins.inbox and rows.inbox[vim.api.nvim_win_get_cursor(wins.inbox)[1]]
  keep = nil
  rows.list = collect()
  render(wins)
  local inbox_line = queued and line_of(rows.inbox, queued, { "host", "ws", "agent" })
  if inbox_line then
    vim.api.nvim_win_set_cursor(wins.inbox, { inbox_line, 0 })
  end
  if not isovim.is_sidebar(vim.api.nvim_get_current_win()) or not before then
    return M.follow()
  end
  local line = line_of(rows.list, before)
  if line then
    vim.api.nvim_win_set_cursor(wins.list, { line, 0 })
  end
end

-- Bursts of refreshes (the poll, hooks, PR updates) run once.
local pending = false
function M.refresh()
  if pending or not windows().list then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    refresh_now()
  end, 30)
end

-- Redraws without rebuilding the rows, for the spinners. False when the column isn't open.
function M.redraw()
  local wins = windows()
  if wins.list then
    render(wins)
  end
  return wins.list ~= nil
end

-- CPU (percent busy over a second) and RAM in use and in all (bytes), on macOS or Linux.
local USAGE = [[
if [ "$(uname)" = Darwin ]; then
  cpu=$(top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { u = $3 + $5 } END { print u }')
  page=$(sysctl -n hw.pagesize)
  used=$(vm_stat | awk -v page="$page" '/Pages active|Pages wired|occupied by compressor/ { gsub(/\./, "", $NF); n += $NF } END { printf "%.0f", n * page }')
  total=$(sysctl -n hw.memsize)
else
  read -r _ a b c d e f g h _ < /proc/stat
  busy=$((a + b + c + f + g + h)) all=$((a + b + c + d + e + f + g + h))
  sleep 1
  read -r _ a b c d e f g h _ < /proc/stat
  cpu=$((100 * (a + b + c + f + g + h - busy) / (a + b + c + d + e + f + g + h - all)))
  used=$(awk '/^MemTotal/ { t = $2 } /^MemAvailable/ { a = $2 } END { printf "%.0f", (t - a) * 1024 }' /proc/meminfo)
  total=$(awk '/^MemTotal/ { printf "%.0f", $2 * 1024 }' /proc/meminfo)
fi
echo "$cpu $used $total"
]]

-- Only when asked (u): another host's is measured over ssh.
local function measure()
  local host = shown_host()
  local name = host or remote.self()
  if usage[name] == "busy" then
    return
  end
  local cmd = { "sh", "-c", USAGE }
  if host then
    local remote_cmd = vim.fn.shellescape("sh -c " .. vim.fn.shellescape(USAGE))
    cmd = { "bash", "-c", ("%s %s %s"):format(remote.ssh, vim.fn.shellescape(remote.peers()[host]), remote_cmd) }
  end
  usage[name] = "busy"
  M.redraw()
  vim.system(cmd, { text = true, timeout = 15000 }, vim.schedule_wrap(function(result)
    local cpu, used, total = (result.stdout or ""):match("([%d.]+) (%d+) (%d+)")
    usage[name] = cpu and { cpu = tonumber(cpu), used = tonumber(used), total = tonumber(total), at = os.time() } or false
    M.redraw()
  end))
end

local function add_agent(ws, spec)
  local agent = store.add_agent(ws, spec)
  isovim.open(ws, agent.id)
  isovim.refresh()
end

-- {key, action, description}: each window's keys, which `?` lists. COLUMN_KEYS work in all of them.
local COLUMN_KEYS = {
  { "<c-j>", "isovim_window_down", "to the window below" },
  { "<c-k>", "isovim_window_up", "to the window above" },
  { "<c-l>", "isovim_focus_chat", "to the chat" },
  { "<", "isovim_prev_host", "the host list shows the previous host" },
  { ">", "isovim_next_host", "the host list shows the next host" },
  { "u", "isovim_usage", "measure the shown host's CPU and RAM (in the footer)" },
  { "?", "isovim_help", "this help" },
}
local LIST_KEYS = {
  { "<cr>", "isovim_open", "open the agent or PR; a pinned file beside the chat, a folder in the explorer" },
  { "<Tab>", "isovim_toggle_expand", "expand or collapse the workspace" },
  { "a", "isovim_add", "new workspace" },
  { "A", "isovim_add_agent", "new agent in this workspace" },
  { "t", "isovim_terminal", "new terminal in this workspace" },
  { "r", "isovim_rename", "rename the workspace or agent" },
  { "d", "isovim_delete", "remove the agent or pinned path, or archive the workspace" },
  { "c", "isovim_changes", "its changes since its base; on a PR, its Files changed tab" },
  { "o", "isovim_open_port", "open its dev server (the port it listens on) in the browser; on a PR, the PR" },
  { "y", "isovim_yank_url", "copy the PR's URL" },
  { "f", "isovim_find", "find the agent that was on something, on any host (iso find)" },
  { "R", "isovim_restart", "restart the agent (it resumes)" },
  { "m", "isovim_move", "move it to another host, or here" },
  { "s", "isovim_sort", "sort by creation or by recent activity" },
  { "H", "isovim_toggle_hidden", "show or hide hidden agents" },
  { "L", "isovim_toggle_ports", "show or hide the ports agents listen on" },
  { "T", "isovim_toggle_tasks", "show or hide agents' tasks" },
  { "P", "isovim_toggle_prs", "agents or PRs" },
  { "b", "isovim_last_workspace", "back to the last workspace" },
  { "E", "isovim_explorer", "file explorer (W comes back)" },
}
local INBOX_KEYS = {
  { "<cr>", "isovim_open_queued", "open that agent; on the title, collapse or expand the Inbox" },
  { "<Tab>", "isovim_toggle_inbox", "collapse or expand the Inbox" },
}
local FOOTER_KEYS = {
  { "<cr>", "isovim_open_footer", "on Settings, open ~/.isovim/config.json beside the chat; on cpu, ram, measure them" },
}
local ROLE_KEYS = { list = LIST_KEYS, inbox = INBOX_KEYS, footer = FOOTER_KEYS }

local function map_keys(buf, role)
  for _, key in ipairs(vim.list_extend(vim.list_extend({}, COLUMN_KEYS), ROLE_KEYS[role] or {})) do
    vim.keymap.set("n", key[1], function()
      M.actions[key[2]]((rows[role] or {})[vim.api.nvim_win_get_cursor(0)[1]])
    end, { buffer = buf, nowait = true, desc = "isovim: " .. key[3] })
  end
end

-- A float listing every isovim key, built from the tables above, the chats' and the live <leader> maps.
function M.help()
  local lines = {}
  local function section(title, keys)
    lines[#lines + 1] = "# " .. title
    for _, key in ipairs(keys) do
      lines[#lines + 1] = ("  %-12s %s"):format(key[1], key[#key])
    end
    lines[#lines + 1] = ""
  end
  section("Sidebar (any of its windows)", COLUMN_KEYS)
  section("Host list", LIST_KEYS)
  section("Inbox", INBOX_KEYS)
  section("Footer", FOOTER_KEYS)
  section("Chat (terminal mode)", isovim.chat_keys)
  section("Chat (normal mode)", isovim.chat_normal_keys)
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
    height = math.min(#lines, vim.o.lines - 4),
    wo = { wrap = false, conceallevel = 2 },
    keys = { q = "close", ["?"] = "close" },
  })
end

local function toggle(option)
  return function()
    isovim.remember(option, not isovim[option])
    M.refresh()
  end
end

-- C-j and C-k step through the Inbox, the list and the footer; the title is no stop.
local STOPS = { "inbox", "list", "footer" }
local function step_window(by)
  local at = 0
  for i, role in ipairs(STOPS) do
    if role == vim.b.isovim_sidebar then
      at = i
    end
  end
  local target = STOPS[at + by] and windows()[STOPS[at + by]]
  if target then
    vim.api.nvim_set_current_win(target)
  end
end

local function step_host(by)
  local all = hosts()
  local at = 1
  for i, name in ipairs(all) do
    if name == (shown_host() or remote.self()) then
      at = i
    end
  end
  local name = all[(at - 1 + by) % #all + 1]
  vim.g.isovim_sidebar_host = name ~= remote.self() and name or nil
  if shown_host() then
    remote.invalidate(name)
  end
  vim.api.nvim_win_set_cursor(windows().list, { 1, 0 })
  refresh_now()
end

M.actions = {
  isovim_open = function(item)
    return item and KINDS[item.kind].open and KINDS[item.kind].open(item)
  end,
  isovim_open_queued = function(entry)
    if entry and entry.kind == "inbox" then
      return M.actions.isovim_toggle_inbox()
    end
    return entry and KINDS.agent.open(entry)
  end,
  isovim_toggle_inbox = function()
    isovim.remember("inbox_collapsed", not isovim.inbox_collapsed)
    refresh_now()
  end,
  isovim_open_footer = function(row)
    if row and row.kind == "settings" then
      isovim.open_beside(isovim.main_win(), require("isovim.config").path)
    elseif row and row.kind == "usage" then
      measure()
    end
  end,
  isovim_usage = measure,
  isovim_window_down = function()
    step_window(1)
  end,
  isovim_window_up = function()
    step_window(-1)
  end,
  isovim_next_host = function()
    step_host(1)
  end,
  isovim_prev_host = function()
    step_host(-1)
  end,
  isovim_toggle_prs = toggle("show_prs"),
  isovim_add = function()
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
          isovim.open(id)
          isovim.refresh()
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
  isovim_add_agent = function(item)
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
    isovim.find()
  end,
  isovim_open_port = function(item)
    if item and item.kind == "pr" then
      vim.ui.open(item.pr.url)
    elseif item and item.ws and not item.host then
      isovim.open_port(item.ws, item.agent)
    end
  end,
  isovim_changes = function(item)
    if item and item.kind == "pr" then
      vim.ui.open(item.pr.url .. "/files")
    elseif item and item.ws and not item.host then
      isovim.changes(item.ws)
    end
  end,
  isovim_yank_url = function(item)
    if item and item.kind == "pr" then
      vim.fn.setreg("+", item.pr.url)
      vim.notify("Copied " .. item.pr.url)
    end
  end,
  isovim_restart = function(item)
    if item and item.agent and not item.host then
      Snacks.picker.util.confirm(("Restart %s?"):format(item.name), function()
        isovim.restart(item.ws, item.agent)
        isovim.refresh()
      end)
    end
  end,
  -- t opens a new terminal in the workspace under the cursor; it outlives the TUI like the agents.
  isovim_terminal = function(item)
    local ws = item and item.ws or isovim.current
    if ws then
      add_agent(ws, { kind = "terminal" })
    end
  end,
  isovim_rename = function(item)
    if not item or not item.ws then
      return
    end
    -- On an agent row it renames the agent, e.g. a terminal after what runs in it.
    if item.agent then
      return vim.ui.input({ prompt = "Rename agent: ", default = item.name }, function(name)
        if name and name ~= "" then
          store.update_agent(item.ws, item.agent, { name = name })
          isovim.refresh()
        end
      end)
    end
    vim.ui.input({ prompt = "Rename workspace: ", default = item.ws_name }, function(name)
      if name and name ~= "" then
        store.rename(item.ws, name)
        isovim.refresh()
      end
    end)
  end,
  isovim_delete = function(item)
    return item and KINDS[item.kind].delete and KINDS[item.kind].delete(item)
  end,
  -- m moves the workspace to another host; its agents resume there (iso move).
  isovim_move = function(item)
    if not item or not item.ws then
      return
    elseif item.host then
      return isovim.move_here(item)
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
          isovim.toast(("%s moved to %s"):format(name, host))
          isovim.refresh()
        end))
      end
      move(false)
    end)
  end,
  -- From an agent or pin row it collapses that row's workspace, and the cursor goes up to it.
  isovim_toggle_expand = function(item)
    if not item or not item.ws then
      return
    end
    isovim.expanded[item.ws] = not isovim.expanded[item.ws] or nil
    isovim.remember("expanded", isovim.expanded)
    keep = { kind = "workspace", ws = item.ws }
    refresh_now()
  end,
  isovim_toggle_hidden = toggle("show_hidden"),
  isovim_toggle_ports = toggle("show_ports"),
  isovim_toggle_tasks = toggle("show_tasks"),
  isovim_explorer = function()
    M.show_explorer()
  end,
  isovim_focus_chat = function()
    vim.api.nvim_set_current_win(isovim.main_win())
  end,
  isovim_last_workspace = function()
    isovim.last_workspace()
  end,
  isovim_help = function()
    M.help()
  end,
  isovim_sort = function()
    isovim.remember("sort", isovim.sort == "created" and "active" or "created")
    Snacks.notify.info("Sorted by " .. (isovim.sort == "created" and "creation time" or "recent activity"))
    M.refresh()
  end,
}

-- Another host's rows only open; changing them is that host's business.
for _, name in ipairs({ "isovim_add_agent", "isovim_terminal", "isovim_rename", "isovim_delete" }) do
  local action = M.actions[name]
  M.actions[name] = function(item)
    if item and item.host then
      return Snacks.notify.info(("That's on %s; change it there"):format(item.host), { title = "isovim" })
    end
    return action(item)
  end
end

-- What every window of the column sets: read-only, nothing in the margins, its width and buffer fixed.
local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  statuscolumn = "",
  foldcolumn = "0",
  wrap = false,
  list = false,
  spell = false,
  winbar = "",
  fillchars = "eob: ",
  winfixwidth = true,
  winfixbuf = true,
}

local function column_buffer(role)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "isovim_sidebar"
  vim.b[buf].isovim_sidebar = role
  map_keys(buf, role)
  -- The list's cursor shows what you're on wherever you are; the Inbox's and footer's only in them.
  if role == "inbox" or role == "footer" then
    vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
      buffer = buf,
      callback = function(ev)
        vim.wo.cursorline = ev.event == "WinEnter"
      end,
    })
  end
  return buf
end

-- The column on the left, top to bottom: the Inbox, the host list and the footer, under its title
-- in the tab line. Only the host list changes height with the screen.
---@param opts? {enter?: boolean}
function M.open(opts)
  local wins = windows()
  if not wins.list then
    wins.list = vim.api.nvim_open_win(column_buffer("list"), false, { split = "left", win = -1, width = 40 })
    wins.inbox = vim.api.nvim_open_win(column_buffer("inbox"), false, { split = "above", win = wins.list, height = 1 })
    wins.footer = vim.api.nvim_open_win(column_buffer("footer"), false, { split = "below", win = wins.list, height = 3 })
    for role, win in pairs(wins) do
      for option, value in pairs(WINDOW_OPTIONS) do
        vim.wo[win][option] = value
      end
      vim.wo[win].winfixheight = role ~= "list"
      vim.wo[win].cursorline = role == "list"
    end
  end
  if not version then
    vim.system({ "git", "-C", vim.fs.dirname(panes.bin), "rev-parse", "--short", "HEAD" }, { text = true }, vim.schedule_wrap(function(result)
      version = result.code == 0 and vim.trim(result.stdout) or "?"
      M.redraw()
    end))
  end
  refresh_now()
  if not opts or opts.enter ~= false then
    vim.api.nvim_set_current_win(wins.list)
  end
end

function M.close()
  for _, win in pairs(windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

-- Into the sidebar: the host list, or the explorer in its place.
function M.focus()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  local list = windows().list
  if explorer then
    explorer:focus("list")
  elseif list then
    vim.api.nvim_set_current_win(list)
  end
end

-- The sidebar shows the column (W) or a file explorer rooted at the current workspace (E).
-- Opening is deferred a tick: snacks errors if a picker opens while the closed one is still resizing.
---@param opts? {cwd?: string, reveal?: string, enter?: boolean} reveal: a file to select once it's open
function M.show_explorer(opts)
  opts = opts or {}
  M.view = "explorer"
  M.close()
  local open = Snacks.picker.get({ source = "explorer" })[1]
  if open then
    open:close()
  end
  vim.schedule(function()
    -- Each workspace's explorer reopens where it was left: its root (a jump, <BS>, .) and the item
    -- the cursor was on; a workspace never moved around in opens at its dir.
    local key = isovim.current or ""
    local last = type(isovim.explorer_roots[key]) == "table" and isovim.explorer_roots[key] or {}
    if last.cwd and vim.fn.isdirectory(last.cwd) == 0 then
      last = {}
    end
    local reveal = opts.reveal or (not opts.cwd and last.file and vim.uv.fs_stat(last.file) and last.file) or nil
    Snacks.explorer({
      enter = opts.enter ~= false,
      cwd = opts.cwd or last.cwd or (isovim.current and store.dir(isovim.current)) or store.workspaces,
      on_close = function(picker)
        local item = picker:current()
        isovim.explorer_roots[key] = { cwd = picker:cwd(), file = item and item.file }
        isovim.remember("explorer_roots", isovim.explorer_roots)
      end,
      actions = {
        isovim_workspaces = M.show_workspaces,
        isovim_focus_chat = M.actions.isovim_focus_chat,
      },
      win = { list = { keys = { ["W"] = "isovim_workspaces", ["<c-l>"] = "isovim_focus_chat" } } },
      on_show = reveal and function(picker)
        require("snacks.explorer.tree"):open(reveal)
        require("snacks.explorer.actions").update(picker, { target = reveal, refresh = true })
      end or nil,
    })
  end)
end

function M.show_workspaces()
  M.view = "workspaces"
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    explorer:close()
  end
  vim.schedule(M.open)
end

-- Focuses the sidebar (the column or the file explorer), or closes it when already there.
-- Reopening shows the view it had.
function M.toggle()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer and not windows().list then
    if M.view == "explorer" then
      M.show_explorer()
    else
      M.open()
    end
  elseif not isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    M.focus()
  elseif explorer then
    explorer:close()
  else
    M.close()
  end
end

-- The sidebar's file explorer, focused; from inside it, back to the column. LazyVim's own explorer
-- keys come here too, rather than opening a second explorer beside the sidebar.
function M.files()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer then
    M.show_explorer()
  elseif isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    M.show_workspaces()
  else
    explorer:focus("list")
  end
end

-- After a hot reload the sidebar's keys and the explorer's actions still point at the old code.
-- The column keeps its windows and takes the new keys. The explorer reopens (its W would bring
-- back the old column), and so does the picker an isovim from before the column had; reopening
-- must not move the cursor: put back the window and mode (terminal/insert) the reload interrupted.
function M.reopen()
  local wins = windows()
  for role, win in pairs(wins) do
    map_keys(vim.api.nvim_win_get_buf(win), role)
  end
  if wins.list then
    return M.refresh()
  end
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if not sidebar then
    return
  end
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
      isovim.explorer_roots = store.read_session().explorer_roots or {}
      M.show_explorer({ enter = in_sidebar })
      vim.schedule(put_back_cursor)
    else
      M.open({ enter = in_sidebar })
      put_back_cursor()
    end
  end)
end

return M
