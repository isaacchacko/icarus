-- The Workspaces picker, its Needs-you pane, and the file explorer that can take its place.
-- init.lua requires this module only from inside functions, so requiring it back makes no cycle.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local prs = require("isovim.prs")
local icons = require("isovim.icons")
local diffstat = require("isovim.diffstat")
local remote = require("isovim.remote")
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
  -- A divider: what follows is on that machine.
  host = {
    format = function(item)
      if item.down then
        return { { "── ", "Comment" }, { icons.get("host"), "Comment" }, { " " .. item.host .. " unreachable ", "Comment" }, { ("─"):rep(40), "Comment" } }
      end
      return { { "── ", "Comment" }, { icons.get("host") }, { " " }, { item.host, "Title" }, { " " .. ("─"):rep(40), "Comment" } }
    end,
    id = { "host" },
  },
  workspace = {
    format = function(item)
      local folder, folder_hl = icons.get(item.ws == isovim.current and "workspace_current" or "workspace")
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
    delete = function(_, item)
      Snacks.picker.util.confirm("Archive " .. item.ws_name .. "?", function()
        panes.stop_all(item.ws)
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
    delete = function(_, item)
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
    delete = function(_, item)
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

-- Rows: each workspace with its agents, or its PRs while P is on; a collapsed workspace (the default)
-- only its own row. Hidden agents show only while show_hidden is on. Agents waiting on you
-- (attention) also go to M.queue, the "Needs you" pane.
local function sidebar_items()
  isovim.mark_visible_seen()
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
      if not agent.hidden or isovim.show_hidden then
        ws.agents[#ws.agents + 1] = agent
        ws.running = ws.running or agent.running
        working = working or agent.status == "working"
      end
      if M.needs_you(agent) then
        queue[#queue + 1] =
          { ws = ws.id, ws_name = ws.name, agent = agent.id, name = agent.name, kind = agent.kind, status = agent.status }
      end
    end
  end
  -- The other hosts' agents, by host then workspace, as their `iso ls` lists them.
  local hosts = {}
  for name, host in pairs(remote.peers()) do
    local rows = remote.list(name, host, M.refresh)
    if rows then
      isovim.notify_remote(name, rows)
    end
    if remote.down(name) then
      hosts[#hosts + 1] = { name = name, ssh = host, order = {}, by_ws = {}, down = true }
    elseif rows and #rows > 0 then
      local by_ws, order = {}, {}
      for _, row in ipairs(rows) do
        local ws_id = row.id:match("^[^/]+")
        local state = row.status ~= "idle" and row.status ~= "stopped" and row.status or nil
        local agent = { id = row.id, name = row.agent, kind = row.kind, status = state, running = row.status ~= "stopped", hidden = row.hidden, doing = row.doing, tasks = row.tasks }
        if not by_ws[ws_id] then
          by_ws[ws_id] = { name = row.workspace, agents = {} }
          order[#order + 1] = ws_id
        end
        if not agent.hidden or isovim.show_hidden then
          table.insert(by_ws[ws_id].agents, agent)
          by_ws[ws_id].running = by_ws[ws_id].running or agent.running
        end
        if M.needs_you(agent) then
          queue[#queue + 1] = { host = name, ssh = host, agent = row.id, ws_name = name .. ":" .. row.workspace, name = row.agent, kind = row.kind, status = state }
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
    return a[isovim.sort] > b[isovim.sort]
  end)
  table.sort(queue, function(a, b)
    return (a.status == "attention" and 0 or 1) < (b.status == "attention" and 0 or 1)
  end)
  M.queue = queue

  local items = {}
  -- An agent's tasks, in tree order: each one's subtasks right under it.
  local function add_tasks(base, agent)
    if not isovim.show_tasks then
      return
    end
    local tasks = agent.tasks or {}
    local function under(parent, depth)
      for _, task in ipairs(tasks) do
        if task.parent == parent then
          items[#items + 1] = vim.tbl_extend("force", base, {
            kind = "task",
            text = base.ws_name .. " " .. agent.name .. " " .. task.title,
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
  for _, ws in ipairs(workspaces) do
    local base = { ws = ws.id, ws_name = ws.name }
    local added, removed = diffstat.get(ws.dir, M.refresh)
    local row = { kind = "workspace", text = ws.name, running = ws.running, added = added, removed = removed, status = most_urgent(ws.agents) }
    items[#items + 1] = vim.tbl_extend("force", base, row)
    local open = isovim.expanded[ws.id]
    if open and isovim.show_prs then
      local list = prs.list(ws.id, M.refresh)
      for _, pr in ipairs(list) do
        local text = ws.name .. " " .. (pr.title or pr.url)
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "pr", text = text, pr = pr, url = pr.url })
      end
      if #list == 0 then
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "empty", text = ws.name .. " no PRs yet" })
      end
    elseif open then
      for _, agent in ipairs(ws.agents) do
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "agent",
          text = ws.name .. " " .. agent.name,
          agent = agent.id,
          name = agent.name,
          agent_kind = agent.kind,
          status = agent.status,
          running = agent.running,
          hidden = agent.hidden,
          subtitle = agent.running and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id]) or nil,
          ports = agent.running and require("isovim.ports").of(ws.id, agent.id) or nil,
        })
        add_tasks(base, agent)
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
  if not isovim.show_prs then
    for _, host in ipairs(hosts) do
      items[#items + 1] = { kind = "host", text = host.name, host = host.name, ws = "@" .. host.name, down = host.down }
      for _, ws_id in ipairs(host.order) do
        local ws = host.by_ws[ws_id]
        local base = { host = host.name, ssh = host.ssh, ws = host.name .. ":" .. ws_id, ws_name = ws.name, remote_ws = ws_id }
        local text = host.name .. " " .. ws.name
        items[#items + 1] = vim.tbl_extend("force", base, { kind = "workspace", text = text, running = ws.running, status = most_urgent(ws.agents) })
        for _, agent in ipairs(isovim.expanded[base.ws] and ws.agents or {}) do
          items[#items + 1] = vim.tbl_extend("force", base, {
            kind = "agent",
            text = host.name .. " " .. ws.name .. " " .. agent.name,
            agent = agent.id,
            name = agent.name,
            agent_kind = agent.kind,
            status = agent.status,
            running = agent.running,
            hidden = agent.hidden,
            subtitle = agent.doing,
          })
          add_tasks(base, agent)
        end
      end
    end
  end
  return items
end

local function row_of(picker, item)
  for i = 1, picker.list:count() do
    local row = picker.list:get(i)
    local same = row.kind == item.kind
    for _, field in ipairs(KINDS[item.kind].id) do
      same = same and row[field] == item[field]
    end
    if same then
      return i
    end
  end
end

-- The sidebar's cursor sits on what you're looking at: the agent in the focused window, or else the
-- current workspace. Left alone while you're moving around the sidebar yourself.
local function follow(picker)
  if picker.closed or isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    return
  end
  local shown = vim.api.nvim_get_current_buf()
  local agent = vim.b[shown].isovim_id == isovim.current and vim.b[shown].isovim_agent
  local target = agent and row_of(picker, { kind = "agent", ws = isovim.current, agent = agent })
    or row_of(picker, { kind = "workspace", ws = isovim.current })
  if target then
    picker.list:view(target)
  end
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
local function refresh(picker)
  if picker.isovim_refresh_pending then
    return
  end
  picker.isovim_refresh_pending = true
  vim.defer_fn(function()
    picker.isovim_refresh_pending = nil
    if picker.closed then
      return
    end
    -- A sidebar reopened by a hot reload has no cursor yet: it lands on the item the old one had.
    local before = picker.isovim_keep or picker.list:current()
    picker.isovim_keep = nil
    picker.list:set_target(picker.list.cursor, picker.list.top, { force = true })
    picker:find({
      refresh = true,
      on_done = function()
        update_queue(picker)
        if not isovim.is_sidebar(vim.api.nvim_get_current_win()) or not before then
          return follow(picker)
        end
        local i = row_of(picker, before)
        if i then
          picker.list:view(i)
        end
      end,
    })
  end, 30)
end

function M.refresh()
  local picker = Snacks.picker.get({ source = "isovim" })[1]
  if picker then
    refresh(picker)
  end
end

function M.follow()
  local picker = Snacks.picker.get({ source = "isovim" })[1]
  if picker then
    follow(picker)
  end
end

local function add_agent(ws, spec)
  local agent = store.add_agent(ws, spec)
  isovim.open(ws, agent.id)
  isovim.refresh()
end

-- {key, action, description}: the sidebar list's and the Needs-you pane's keys, which `?` lists.
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
  section("Sidebar", LIST_KEYS)
  section("Needs you", QUEUE_KEYS)
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
    height = #lines,
    wo = { wrap = false, conceallevel = 2 },
    keys = { q = "close", ["?"] = "close" },
  })
