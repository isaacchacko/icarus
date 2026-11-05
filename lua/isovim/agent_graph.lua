-- The agents as a graph: one tab, one buffer, every project on this host and the other hosts' as the sidebar
-- knows them, each agent a box joined to whoever started it by box-drawing lines (the parent link, no message
-- edges). <leader>iG, or <CR> on Agents in the sidebar. The repo's root is at the top, what has no parent hanging off
-- it, with its root mode shown. Each open thread is a small square box on the agent that has it now: the worker it
-- waits on or is bypassed to, the root if it's answering, else its router. An agent with more than a few gets one
-- box for them all, folded, saying how many are yours.
--
-- A box's children hang off a trunk under its left side, in rows along buses, as many to a row as the window
-- holds, so a repo of 20 stays readable and a narrow window just stacks them. Lines never wrap; what's wider
-- than the window scrolls sideways with the cursor. A box says the agent's name, its role by glyph, color and
-- word, a spinner while it works, what it's on in a few words, and a mark for unread output or a thread waiting on
-- it. What's idle is dim, so what's moving stands out; hidden agents are here too, with an eye.
--
-- It's redrawn as states change: only the lines that changed are written, and the cursor stays put unless its
-- box moved. Messages moving between agents show as pulses along the lines (isovim.agent_pulses). hjkl go along the
-- graph (M.step). Any other motion (a scroll, the wheel, a click) moves the focus to
-- the box under the cursor or nearest it, so the next key goes from where you're looking.
local store = require("isovim.store")
local boxes = require("isovim.boxes")
local icons = require("isovim.icons")
local status = require("isovim.status")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_agent_graph")
local BOX_WIDTH, BOX_HEIGHT, INDENT, GAP, MIN_WIDTH = 28, 4, 4, 2, 16
local THREAD_WIDTH, THREAD_HEIGHT, THREADS_SHOWN = 30, 3, 3
local RANK = { root = 1, router = 2, dedicated = 3, worker = 4, script = 5, thread = 6, threads = 6 }
local ROLE_HL = { root = "Special", router = "DiagnosticInfo", dedicated = "DiagnosticHint", worker = "Normal", script = "Comment" }
local TICK, READ_EVERY = 150, 5000

-- In _G, so a hot reload keeps the buffer, its focus and what's folded.
_G.isovim_agent_graph = _G.isovim_agent_graph or { folded = {} }
local state = _G.isovim_agent_graph

local function number_of(id)
  return tonumber((id or ""):match("(%d+)$")) or 0
end

-- The threads each agent of repo has waiting on it.
local function waits_of(repo)
  local waits = {}
  local ok, list = pcall(require("isovim.surfaces").list, repo)
  for _, entry in ipairs(ok and list or {}) do
    if entry.type == "thread" and entry.waiting_on and entry.waiting_on ~= "user" then
      waits[entry.waiting_on] = (waits[entry.waiting_on] or 0) + 1
    end
  end
  return waits
end

-- Each thread's summary by its file, kept as long as its size and mtime stay, so a read is mostly stats.
state.thread_cache = state.thread_cache or {}

