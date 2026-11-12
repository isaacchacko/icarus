-- An agent working on another, on the agent graph (isovim.agent_graph): when one reads another's screen or
-- transcript or renames it (the agent.*.acted events), a cursor leaves its box on a curve, as a hand would move
-- it, reads the other box line by line with that box lit, then curves back home by another way and is gone. Its
-- box stays where it is. Boxes are looked up again every frame, so a cursor follows them as the graph redraws.
--
-- The cursor and its trail are virtual text at window columns, so they cross the empty space between boxes; the
-- lit cells are extmarks over the lines, so the buffer and cursor don't move. The events are watched only while
-- the graph is on screen, and the timer runs only while a cursor moves. MAX_CURSORS move at once; the rest are
-- dropped.
local M = {}

local NS = vim.api.nvim_create_namespace("isovim_agent_cursors")
local TICK, MAX_CURSORS, TRAIL = 33, 4, 4
local SCAN_MS, ARRIVE_MS, HOME_MS = 2200, 220, 260
local POINTER, CLICK, TRAIL_GLYPHS = "\u{f01c0}", "\u{f0cfd}", { "•", "•", "·", "·" } -- md-cursor_default, _click
local LABELS = { peek = "reading its screen", transcript = "reading its history", rename = "renaming" }

-- In _G, so a hot reload keeps the watcher and what's moving.
_G.isovim_agent_cursors = _G.isovim_agent_cursors or { list = {} }
local cursors = _G.isovim_agent_cursors

local function graph_state()
  return _G.isovim_agent_graph
end

local function highlights()
  local color = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false }).fg
  local background = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  vim.api.nvim_set_hl(0, "IsovimCursor", { fg = color, bold = true })
  vim.api.nvim_set_hl(0, "IsovimCursorTrail", { fg = color })
  vim.api.nvim_set_hl(0, "IsovimCursorLabel", { fg = color, italic = true })
  vim.api.nvim_set_hl(0, "IsovimCursorBox", { fg = color })
  vim.api.nvim_set_hl(0, "IsovimCursorRead", { bg = color, fg = background })
end

local function now()
  return vim.uv.hrtime() / 1e6
end

local function smooth(t)
  t = math.min(math.max(t, 0), 1)
  return t * t * t * (t * (6 * t - 15) + 10)
end

local function node_of(key)
  local pulses = require("isovim.agent_pulses")
  local node = pulses.find(key)
  return node and pulses.shown(node)
end

local function center(node)
  return { node.y + (node.h - 1) / 2, node.x + node.w / 2 }
end

