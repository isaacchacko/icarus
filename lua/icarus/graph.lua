-- The graph: a task's agents, in the window chats show in. The task is the root; each chat on it is
-- a box hanging off it, saying whether it's working, idle or needs you, for how long, what's queued
-- and its title; under a box, the subagents it's running now. It redraws while it shows.
--
-- j and k go from agent to agent, <CR> opens the one under the cursor, n starts a new agent on the
-- task, and q goes back to the view before.
--
-- In a democracy each box shows the agent's claim and edges (icarus.democracy), which you edit, over
-- theirs: r, n or c starts a reviews, needs or contests edge from the agent you're on, and <CR> on
-- another ends it (<Esc> calls it off); dd removes one of its edges; m on two agents merges the second
-- into the first. a starts a new agent.
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local M = {}

local NAME = "icarus://graph"
local NS = vim.api.nvim_create_namespace("icarus_graph")
local REFRESH_MS = 500
-- Where the trunk runs down from the task's box, and the widest an agent's box gets.
local TRUNK, MAX_BOX = 4, 64

local GLYPH = { working = "●", ["needs you"] = "◆", idle = "○" }
local STATUS_HL = { working = "IcarusGraphWorking", ["needs you"] = "IcarusGraphNeeds", idle = "IcarusGraphIdle" }

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusGraphWorking", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphNeeds", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphIdle", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphLine", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphBox", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphSelected", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "IcarusGraphTitle", { bold = true, default = true })
end
highlights()

-- In _G, so a hot reload keeps them.
_G.icarus_graph = _G.icarus_graph or {}
local state = _G.icarus_graph ---@type {task?: string, nodes?: {row: integer, last: integer, record: icarus.ChatRecord}[], timer?: uv.uv_timer_t}

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function fit(text, cols)
  if width(text) <= cols then
    return text .. (" "):rep(cols - width(text))
  end
  return vim.fn.strcharpart(text, 0, cols - 1) .. "…"
end