end

-- H, P and L show in the sidebar's title as badges, like the explorer's hidden-files toggle:
-- snacks draws a badge for each `toggles` entry whose picker option is on.
local TOGGLES = { isovim_hidden = "h", isovim_prs = "p", isovim_ports = "l", isovim_tasks = "t" }

local function toggle(option, badge)
  return function(picker)
    isovim.remember(option, not isovim[option])
    picker.opts[badge] = isovim[option]
    picker:update_titles()
    refresh(picker)
  end
end

M.actions = {
  isovim_open = function(_, item)
    return item and KINDS[item.kind].open and KINDS[item.kind].open(item)
  end,
  isovim_open_queued = function(picker)
    local entry = M.queue[vim.api.nvim_win_get_cursor(picker.preview.win.win)[1]]
    return entry and KINDS.agent.open(entry)
  end,
  isovim_focus_queue = function(picker)
    if not picker.layout:is_hidden("preview") then
      picker:focus("preview")
    end
  end,
  isovim_focus_list = function(picker)
    picker:focus("list")
  end,
  isovim_toggle_prs = toggle("show_prs", "isovim_prs"),
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
  isovim_find = isovim.find,
  isovim_open_port = function(_, item)
    if item and item.kind == "pr" then
      vim.ui.open(item.pr.url)
    elseif item and item.ws and not item.host then
      isovim.open_port(item.ws, item.agent)
    end
  end,
  isovim_changes = function(_, item)
    if item and item.kind == "pr" then
      vim.ui.open(item.pr.url .. "/files")
    elseif item and item.ws and not item.host then
      isovim.changes(item.ws)
    end
  end,
  isovim_yank_url = function(_, item)
    if item and item.kind == "pr" then
      vim.fn.setreg("+", item.pr.url)
      vim.notify("Copied " .. item.pr.url)
    end
  end,
  isovim_restart = function(_, item)
    if item and item.agent and not item.host then
      Snacks.picker.util.confirm(("Restart %s?"):format(item.name), function()
        isovim.restart(item.ws, item.agent)
        isovim.refresh()
      end)
    end
  end,
  -- t opens a new terminal in the workspace under the cursor; it outlives the TUI like the agents.
  isovim_terminal = function(_, item)
    local ws = item and item.ws or isovim.current
    if ws then
      add_agent(ws, { kind = "terminal" })
    end
  end,
  isovim_rename = function(picker, item)
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
  isovim_delete = function(picker, item)
    return item and KINDS[item.kind].delete and KINDS[item.kind].delete(picker, item)
  end,
  -- m moves the workspace to another host; its agents resume there (iso move).
  isovim_move = function(picker, item)
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
  isovim_toggle_expand = function(picker, item)
    if not item or not item.ws or item.kind == "host" then
      return
    end
    isovim.expanded[item.ws] = not isovim.expanded[item.ws] or nil
    isovim.remember("expanded", isovim.expanded)
    picker.isovim_keep = { kind = "workspace", ws = item.ws }
    refresh(picker)
  end,
  isovim_toggle_hidden = toggle("show_hidden", "isovim_hidden"),
  isovim_toggle_ports = toggle("show_ports", "isovim_ports"),
  isovim_toggle_tasks = toggle("show_tasks", "isovim_tasks"),
  isovim_explorer = function()
    M.show_explorer()
  end,
  isovim_focus_chat = function()
    vim.api.nvim_set_current_win(isovim.main_win())
  end,
  isovim_last_workspace = isovim.last_workspace,
  isovim_help = M.help,
  isovim_sort = function(picker)
    isovim.remember("sort", isovim.sort == "created" and "active" or "created")
    Snacks.notify.info("Sorted by " .. (isovim.sort == "created" and "creation time" or "recent activity"))
    refresh(picker)
  end,
}