-- Where the cursor reads, line after line of the box's inside, the way back each time: the name line only for a
-- rename.
local function reading_points(node, act)
  local points, last = {}, act == "rename" and node.y + 1 or node.y + node.h - 2
  for y = node.y + 1, math.max(last, node.y + 1) do
    local from, to = node.x + 3, node.x + node.w - 4
    if (y - node.y) % 2 == 0 then
      from, to = to, from
    end
    points[#points + 1] = { y, from }
    points[#points + 1] = { y, to }
  end
  return points
end

-- A cubic curve from a to b bowed sideways by bend, a share of the way's length; rows count double, as a cell is
-- about twice as tall as it's wide.
local function curve(a, b, bend, t)
  local dy, dx = (b[1] - a[1]) * 2, b[2] - a[2]
  local length = math.sqrt(dx * dx + dy * dy)
  local side_y, side_x = dx / math.max(length, 1) / 2, -dy / math.max(length, 1)
  local function lerp(share, off)
    return { a[1] + (b[1] - a[1]) * share + side_y * off, a[2] + (b[2] - a[2]) * share + side_x * off }
  end
  local p1, p2 = lerp(0.3, bend * length), lerp(0.75, bend * length * 0.55)
  local u = 1 - t
  local function at(i)
    return u * u * u * a[i] + 3 * u * u * t * p1[i] + 3 * u * t * t * p2[i] + t * t * t * b[i]
  end
  return { at(1), at(2) }
end

local function travel_ms(a, b)
  local dy, dx = (b[1] - a[1]) * 2, b[2] - a[2]
  return math.min(math.max(math.sqrt(dx * dx + dy * dy) * 11, 650), 1500)
end

-- Along the reading points, easing into and out of each, with a little wander so it doesn't look ruled.
local function reading(points, t, started)
  local legs = #points - 1
  if legs < 1 then
    return points[1]
  end
  local at = math.min(t * legs, legs - 1e-9)
  local leg = math.floor(at)
  local a, b, share = points[leg + 1], points[leg + 2], smooth(at - leg)
  local wander = math.sin((now() - started) / 140) * 0.6
  return { a[1] + (b[1] - a[1]) * share, a[2] + (b[2] - a[2]) * share + wander }
end

-- Where a cursor is now, what it's doing, and whether it's done; nil once either box is gone.
local function where(cursor)
  local actor, target = node_of(cursor.by), node_of(cursor.target)
  if not (actor and target) then
    return nil
  end
  cursor.actor_node, cursor.target_node = actor, target
  local home, points = center(actor), reading_points(target, cursor.act)
  local first, last = points[1], points[#points]
  local out_ms = travel_ms(home, first)
  local back_ms = travel_ms(last, home)
  local scan_ms = cursor.act == "rename" and SCAN_MS * 0.6 or SCAN_MS
  local elapsed = now() - cursor.started
  if elapsed < out_ms then
    return curve(home, first, cursor.bend, smooth(elapsed / out_ms)), "out"
  end
  elapsed = elapsed - out_ms
  if elapsed < scan_ms then
    return reading(points, elapsed / scan_ms, cursor.started), elapsed < ARRIVE_MS and "arrive" or "read"
  end
  elapsed = elapsed - scan_ms
  if elapsed < back_ms then
    return curve(last, home, -cursor.bend * 1.3, smooth(elapsed / back_ms)), "back"
  elseif elapsed < back_ms + HOME_MS then
    return home, "home"
  end
  return home, "done"
end

local function light(buf, y, x, hl)
  local bytes = (graph_state().cell_bytes or {})[y + 1]
  local cell = bytes and bytes[x + 1]
  if cell then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, y, cell[1], { end_col = cell[2], hl_group = hl, priority = 5100 })
  end
end

local function light_border(buf, node)
  for x = node.x, node.x + node.w - 1 do
    light(buf, node.y, x, "IsovimCursorBox")
    light(buf, node.y + node.h - 1, x, "IsovimCursorBox")
  end
  for y = node.y + 1, node.y + node.h - 2 do
    light(buf, y, node.x, "IsovimCursorBox")
    light(buf, y, node.x + node.w - 1, "IsovimCursorBox")
  end
end

local function put(buf, lines, leftcol, y, x, text, hl)
  local row, col = math.floor(y + 0.5), math.floor(x + 0.5) - leftcol
  if row >= 0 and row < lines and col >= 0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, 0, { virt_text = { { text, hl } }, virt_text_win_col = col,
      priority = 5200 })
  end
end

-- Draws what's moving now, over what the graph drew.
function M.render()
  local state = graph_state()
  local buf = state and state.buf
  local win = buf and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) or -1
  if win == -1 then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local leftcol = vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol
  local lines = vim.api.nvim_buf_line_count(buf)
  for _, cursor in ipairs(cursors.list) do
    local at, phase = cursor.at, cursor.phase
    if at then
      local node = cursor.target_node
      if phase == "arrive" or phase == "read" then
        light_border(buf, node)
        -- The line it's on is lit as far as it's read, from where the sweep began.
        local row, col = math.floor(at[1] + 0.5), math.floor(at[2] + 0.5)
        local backwards = (row - node.y) % 2 == 0
        for x = backwards and col or node.x + 1, backwards and node.x + node.w - 2 or col do
          light(buf, row, x, "IsovimCursorRead")
        end
        put(buf, lines, leftcol, node.y + node.h - 1, node.x + 2, " " .. (LABELS[cursor.act] or cursor.act) .. " ", "IsovimCursorLabel")
      elseif phase == "home" then
        light_border(buf, cursor.actor_node)
      end
      if phase ~= "home" then
        for i = #cursor.trail, 1, -1 do
          local each = cursor.trail[i]
          put(buf, lines, leftcol, each[1], each[2], TRAIL_GLYPHS[i], "IsovimCursorTrail")
        end
        put(buf, lines, leftcol, at[1], at[2], phase == "arrive" and CLICK or POINTER, "IsovimCursor")
        if phase == "out" then
          put(buf, lines, leftcol, at[1], at[2] + 2, LABELS[cursor.act] or cursor.act, "IsovimCursorLabel")
        end
      end
    end
  end