local function duration(seconds)
  seconds = math.floor(seconds)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return ("%dm%02ds"):format(math.floor(seconds / 60), seconds % 60)
  end
  return ("%dh%02dm"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

-- What the chat with record shows about itself: its status, the open chat if it's open.
function M.agent(record)
  local open = _G.icarus_open_chats and _G.icarus_open_chats[record.id]
  local status = chats.status(record.id)
  local subagents = {}
  for _, call in pairs(open and open.tools or {}) do
    local name = require("icarus.acp.look").tool_name(call)
    if (name == "Task" or name == "Agent") and call.status ~= "completed" and call.status ~= "failed" then
      local input = call.input or {}
      subagents[#subagents + 1] = ("%s%s"):format(input.subagent_type and (input.subagent_type .. ": ") or "",
        input.description or call.title or "subagent")
    end
  end
  for _, child in pairs(open and open.subagents or {}) do
    if require("icarus.subagents").running(child) then
      subagents[#subagents + 1] = require("icarus.subagents").label(child) .. (child.last and (" · " .. child.last) or "")
    end
  end
  table.sort(subagents)
  local note = {}
  if open and open.busy and open.since then
    local sec, usec = vim.uv.gettimeofday()
    note[#note + 1] = duration(sec + usec / 1e6 - open.since)
  end
  local queued = open and #open.session.queue or 0
  if queued > 0 then
    note[#note + 1] = queued .. " queued"
  end
  if not open then
    note[#note + 1] = "not open"
  end
  return status, table.concat(note, " · "), subagents
end

local function buf()
  local b = vim.fn.bufnr("^" .. NAME .. "$")
  if b == -1 then
    b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = "icarus_graph"
    vim.bo[b].modifiable = false
    vim.api.nvim_buf_set_name(b, NAME)
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("icarus.graph")[fn]()
    end, { buffer = b, nowait = true, desc = desc })
  end
  map("j", "next", "Next agent")
  map("k", "previous", "Previous agent")
  map("<CR>", "enter", "Open this agent")
  map("n", "wire_needs", "New agent on this task, or in a democracy, a needs edge")
  map("a", "new", "New agent on this task")
  map("r", "wire_reviews", "In a democracy, a reviews edge")
  map("c", "wire_contests", "In a democracy, a contests edge")
  map("dd", "unwire", "In a democracy, remove an edge")
  map("m", "merge", "In a democracy, merge two agents")
  map("<Esc>", "cancel", "Call off the edge being wired")
  map("q", "back", "Back")
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("icarus_graph", { clear = true }),
    buffer = b,
    callback = function()
      require("icarus.graph").draw()
    end,
  })
  return b
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- The node under the cursor, if the graph is the window you're in.
local function selected()
  local b = buf()
  if vim.api.nvim_get_current_buf() ~= b then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for i, node in ipairs(state.nodes or {}) do
    if row >= node.row and row <= node.last then
      return node, i
    end
  end
end

-- Draws the graph of state.task in the window showing it.
function M.draw()
  local b = buf()
  local win = vim.fn.win_findbuf(b)[1]
  local task = state.task and tasks.read(state.task)
  if not (win and task) then
    return stop()
  end
  local cols = vim.api.nvim_win_get_width(win)
  local box = math.max(24, math.min(MAX_BOX, cols - TRUNK - 6))
  local lines, marks, nodes = {}, {}, {}
  local function add(text, line_marks)
    lines[#lines + 1] = text
    marks[#lines] = line_marks or {}
  end
  local records = chats.on_task(task.slug)
  local democracy = require("icarus.orchestration").style(task) == "democracy"
  -- The task.
  local root = math.max(24, math.min(MAX_BOX, width(task.title) + 4))
  local summary = ("%s%d agent%s"):format(task.status and (task.status .. " · ") or "", #records, #records == 1 and "" or "s")
  add("╭" .. ("─"):rep(root) .. "╮", { { 0, -1, "IcarusGraphBox" } })
  add("│ " .. fit(task.title, root - 2) .. " │", { { 0, -1, "IcarusGraphBox" }, { 4, 4 + #fit(task.title, root - 2), "IcarusGraphTitle" } })
  add("│ " .. fit(summary, root - 2) .. " │", { { 0, -1, "IcarusGraphBox" }, { 4, -4, "IcarusGraphIdle" } })
  local bottom = "╰" .. ("─"):rep(TRUNK - 1) .. (#records > 0 and "┬" or "─") .. ("─"):rep(root - TRUNK) .. "╯"
  add(bottom, { { 0, -1, "IcarusGraphBox" } })
  local pad = (" "):rep(TRUNK)
  -- The agents, newest first, each a box off the trunk, its subagents under it.
  for i, record in ipairs(records) do
    local last = i == #records
    local stem, rest = last and "└──" or "├──", last and "   " or "│  "
    local status, note, subagents = M.agent(record)
    local head = ("%s %s%s"):format(GLYPH[status] or "○", status, note ~= "" and (" · " .. note) or "")
    local title = record.title or "new chat"
    add(pad .. "│", { { 0, -1, "IcarusGraphLine" } })
    local top_row = #lines
    add(pad .. stem .. "╭" .. ("─"):rep(box) .. "╮")
    add(pad .. rest .. "│ " .. fit(head, box - 2) .. " │")
    add(pad .. rest .. "│ " .. fit(title, box - 2) .. " │")
    add(pad .. rest .. "╰" .. ("─"):rep(box) .. "╯")
    for _, part in ipairs(democracy and require("icarus.democracy").describe(task.slug, record.id) or {}) do
      add(pad .. rest .. "   " .. fit(part, box - 2))
    end
    for j, sub in ipairs(subagents) do
      add(pad .. rest .. "   " .. (j == #subagents and "└─ " or "├─ ") .. "◌ " .. fit(sub, box - 6))
    end
    nodes[#nodes + 1] = { row = top_row, last = #lines - 1, record = record, status = status,
      stem = #pad + #stem, rest = #pad + #rest }
  end
  if #records == 0 then
    add("")
    add("  no agents on this task yet: n starts one", { { 0, -1, "IcarusGraphIdle" } })
  end
  state.nodes = nodes
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  local function mark(row, from, to, group)
    local text = lines[row + 1]
    from = from < 0 and #text + from + 1 or from
    to = to < 0 and #text + to + 1 or to
    if to > from then
      vim.api.nvim_buf_set_extmark(b, NS, row, from, { end_col = to, hl_group = group })
    end
  end
  for row, line_marks in pairs(marks) do
    for _, m in ipairs(line_marks) do
      mark(row - 1, m[1], m[2], m[3])
    end
  end
  local current = selected()
  for _, node in ipairs(nodes) do
    local group = node == current and "IcarusGraphSelected" or "IcarusGraphBox"
    for row = node.row, node.row + 3 do
      local from = row == node.row and node.stem or node.rest
      mark(row, 0, from, "IcarusGraphLine")
      mark(row, from, -1, group)
    end
    -- The status's glyph and word in its colour, and the title.
    local status_row, status_col = node.row + 1, node.rest + #"│ "
    mark(status_row, status_col, status_col + #(GLYPH[node.status] or "○") + 1 + #node.status, STATUS_HL[node.status] or "IcarusGraphIdle")
    mark(node.row + 2, status_col, -#"│ " - 1, "IcarusGraphTitle")
    for row = node.row + 4, node.last do
      mark(row, 0, -1, "IcarusGraphLine")
    end
  end
  for row = 4, #lines - 1 do
    if lines[row + 1] == pad .. "│" then
      mark(row, 0, -1, "IcarusGraphLine")
    end
  end
  if not state.timer then
    state.timer = assert(vim.uv.new_timer())
    state.timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
      require("icarus.graph").draw()
    end))
  end
end

local function go(step)
  local nodes = state.nodes or {}
  if #nodes == 0 then
    return
  end
  local _, i = selected()
  i = i and math.max(1, math.min(#nodes, i + step)) or (step > 0 and 1 or #nodes)
  vim.api.nvim_win_set_cursor(0, { nodes[i].row + 2, 0 })
end

function M.next()
  go(1)
end

function M.previous()
  go(-1)
end

local function democratic()
  local task = state.task and tasks.read(state.task)
  return task and require("icarus.orchestration").style(task) == "democracy"
end

local function wire(kind)
  local node = selected()
  if node and democratic() then
    state.wiring = { kind = kind, from = node.record.id }
    vim.notify(("%s from %s: move to the other agent, <CR>"):format(kind, node.record.title or node.record.id))
  end
end

function M.wire_reviews()
  wire("reviews")
end

function M.wire_contests()
  wire("contests")
end

function M.wire_needs()
  if not democratic() then
    return M.new()
  end
  wire("needs")
end

function M.cancel()
  state.wiring, state.marked = nil, nil
end

-- dd: picks one of the edges of the agent under the cursor and removes it.
function M.unwire()
  local node = selected()
  if not (node and democratic()) then
    return
  end
  local democracy = require("icarus.democracy")
  local edges = vim.tbl_filter(function(edge)
    return edge.from == node.record.id or edge.to == node.record.id
  end, democracy.graph(state.task).edges)
  vim.ui.select(edges, { prompt = "Remove which edge?", format_item = function(edge)
    local from, to = chats.get(edge.from), chats.get(edge.to)
    return ("%s: %s → %s"):format(edge.type, from and from.title or edge.from, to and to.title or edge.to)
  end }, function(edge)
    if edge then
      democracy.user_unedge(state.task, edge)
    end
  end)
end

-- m on the agent that stays, then on the one that folds into it.
function M.merge()
  local node = selected()
  if not (node and democratic()) then
    return
  end
  if not state.marked then
    state.marked = node.record.id
    return vim.notify(("Merging into %s: m on the agent to fold in"):format(node.record.title or node.record.id))
  end
  if state.marked ~= node.record.id then
    require("icarus.democracy").user_merge(state.task, state.marked, node.record.id)
  end
  state.marked = nil
end

function M.enter()
  local node = selected()
  local task = state.task and tasks.read(state.task)
  if node and state.wiring then
    require("icarus.democracy").user_edge(state.task, state.wiring.kind, state.wiring.from, node.record.id)
    state.wiring = nil
    return
  end
  if node and task then
    require("icarus.task_page").open(task, node.record)
  end
end

function M.new()
  local task = state.task and tasks.read(state.task)
  if task then
    local page = require("icarus.task_page")
    page.open(task, page.new_agent(task))
  end
end

function M.back()
  require("icarus").last_view()
end

-- <leader>g: the graph of the task you're on ("(no task)" if none), in the window chats show in.
---@param task? icarus.Task
function M.open(task)
  local icarus = require("icarus")
  if not task then
    local view = icarus.view()
    local record = icarus.current() and chats.get(icarus.current())
    local slug = view and view.task or record and record.task or tasks.SENTINEL
    task = tasks.read(slug) or tasks.sentinel()
  end
  state.task = task.slug
  local win = icarus.main()
  require("icarus.acp.chat").leave(win)
  vim.api.nvim_win_set_buf(win, buf())
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, cursorline = false }) do
    vim.wo[win][0][option] = value
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.stopinsert()
  icarus.set_view({ kind = "graph", task = task.slug })
  M.draw()
  -- On the agent showing before, else the first.
  for _, node in ipairs(state.nodes or {}) do
    if node.record.id == icarus.current() then
      return vim.api.nvim_win_set_cursor(win, { node.row + 2, 0 })
    end
  end
  if state.nodes and state.nodes[1] then
    vim.api.nvim_win_set_cursor(win, { state.nodes[1].row + 2, 0 })
  end
end

return M