local function thread_infos(repo)
  local threads = require("isovim.threads")
  local infos, dir = {}, threads.dir(repo)
  if vim.fn.isdirectory(dir) == 0 then
    return infos
  end
  for base in vim.fs.dir(dir) do
    local id = base:match("^(t%d+)%.jsonl$")
    local stat = id and vim.uv.fs_stat(dir .. "/" .. base)
    if stat then
      local path = dir .. "/" .. base
      local cached = state.thread_cache[path]
      if not (cached and cached.size == stat.size and cached.mtime == stat.mtime.sec) then
        local info = threads.summary(threads.read(repo, id) or {})
        info.id = id
        cached = { size = stat.size, mtime = stat.mtime.sec, info = info }
        state.thread_cache[path] = cached
      end
      if cached.info.status == "open" then
        infos[#infos + 1] = cached.info
      end
    end
  end
  return infos
end

-- The repo's open threads as nodes, each hanging off the agent that has it now.
local function thread_nodes(repo, tasks)
  local threads = require("isovim.threads")
  local infos = thread_infos(repo)
  if #infos == 0 then
    return {}
  end
  local routers, seen, nodes = threads.routers(repo), threads.seen(repo), {}
  local root = require("isovim.rootmode").route(repo)
  for _, info in ipairs(infos) do
    local waits_on = info.waiting_on ~= "user" and info.waiting_on or nil
    local answering = root and (info.working_by == root or info.handed ~= nil or (info.root_posts or 0) > 0)
    local holder = waits_on or info.bypass or (answering and root) or threads.router_of(repo, info, routers)
    local task = info.task and tasks[info.task]
    nodes[#nodes + 1] = { key = repo .. "#" .. info.id, ws = repo, id = info.id, thread = true, role = "thread", name = info.title or info.id,
      status = info.working and "working" or "idle", parent = holder, yours = info.waiting_on == "user" or (info.pending or 0) > 0,
      question = (info.pending or 0) > 0, unread = (info.last_reply or 0) > (seen[info.id] or 0), task = task and task.id or nil,
      parked = task and task.column == "backburner" or nil, waits = 0 }
  end
  return nodes
end

-- This host's agents and the others', as the sidebar has them, by section: {key, title, hl, host?, nodes}.
local function read_sections()
  local panes, scope = require("isovim.panes"), require("isovim.scope")
  local repos = require("isovim.repos")
  local sessions, titles = panes.sessions(), panes.titles()
  local sections = {}
  for _, ws in ipairs(store.list()) do
    local nodes = {}
    local waits = store.is_pseudo(ws.id) and {} or waits_of(ws.id)
    for _, agent in ipairs(store.agents(ws.id)) do
      local script = require("isovim.scripts").of(agent)
      if script or not scope.is_terminal(agent) then
        local address = ws.id .. "/" .. agent.id
        local running = sessions[ws.id] and sessions[ws.id][agent.id] ~= nil
        nodes[#nodes + 1] = { key = address, ws = ws.id, id = agent.id, name = agent.name or agent.id, kind = agent.kind,
          role = script and "script" or store.shown_role(agent), hidden = agent.hidden, running = running, script = script,
          mode = store.role(agent) == "root" and not store.is_pseudo(ws.id) and require("isovim.rootmode").mode(ws.id) or nil,
          status = running and (status.get(ws.id, agent.id) or "idle") or "stopped",
          doing = running and panes.subtitle(agent.kind, titles[address]) or nil, waits = waits[address] or 0,
          parent = agent.parent or (agent.of and (ws.id .. "/" .. agent.of)) or nil }
      end
    end
    if #nodes > 0 then
      local style = ws.repo and repos.style(ws.repo)
      if not store.is_pseudo(ws.id) then
        vim.list_extend(nodes, thread_nodes(ws.id, (require("isovim.board_tasks").read(ws.id))))
      end
      sections[#sections + 1] = { key = ws.id, title = ws.name or ws.id, nodes = nodes, repo = ws.id,
        glyph = style and style.glyph, hl = style and style.color and repos.highlight(style.color) or "Title" }
    end
  end
  table.sort(sections, function(a, b)
    if store.is_pseudo(a.key) ~= store.is_pseudo(b.key) then
      return store.is_pseudo(b.key)
    end
    return a.key < b.key
  end)
  -- Other hosts': their `iso ls`, which the sidebar fetches anyway, so this adds no waiting.
  local remote = require("isovim.remote")
  local names = vim.tbl_keys(remote.peers())
  table.sort(names)
  for _, host in ipairs(names) do
    local by_workspace, order = {}, {}
    for _, row in ipairs(remote.list(host, remote.peers()[host], function()
      state.dirty = true
    end) or {}) do
      if row.script or not (row.kind == "terminal" or row.kind == "shell") then
        local section = by_workspace[row.workspace]
        if not section then
          section = { key = host .. ":" .. row.workspace, title = host .. " · " .. row.workspace, host = host, nodes = {}, hl = "Comment" }
          by_workspace[row.workspace] = section
          order[#order + 1] = section
        end
        local id = row.id:gsub("^[^:]+:", "")
        table.insert(section.nodes, { key = host .. ":" .. id, id = id:match("([^/]+)$"), name = row.agent, kind = row.kind,
          role = row.script and "script" or row.role or "worker", hidden = row.hidden, running = row.status ~= "stopped",
          status = row.status or "idle", doing = row.doing, waits = 0, host = host, remote_id = row.id, workspace = row.workspace,
          script = row.script, parent = row.parent and (host .. ":" .. row.parent:gsub("^[^:]+:", "")) or nil })
      end
    end
    table.sort(order, function(a, b)
      return a.key < b.key
    end)
    vim.list_extend(sections, order)
  end
  return sections
end

-- Each section's nodes as trees: a node's parent in its section, else it's a top one, the roots and routers
-- first. With a root, it's the one top, the rest hanging off it. A cycle written by hand comes out as top ones. An
-- agent with more than a few threads gets a box for them.
local function build_trees(sections)
  local function before(a, b)
    if (RANK[a.role] or 9) ~= (RANK[b.role] or 9) then
      return (RANK[a.role] or 9) < (RANK[b.role] or 9)
    end
    return number_of(a.id) < number_of(b.id)
  end
  for _, section in ipairs(sections) do
    local by_key = {}
    for _, node in ipairs(section.nodes) do
      by_key[node.key] = node
      node.children = {}
    end
    section.tops = {}
    for _, node in ipairs(section.nodes) do
      local above, at, cycle = by_key[node.parent or ""], node, false
      while at and by_key[at.parent or ""] do
        at = by_key[at.parent]
        if at == node then
          cycle = true
          break
        end
      end
      if above and above ~= node and not cycle then
        node.above = above
        table.insert(above.children, node)
      else
        table.insert(section.tops, node)
      end
    end
    table.sort(section.tops, before)
    local root = section.tops[1] and section.tops[1].role == "root" and section.tops[1] or nil
    if root then
      for i = 2, #section.tops do
        section.tops[i].above = root
        table.insert(root.children, section.tops[i])
      end
      section.tops = { root }
    end
    for _, node in ipairs(vim.list_slice(section.nodes)) do
      local threads = vim.tbl_filter(function(child)
        return child.thread
      end, node.children)
      if not node.thread and #threads > THREADS_SHOWN then
        local yours = #vim.tbl_filter(function(each)
          return each.yours
        end, threads)
        local group = { key = node.key .. "#threads", role = "threads", id = "threads", group = true, status = "idle", waits = 0, above = node,
          name = ("%d threads"):format(#threads), yours = yours > 0, yours_count = yours, unread = vim.iter(threads):any(function(each)
            return each.unread
          end), children = threads }
        node.children = vim.tbl_filter(function(child)
          return not child.thread
        end, node.children)
        table.insert(node.children, group)
        for _, thread in ipairs(threads) do
          thread.above = group
        end
        table.insert(section.nodes, group)
      end
    end
    for _, node in ipairs(section.nodes) do
      table.sort(node.children, before)
      node.section = section
    end
  end
end

-- What's shown under a node: a threads box is folded until opened, anything else open until folded.
state.opened = state.opened or {}

local function kids_of(node)
  if node.group then
    return state.opened[node.key] and node.children or {}
  end
  return state.folded[node.key] and {} or node.children
end

local function total_under(node)
  local n = #node.children
  for _, child in ipairs(node.children) do
    n = n + total_under(child)
  end
  return n
end

-- Packs blocks into rows no wider than width: {items, w, h}.
local function pack(items, width)
  local rows, row = {}, nil
  for i, item in ipairs(items) do
    -- Threads on a row of their own, under the agents.
    local turning = item.role == "thread" or item.role == "threads"
    turning = turning and items[i - 1] and items[i - 1].role ~= "thread" and items[i - 1].role ~= "threads"
    if not row or turning or (row.w + GAP + item.block_w > width and #row.items > 0) then
      row = { items = {}, w = -GAP, h = 0 }
      rows[#rows + 1] = row
    end
    table.insert(row.items, item)
    row.w, row.h = row.w + GAP + item.block_w, math.max(row.h, item.block_h)
  end
  return rows
end

-- How much room a node and all under it take, in rows that fit width.
local function measure(node, width, box_w)
  local kids = kids_of(node)
  local small = node.thread or node.group
  node.w = small and (box_w >= BOX_WIDTH and THREAD_WIDTH or box_w) or box_w
  node.h = small and THREAD_HEIGHT or BOX_HEIGHT
  node.block_w, node.block_h, node.rows = node.w, node.h, nil
  if #kids == 0 then
    return
  end
  local room = math.max(box_w, width - INDENT)
  for _, kid in ipairs(kids) do
    measure(kid, room, box_w)
  end
  node.rows = pack(kids, room)
  for _, row in ipairs(node.rows) do
    node.block_w = math.max(node.block_w, INDENT + row.w)
    node.block_h = node.block_h + 1 + row.h
  end
end

-- Where a node and all under it go: x and y, 0-based cells.
local function place(node, x, y)
  node.x, node.y = x, y
  local at = y + node.h
  for _, row in ipairs(node.rows or {}) do
    row.bus = at
    local cell = x + INDENT
    for _, kid in ipairs(row.items) do
      place(kid, cell, at + 1)
      cell = cell + kid.block_w + GAP
    end
    at = at + 1 + row.h
  end
end

-- A grid of cells, each {char, hl}, a wide character's second cell being "".
local function new_canvas(height)
  local rows = {}
  for r = 1, height do
    rows[r] = {}
  end
  return rows
end

local function put(canvas, y, x, text, hl)
  local row = canvas[y + 1]
  if not row then
    return
  end
  local cell = x
  for i = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    local width = vim.fn.strdisplaywidth(char)
    row[cell + 1] = { char, hl }
    if width == 2 then
      row[cell + 2] = { "", hl }
    end
    cell = cell + math.max(width, 1)
  end
end

-- text cut to cells, with … if it had to be.
local function cut(text, cells)
  if vim.fn.strdisplaywidth(text) <= cells then
    return text
  end
  local out = text
  while vim.fn.strdisplaywidth(out) > math.max(cells - 1, 0) do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

local function role_word(node)
  if node.role == "dedicated" then
    return require("isovim.config").dedicated_label()
  elseif node.role == "script" then
    return node.script or "script"
  end
  return node.role
end

-- A thread's box, or the box for an agent's threads: small and square, so it reads apart from the agents.
local function draw_thread(canvas, node, focused)
  local moving = node.status == "working"
  local lively = moving or node.yours or node.unread
  local border = focused and "IsovimBoardFocus" or (node.parked and "NonText") or (node.yours and "DiagnosticWarn")
    or (moving and "DiagnosticInfo") or (node.unread and "DiagnosticOk") or "NonText"
  local inner, x, y = node.w - 2, node.x, node.y
  put(canvas, y, x, "┌" .. ("─"):rep(inner) .. "┐", border)
  put(canvas, y + 2, x, "└" .. ("─"):rep(inner) .. "┘", border)
  put(canvas, y + 1, x, "│", border)
  put(canvas, y + 1, x + inner + 1, "│", border)
  put(canvas, y + 1, x + 1, (" "):rep(inner))
  local tail, tail_w = {}, 0
  local function mark(text, hl)
    tail[#tail + 1] = { text, hl }
    tail_w = tail_w + vim.fn.strdisplaywidth(text) + 1
  end
  if node.group then
    if (node.yours_count or 0) > 0 then
      mark(("%d yours"):format(node.yours_count), "DiagnosticWarn")
    end
    if node.unread then
      mark("●", "DiagnosticOk")
    end
    mark(state.opened[node.key] and "▾" or "▸", "Special")
  else
    if node.task then
      mark(node.task, "Comment")
    end
    if node.unread then
      mark("●", "DiagnosticOk")
    end
    if node.question then
      mark("?", "DiagnosticWarn")
    elseif node.yours then
      mark("\u{f0a4}", "DiagnosticWarn") -- fa-hand_o_right: over to you
    end
  end
  local lead = 2
  if moving then
    local icon, icon_hl = status.icon("working")
    put(canvas, y + 1, x + 1, icon, icon_hl)
  else
    put(canvas, y + 1, x + 1, "\u{f086}", lively and "Special" or "Comment")
  end
  local room = math.max(1, inner - lead - tail_w)
  local text = node.group and node.name or (node.id .. " " .. node.name)
  put(canvas, y + 1, x + 3, cut(text, room), focused and "Bold" or (lively and "Normal" or "Comment"))
  local at = x + inner + 1 - tail_w
  for _, each in ipairs(tail) do
    put(canvas, y + 1, at, each[1], each[2])
    at = at + vim.fn.strdisplaywidth(each[1]) + 1
  end
end

local function draw_box(canvas, node, width, focused)
  if node.thread or node.group then
    return draw_thread(canvas, node, focused)
  end
  local moving = node.status == "working"
  local unread = node.status == "unread" or node.status == "attention"
  -- A root in root mode is on watch, and shows it, moving or not.
  local lively = moving or unread or node.waits > 0 or node.mode ~= nil
  local text_hl = lively and "Normal" or "Comment"
  local border = focused and "IsovimBoardFocus" or ((moving or node.mode) and ROLE_HL[node.role]) or (unread and "DiagnosticWarn") or "NonText"
  if border == "Normal" then
    border = "DiagnosticInfo"
  end
  local inner = width - 2
  local x, y = node.x, node.y
  put(canvas, y, x, "╭" .. ("─"):rep(inner) .. "╮", border)
  put(canvas, y + 3, x, "╰" .. ("─"):rep(inner) .. "╯", border)
  for r = 1, 2 do
    put(canvas, y + r, x, "│", border)
    put(canvas, y + r, x + inner + 1, "│", border)
    put(canvas, y + r, x + 1, (" "):rep(inner))
  end
  local icon, icon_hl = status.icon(node.status)
  if not moving then
    icon, icon_hl = " ", nil
  end
  local glyph, glyph_hl = icons.get(((node.role == "router" or node.role == "dedicated") and "router") or node.kind)
  put(canvas, y + 1, x + 1, icon, icon_hl)
  put(canvas, y + 1, x + 2, glyph or "•", lively and glyph_hl or "Comment")
  -- The marks at the right: unread, threads waiting on it, hidden, how many a fold holds.
  local tail, tail_w = {}, 0
  local function mark(text, hl)
    tail[#tail + 1] = { text, hl }
    tail_w = tail_w + vim.fn.strdisplaywidth(text) + 1
  end
  if unread then
    mark("●", node.status == "unread" and "DiagnosticOk" or "DiagnosticWarn")
  end
  if node.waits > 0 then
    mark("⧗" .. node.waits, "DiagnosticWarn")
  end
  if node.hidden then
    mark("\u{f0209}", "Comment") -- md-eye_off
  end
  if state.folded[node.key] and #node.children > 0 then
    mark("▸" .. total_under(node), "Special")
  end
  local name_room = math.max(1, inner - 3 - tail_w)
  put(canvas, y + 1, x + 4, cut(node.name or node.id, name_room), focused and "Bold" or text_hl)
  local at = x + inner + 1 - tail_w
  for _, each in ipairs(tail) do
    put(canvas, y + 1, at, each[1], each[2])
    at = at + vim.fn.strdisplaywidth(each[1]) + 1
  end
  local under = role_word(node)
  if node.mode then
    under = under .. " · " .. node.mode
  end
  if node.status == "stopped" then
    under = under .. " · stopped"
  elseif node.doing and node.doing ~= "" then
    under = under .. " · " .. node.doing:gsub("%s+", " ")
  end
  put(canvas, y + 2, x + 2, cut(under, inner - 2), lively and ROLE_HL[node.role] or "Comment")
end

-- The lines from a node to those under it: a trunk, a bus along each row, a drop into each box.
local function draw_edges(canvas, node)
  local hl = "NonText"
  for _, row in ipairs(node.rows or {}) do
    for _, kid in ipairs(row.items) do
      draw_edges(canvas, kid)
    end
  end
  if not node.rows then
    return
  end
  local trunk = node.x + 2
  put(canvas, node.y + node.h - 1, trunk, "┬", hl)
  local last = node.rows[#node.rows].bus
  for y = node.y + node.h, last - 1 do
    put(canvas, y, trunk, "│", hl)
  end
  for i, row in ipairs(node.rows) do
    put(canvas, row.bus, trunk, i == #node.rows and "╰" or "├", hl)
    local far = row.items[#row.items].x + 2
    for x = trunk + 1, far do
      put(canvas, row.bus, x, "─", hl)
    end
    for j, kid in ipairs(row.items) do
      put(canvas, row.bus, kid.x + 2, j == #row.items and "╮" or "┬", hl)
      put(canvas, kid.y, kid.x + 2, "┴", hl)
    end
  end
end

local function each_node(node, fn)
  fn(node)
  for _, kid in ipairs(kids_of(node)) do
    each_node(kid, fn)
  end
end

-- Every node shown, in the graph's order (M.step), and each section's place.
local function layout(sections, width)
  local box_w = width >= BOX_WIDTH + 2 and BOX_WIDTH or math.max(MIN_WIDTH, width - 1)
  local y = 0
  local flat = {}
  for _, section in ipairs(sections) do
    section.y = y
    y = y + 1
    for _, top in ipairs(section.tops) do
      measure(top, width - 1, box_w)
    end
    for _, row in ipairs(pack(section.tops, width - 1)) do
      local x = 1
      for _, top in ipairs(row.items) do
        place(top, x, y)
        x = x + top.block_w + GAP
        each_node(top, function(node)
          flat[#flat + 1] = node
        end)
      end
      y = y + row.h
    end
    y = y + 1
  end
  return flat, y, box_w
end

-- The canvas as lines, its highlights as {row, from, to, hl} in bytes, and each cell's bytes for the pulses.
local function to_lines(canvas)
  local lines, marks, cell_bytes = {}, {}, {}
  for r, row in ipairs(canvas) do
    local parts, bytes, last = {}, 0, 0
    cell_bytes[r] = {}
    for cell in pairs(row) do
      last = math.max(last, cell)
    end
    local run_hl, run_from
    for c = 1, last do
      local each = row[c]
      local char, hl = each and each[1] or " ", each and each[2] or nil
      if hl ~= run_hl then
        if run_hl then
          marks[#marks + 1] = { r - 1, run_from, bytes, run_hl }
        end
        run_hl, run_from = hl, bytes
      end
      parts[#parts + 1] = char
      cell_bytes[r][c] = { bytes, bytes + #char }
      bytes = bytes + #char
    end
    if run_hl then
      marks[#marks + 1] = { r - 1, run_from, bytes, run_hl }
    end
    lines[r] = table.concat(parts)
  end
  return lines, marks, cell_bytes
end

local function window()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) or -1
end

local function winbar_text()
  local hints = { { "hjkl", "move" }, { "⏎", "open" }, { "z", "fold" }, { "[ ]", "project" }, { "?", "keys" } }
  local parts = { "%#Title# Agents %#Comment#" }
  for _, hint in ipairs(hints) do
    parts[#parts + 1] = (" %%#IsovimBoardKey# %s %%#Comment# %s "):format(hint[1], hint[2])
  end
  return table.concat(parts)
end

-- Reads what's so, from files and tmux: not on every frame.
local function read()
  state.sections = read_sections()
  build_trees(state.sections)
  state.read_at, state.dirty = vim.uv.now(), nil
  state.any_working = false
  for _, section in ipairs(state.sections) do
    for _, node in ipairs(section.nodes) do
      state.any_working = state.any_working or node.status == "working"
    end
  end
end

local function focus_node()
  for _, node in ipairs(state.flat or {}) do
    if node.key == state.focus then
      return node
    end
  end
end

-- Draws from what was read, writing only the lines that changed, the cursor kept where it is unless move_cursor
-- or its box moved.
function M.draw(move_cursor)
  local win = window()
  if win == -1 or not state.sections then
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  local flat, height, box_w = layout(state.sections, width)
  state.flat, state.box_w = flat, box_w
  if not focus_node() then
    local current = require("isovim").current_scope
    local first = vim.iter(flat):find(function(node)
      return node.ws == current
    end) or flat[1]
    state.focus = first and first.key or nil
    move_cursor = true
  end
  local canvas = new_canvas(math.max(height, 1))
  for _, section in ipairs(state.sections) do
    local count, working, thread_count = 0, 0, 0
    for _, node in ipairs(section.nodes) do
      if node.thread then
        thread_count = thread_count + 1
      elseif not node.group then
        count = count + 1
        working = working + (node.status == "working" and 1 or 0)
      end
    end
    local head = (section.glyph and (section.glyph .. " ") or "") .. section.title
    put(canvas, section.y, 1, head, section.hl)
    put(canvas, section.y, vim.fn.strdisplaywidth(head) + 2,
      ("%d %s%s%s"):format(count, count == 1 and "agent" or "agents", working > 0 and (" · %d working"):format(working) or "",
        thread_count > 0 and (" · %d %s"):format(thread_count, thread_count == 1 and "thread" or "threads") or ""), "Comment")
    for _, top in ipairs(section.tops) do
      draw_edges(canvas, top)
    end
  end
  local focused = focus_node()
  for _, node in ipairs(flat) do
    draw_box(canvas, node, box_w, node == focused)
    -- A drop into this box, over its top border.
    if node.above then
      put(canvas, node.y, node.x + 2, "┴", node == focused and "IsovimBoardFocus" or "NonText")
    end
  end
  for _, node in ipairs(flat) do
    if node.rows then
      put(canvas, node.y + node.h - 1, node.x + 2, "┬", node == focused and "IsovimBoardFocus" or "NonText")
    end
  end
  local lines, marks, cell_bytes = to_lines(canvas)
  state.cell_bytes = cell_bytes
  local buf = state.buf
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.bo[buf].modifiable = true
  if #before ~= #lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    for i, line in ipairs(lines) do
      if before[i] ~= line then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { line })
      end
    end
  end
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  local wo = vim.wo[win][0]
  local bar = winbar_text()
  if wo.winbar ~= bar then
    wo.winbar = bar
  end
  -- The cursor follows its box only if that moved, or a key asked.
  if focused then
    local where = focused.y .. ":" .. focused.x
    if move_cursor or (state.focus_at and state.focus_at ~= where) then
      local col = vim.fn.virtcol2col(win, focused.y + 2, focused.x + 5)
      pcall(vim.api.nvim_win_set_cursor, win, { focused.y + 2, math.max(0, col - 1) })
    end
    state.focus_at = where
  end
  require("isovim.agent_pulses").after_draw()
end

-- What's so may have changed: read it again, if it's been a moment, and draw. As the sidebar refreshes.
function M.refresh()
  if window() ~= -1 and (state.dirty or vim.uv.now() - (state.read_at or 0) >= 500) then
    read()
    M.draw()
  end
end

local function stop_timer()
  if state.timer and not state.timer:is_closing() then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = nil
end

-- A spinner frame while something works, a fresh read now and then: only while it's on screen.
local function start_timer()
  stop_timer()
  state.timer = assert(vim.uv.new_timer())
  state.timer:start(TICK, TICK, require("isovim.safe").ticker("the agent graph", function()
    local graph = require("isovim.agent_graph")
    if window() == -1 then
      require("isovim.agent_pulses").stop()
      return stop_timer()
    end
    if state.dirty or vim.uv.now() - (state.read_at or 0) >= READ_EVERY then
      read()
      return graph.draw()
    end
    if state.any_working then
      graph.draw()
    end
  end))
end

-- hjkl along the graph: h and l the boxes beside it, k whoever started it, j the first it started, else what
-- comes after it. Across the top ones and on to the next section.
function M.step(key)
  local node = focus_node()
  if not node then
    return
  end
  local section = node.section
  local siblings = node.above and kids_of(node.above) or section.tops
  local index = 1
  for i, each in ipairs(siblings) do
    if each == node then
      index = i
    end
  end
  local to
  if key == "h" then
    to = siblings[index - 1]
  elseif key == "l" then
    to = siblings[index + 1]
  elseif key == "k" then
    to = node.above or siblings[index - 1]
    if not to then
      local flat, at = state.flat, 1
      for i, each in ipairs(flat) do
        if each == node then
          at = i
        end
      end
      local before = flat[at - 1]
      to = before and before.section.tops[1] or nil
    end
  elseif key == "j" then
    to = kids_of(node)[1]
    local at = node
    while not to and at do
      local list = at.above and kids_of(at.above) or at.section.tops
      for i, each in ipairs(list) do
        if each == at then
          to = list[i + 1]
        end
      end
      at = at.above
    end
    if not to then
      local flat, last = state.flat, 1
      for i, each in ipairs(flat) do
        if each == node then
          last = i
        end
      end
      for i = last + 1, #flat do
        if flat[i].section ~= section then
          to = flat[i]
          break
        end
      end
    end
  end
  if to then
    state.focus = to.key
    M.draw(true)
  end
end

function M.open_focused()
  local node = focus_node()
  if not node then
    return
  elseif node.group then
    return M.fold()
  elseif node.thread then
    return require("isovim.acp.chat").open_thread(node.ws, node.id)
  elseif node.host then
    return require("isovim").open_remote(node.host, require("isovim.remote").host_of(node.host), node.remote_id:gsub("^[^:]+:", ""),
      node.host .. ":" .. node.workspace, node.name)
  end
  require("isovim").open(node.ws, node.id)
end

function M.fold()
  local node = focus_node()
  if not node then
    return
  elseif node.group then
    state.opened[node.key] = not state.opened[node.key] or nil
    return M.draw(true)
  elseif #node.children == 0 then
    return vim.notify("isovim: " .. node.name .. " started nothing to fold", vim.log.levels.INFO)
  end
  state.folded[node.key] = not state.folded[node.key] or nil
  M.draw(true)
end

-- [ ]: the previous or next project, as the sidebar's are, the graph going to its section; one with no agents
-- is passed over.
function M.step_project(by)
  local sidebar = require("isovim.sidebar")
  for _ = 1, #sidebar.projects do
    sidebar.step_project(by)
    local section = vim.iter(state.sections or {}):find(function(each)
      return each.repo == sidebar.project
    end)
    if section then
      vim.b[state.buf].isovim_scope = section.repo
      require("isovim").set_scope(section.repo)
      local top = section.tops[1]
      state.focus = top and top.key or state.focus
      -- Once the scope's change has settled, as it can move the cursor.
      return require("isovim.safe").schedule("the agent graph", function()
        local win = window()
        if win == -1 then
          return
        end
        state.focus = top and top.key or state.focus
        M.draw(true)
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({ topline = section.y + 1 })
        end)
      end)
    end
  end
  vim.notify("isovim: no other project has agents", vim.log.levels.INFO)
end

-- The cursor went somewhere by a scroll, the wheel or a click: the focus goes to the box under it, or nearest.
function M.cursor_moved()
  local win = window()
  local node = focus_node()
  if win == -1 or not state.flat then
    return
  end
  local line, cell = vim.api.nvim_win_get_cursor(win)[1] - 1, vim.fn.virtcol(".") - 1
  local inside = function(each)
    return line >= each.y and line < each.y + each.h and cell >= each.x and cell < each.x + each.w
  end
  if node and inside(node) then
    return
  end
  local best, distance
  for _, each in ipairs(state.flat) do
    if inside(each) then
      best, distance = each, 0
      break
    end
    local d = math.abs(each.y - line) * 4 + math.abs(each.x - cell)
    if not best or d < distance then
      best, distance = each, d
    end
  end
  if best and best ~= node then
    state.focus = best.key
    M.draw()
  end
end

-- The keys, for ? here and in the sidebar's help.
M.help_keys = {
  { "h / l", "the box beside it, left / right, among those with the same parent" },
  { "j / k", "the first it started, else what comes after it / whoever started it" },
  { "<CR>", "open that agent's chat or that thread; on an agent's box of threads, open or close it" },
  { "z", "fold or unfold all it started and holds" },
  { "[ / ]", "the previous / next project" },
  { "<C-d> <C-u> gg G, the wheel", "scroll: the focus goes to the box under the cursor" },
  { "?", "these keys" },
}

local function bind(buf)
  local function on(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("isovim.safe").wrap("the agent graph", fn)()
    end, { buffer = buf, nowait = true, desc = "isovim: " .. desc })
  end
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    on(key, function()
      require("isovim.agent_graph").step(key)
    end, "along the graph")
  end
  on("<CR>", function()
    require("isovim.agent_graph").open_focused()
  end, "open this agent's chat or this thread")
  on("z", function()
    require("isovim.agent_graph").fold()
  end, "fold all it started")
  on("[", function()
    require("isovim.agent_graph").step_project(-1)
  end, "the previous project")
  on("]", function()
    require("isovim.agent_graph").step_project(1)
  end, "the next project")
  on("?", function()
    local text = vim.tbl_map(function(key)
      return ("%-14s %s"):format(key[1], key[2])
    end, require("isovim.agent_graph").help_keys)
    vim.notify(table.concat(text, "\n"), vim.log.levels.INFO, { title = "The agent graph" })
  end, "the graph's keys")
  require("isovim").map_to_sidebar(buf)
  local group = vim.api.nvim_create_augroup("isovim_agent_graph", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      require("isovim.safe").wrap("the agent graph", require("isovim.agent_graph").cursor_moved)()
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      require("isovim.safe").schedule("the agent graph", function()
        require("isovim.agent_graph").shown()
      end)
    end,
  })
end

-- Its window's look, and its drawing running, whenever it comes into one.
function M.shown()
  local win = window()
  if win == -1 then
    return
  end
  local wo = vim.wo[win][0]
  wo.wrap, wo.number, wo.relativenumber, wo.signcolumn, wo.cursorline, wo.list = false, false, false, "no", false, false
  wo.conceallevel, wo.sidescrolloff = 0, 8
  read()
  M.draw(true)
  start_timer()
  require("isovim.agent_pulses").start()
end

-- Opens the graph as a tab of the current project, drawing everything.
function M.open()
  boxes.highlights()
  vim.api.nvim_set_hl(0, "IsovimBoardFocus", { default = true, link = "DiagnosticInfo" })
  local fresh = not (state.buf and vim.api.nvim_buf_is_valid(state.buf))
  if fresh then
    local buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = "hide", false, "isovim_graph"
    pcall(vim.api.nvim_buf_set_name, buf, "isovim-graph://agents")
    bind(buf)
  end
  local buf = state.buf
  vim.b[buf].isovim_tab = { name = "Agents", icon = "\u{f0645}", hl = "Special" } -- md-graph
  vim.b[buf].isovim_scope = require("isovim").current_scope
  vim.b[buf].completion = false
  vim.bo[buf].buflisted = true
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    require("isovim").show(buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  M.shown()
  vim.cmd.redrawtabline()
end

-- After a hot reload the buffer takes the new keys.
function M.rebind()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    bind(state.buf)
  end
end

return M