end

local function stop_timer()
  if cursors.timer and not cursors.timer:is_closing() then
    cursors.timer:stop()
    cursors.timer:close()
  end
  cursors.timer = nil
end

local function tick()
  local state = graph_state()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1) then
    return M.stop()
  end
  local still = {}
  for _, cursor in ipairs(cursors.list) do
    local at, phase = where(cursor)
    if at and phase ~= "done" then
      -- The trail is the cells it last left, not every frame, so a slow cursor doesn't pile dots under itself.
      local cell = { math.floor(cursor.at and cursor.at[1] + 0.5 or at[1]), math.floor(cursor.at and cursor.at[2] + 0.5 or at[2]) }
      local moved = cell[1] ~= math.floor(at[1] + 0.5) or cell[2] ~= math.floor(at[2] + 0.5)
      if moved and (phase == "out" or phase == "back") then
        table.insert(cursor.trail, 1, cell)
        cursor.trail[TRAIL + 1] = nil
      elseif not moved and #cursor.trail > 0 and phase ~= "read" then
        table.remove(cursor.trail)
      end
      if phase == "read" or phase == "arrive" then
        cursor.trail = {}
      end
      cursor.at, cursor.phase = at, phase
      still[#still + 1] = cursor
    end
  end
  cursors.list = still
  M.render()
  if #still == 0 then
    stop_timer()
  end
end

M.tick = tick

local function start_timer()
  if cursors.timer then
    return
  end
  cursors.timer = assert(vim.uv.new_timer())
  cursors.timer:start(0, TICK, require("isovim.safe").ticker("the agent graph's cursors", function()
    require("isovim.agent_cursors").tick()
  end))
end

-- An agent did something to another: its cursor goes to look, unless it's already there.
function M.acted(by, target, act)
  local state = graph_state()
  if not (state and state.flat and by and target) or #cursors.list >= MAX_CURSORS then
    return
  end
  local actor, node = node_of(by), node_of(target)
  if not (actor and node) or actor == node then
    return
  end
  for _, cursor in ipairs(cursors.list) do
    if cursor.by == actor.key and cursor.target == node.key then
      return
    end
  end
  table.insert(cursors.list, { by = actor.key, target = node.key, act = act, started = now(), trail = {},
    bend = (math.random() < 0.5 and -1 or 1) * (0.25 + math.random() * 0.2) })
  start_timer()
end

-- The graph's on screen: what agents do to each other is watched.
function M.start()
  highlights()
  if cursors.stop_watch then
    return
  end
  cursors.stop_watch = require("isovim.events").watch(function(_, event)
    if event.topic:match("^agent%..*%.acted$") then
      require("isovim.safe").wrap("the agent graph's cursors", require("isovim.agent_cursors").acted)(event.by, event.addr, event.act)
    end
  end)
end

-- It isn't: nothing's watched or running, and nothing's left to carry on when it's back.
function M.stop()
  if cursors.stop_watch then
    cursors.stop_watch()
    cursors.stop_watch = nil
  end
  stop_timer()
  cursors.list = {}
  local state = graph_state()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  end
end

return M