-- Another host's rows only open; changing them is that host's business.
for _, name in ipairs({ "isovim_add_agent", "isovim_terminal", "isovim_rename", "isovim_delete" }) do
  local action = M.actions[name]
  M.actions[name] = function(picker, item)
    if item and item.host then
      return Snacks.notify.info(("That's on %s; change it there"):format(item.host), { title = "isovim" })
    end
    return action(picker, item)
  end
end

---@param opts? {enter?: boolean}
function M.open(opts)
  return Snacks.picker.pick({
    source = "isovim",
    enter = not opts or opts.enter ~= false,
    title = "Workspaces",
    toggles = TOGGLES,
    isovim_hidden = isovim.show_hidden,
    isovim_prs = isovim.show_prs,
    isovim_ports = isovim.show_ports,
    isovim_tasks = isovim.show_tasks,
    finder = sidebar_items,
    format = function(item)
      return KINDS[item.kind].format(item)
    end,
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
    actions = M.actions,
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
---@param opts? {cwd?: string, reveal?: string, enter?: boolean} reveal: a file to select once it's open
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

-- Focuses the sidebar (Workspaces or the file explorer), or closes it when already there.
-- Reopening shows the view it had.
function M.toggle()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if not sidebar then
    if M.view == "explorer" then
      M.show_explorer()
    else
      M.open()
    end
  elseif isovim.is_sidebar(vim.api.nvim_get_current_win()) then
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
  elseif isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    M.show_workspaces()
  else
    explorer:focus("list")
  end
end

-- After a hot reload the open sidebar's actions still point at the old code, in either view; the
-- explorer's W would bring back an old Workspaces. Reopening it must not move the cursor: put back
-- the window and mode (terminal/insert) the reload interrupted.
function M.reopen()
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
  local keep = not explorer and sidebar.list:current() or nil
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
      M.open({ enter = in_sidebar }).isovim_keep = keep
      put_back_cursor()
    end
  end)
end

return M
