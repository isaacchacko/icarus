-- Messages moving on the agent graph (isovim.agent_graph): when one goes between two agents, or a post between a
-- thread and its agent, a couple of lit cells
-- travel from sender to receiver along the graph's lines, through their common ancestor when they aren't parent and
-- child, blue going down, green going up, purple across. Timing's loose: they come from the msg.* events, which is
-- when a message reached its agent, so a pulse may start late. Agents with no line between them (two top ones,
-- two projects) or a sender that isn't drawn (you, an agent on another host) get a short flash on the box that's
-- there. In a folded subtree a pulse stops at the fold.
--
-- They're extmarks over the lines, so the buffer and cursor don't move. The events are watched only while the
-- graph is on screen, and the timer runs only while a pulse moves. MAX_PULSES move at once; the rest are dropped,
-- so a burst of messages can't lag the TUI.
local M = {}

local NS = vim.api.nvim_create_namespace("isovim_agent_pulses")
local TICK, MAX_PULSES, FLASH_TICKS, LONGEST_TICKS = 90, 8, 6, 60
local COLORS = { down = "DiagnosticInfo", up = "DiagnosticOk", across = "DiagnosticHint" }

-- In _G, so a hot reload keeps the watcher and what's moving.
_G.isovim_agent_pulses = _G.isovim_agent_pulses or { list = {} }
local pulses = _G.isovim_agent_pulses

local function graph_state()
  return _G.isovim_agent_graph
end

local function highlights()
  local background = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  for name, from in pairs(COLORS) do
    local fg = vim.api.nvim_get_hl(0, { name = from, link = false }).fg
    vim.api.nvim_set_hl(0, "IsovimPulse_" .. name, { bg = fg, fg = background, bold = true })
  end
end

-- What a message's end is: a node drawn or folded away, by the address the event gives.
local function find(address)
  local self = require("isovim.remote").self()
  local key = (address or ""):gsub("^" .. vim.pesc(self) .. ":", "")
  for _, section in ipairs(graph_state().sections or {}) do
    for _, node in ipairs(section.nodes) do
      if node.key == key then
        return node
      end
    end
  end
end

-- The node itself if it's shown, else the fold holding it.
local function shown(node)
  local state = graph_state()
  local at = node
  while at.above and vim.iter(state.flat or {}):all(function(each)
    return each ~= at
  end) do
    at = at.above
  end
  return at
end

-- The cells of the line from a node to one it started: down its trunk, along the bus, into the child's top.
local function segment(parent, child)
  local cells, trunk = {}, parent.x + 2
  local bus
  for _, row in ipairs(parent.rows or {}) do
    if vim.tbl_contains(row.items, child) then
      bus = row.bus
    end
  end
  if not bus then
    return cells
  end
  for y = parent.y + parent.h - 1, bus do
    cells[#cells + 1] = { y, trunk }
  end
  for x = trunk + 1, child.x + 2 do
    cells[#cells + 1] = { bus, x }
  end
  cells[#cells + 1] = { child.y, child.x + 2 }
  return cells
end

local function reversed(list)
  local out = {}
  for i = #list, 1, -1 do
    out[#out + 1] = list[i]
  end
  return out
end

local function chain_up(node)
  local chain = { node }
  while chain[#chain].above do
    chain[#chain + 1] = chain[#chain].above
  end
  return chain
end

-- From an ancestor down to a node of its subtree, all the segments.
local function descend(top, node)
  local chain, cells = {}, {}
  local at = node
  while at ~= top do
    table.insert(chain, 1, at)
    at = at.above
  end
  local above = top
  for _, each in ipairs(chain) do
    vim.list_extend(cells, segment(above, each))
    above = each
  end
  return cells
end

-- The cells from a to b along the graph's lines, and which way that is: nil with no line between them.
local function route(a, b)
  local of_a = chain_up(a)
  local meet
  for _, each in ipairs(chain_up(b)) do
    if vim.tbl_contains(of_a, each) then
      meet = each
      break
    end
  end
  if not meet then
    return nil
  elseif meet == a then
    return descend(a, b), "down"
  elseif meet == b then
    return reversed(descend(b, a)), "up"
  end
  local from, to = descend(meet, a), descend(meet, b)
  -- They leave the common ancestor by the same trunk: only as far as they part.
  local shared = 0
  while from[shared + 1] and to[shared + 1] and from[shared + 1][1] == to[shared + 1][1] and from[shared + 1][2] == to[shared + 1][2] do
    shared = shared + 1
  end
  local cells = reversed(vim.list_slice(from, math.max(shared, 1)))
  vim.list_extend(cells, vim.list_slice(to, shared + 1))
  return cells, "across"
end

-- The box's border, as cells to light for a moment.
local function border(node)
  local width, cells = node.w, {}
  for x = node.x, node.x + width - 1 do
    cells[#cells + 1] = { node.y, x }
    cells[#cells + 1] = { node.y + node.h - 1, x }
  end
  for y = node.y + 1, node.y + node.h - 2 do
    cells[#cells + 1] = { y, node.x }
    cells[#cells + 1] = { y, node.x + width - 1 }
  end
  return cells
end

local function light(buf, y, x, hl)
  local bytes = (graph_state().cell_bytes or {})[y + 1]
  local cell = bytes and bytes[x + 1]
  if cell then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, y, cell[1], { end_col = cell[2], hl_group = hl, priority = 5000 })
  end
end

-- Draws what's moving now, over what the graph drew.
function M.render()
  local state = graph_state()
  local buf = state and state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, pulse in ipairs(pulses.list) do
    if pulse.flash then
      for _, cell in ipairs(pulse.cells) do
        light(buf, cell[1], cell[2], pulse.hl)
      end
    else
      local head = math.floor(pulse.head)
      -- A cell or two; a long way moves faster, and its tail keeps the moving unbroken.
      for i = math.max(1, head - pulse.step), math.min(head, #pulse.cells) do
        light(buf, pulse.cells[i][1], pulse.cells[i][2], pulse.hl)
      end
    end
  end
end

local function stop_timer()
  if pulses.timer and not pulses.timer:is_closing() then
    pulses.timer:stop()
    pulses.timer:close()
  end
  pulses.timer = nil
end

local function tick()
  local state = graph_state()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1) then
    return M.stop()
  end
  local still = {}
  for _, pulse in ipairs(pulses.list) do
    if pulse.flash then
      pulse.left = pulse.left - 1
      if pulse.left > 0 then
        still[#still + 1] = pulse
      end
    else
      pulse.head = pulse.head + pulse.step
      if pulse.head - pulse.step <= #pulse.cells then
        still[#still + 1] = pulse
      elseif pulse.receiver then
        -- It's arrived: the box that got it lights up.
        still[#still + 1] = { flash = true, left = FLASH_TICKS, cells = border(pulse.receiver), hl = pulse.hl, node = pulse.receiver }
      end
    end
  end
  pulses.list = still
  M.render()
  if #still == 0 then
    stop_timer()
  end
end

local function start_timer()
  if pulses.timer then
    return
  end
  pulses.timer = assert(vim.uv.new_timer())
  pulses.timer:start(TICK, TICK, require("isovim.safe").ticker("the agent graph's pulses", function()
    require("isovim.agent_pulses").tick()
  end))
end

M.tick = tick

local function add(pulse)
  if #pulses.list >= MAX_PULSES then
    return
  end
  table.insert(pulses.list, pulse)
  start_timer()
end

local function flash(node, kind)
  add({ flash = true, left = FLASH_TICKS, cells = border(node), hl = "IsovimPulse_" .. kind, node = node })
end

-- A message reached an agent: its pulse, or a flash on what's drawn of it.
function M.message(from, to)
  local state = graph_state()
  if not (state and state.flat and from ~= to) then
    return
  end
  local sender, receiver = from and find(from), to and find(to)
  if not (sender or receiver) then
    return
  end
  sender, receiver = sender and shown(sender), receiver and shown(receiver)
  if not (sender and receiver) then
    return flash(sender or receiver, sender and "up" or "down")
  elseif sender == receiver then
    return flash(sender, "across")
  end
  local cells, kind = route(sender, receiver)
  if not cells then
    flash(sender, "across")
    return flash(receiver, "across")
  end
  -- Slowly, but a long way isn't left crawling.
  add({ cells = cells, head = 1, step = math.max(1, math.ceil(#cells / LONGEST_TICKS)), hl = "IsovimPulse_" .. kind,
    sender = sender, receiver = receiver })
end

-- A post on a thread: yours moves from the thread to the agent that has it, flashing the thread as you post it, and
-- an agent's from it to the thread. You aren't a box of your own.
function M.post(repo, id, by)
  local state = graph_state()
  if not (state and state.flat) then
    return
  end
  local thread = find(repo .. "#" .. id)
  if not thread then
    return
  end
  local holder = thread.above
  while holder and holder.group do
    holder = holder.above
  end
  if by == "user" then
    flash(shown(thread), "down")
    if holder then
      M.message(thread.key, holder.key)
    end
  else
    local sender = find(by) or holder
    if sender then
      M.message(sender.key, thread.key)
    end
  end
end

-- The graph drew: what's moving goes on along wherever its boxes are now.
function M.after_draw()
  if #pulses.list == 0 then
    return
  end
  for _, pulse in ipairs(pulses.list) do
    if pulse.flash then
      pulse.cells = border(pulse.node)
    else
      local cells = route(pulse.sender, pulse.receiver)
      if cells and #cells ~= #pulse.cells then
        pulse.head = pulse.head * #cells / math.max(#pulse.cells, 1)
      end
      pulse.cells = cells or pulse.cells
    end
  end
  M.render()
end

-- The graph's on screen: its messages are watched.
function M.start()
  highlights()
  if pulses.stop_watch then
    return
  end
  pulses.stop_watch = require("isovim.events").watch(function(_, event)
    local wrap = require("isovim.safe").wrap
    if event.topic:match("^msg%.") then
      -- A post on a thread reaching its agent moves by the post's own event.
      if not require("isovim.threads").tagged(event.text) then
        wrap("the agent graph's pulses", require("isovim.agent_pulses").message)(event.from, event.addr)
      end
    elseif event.topic:match("^thread%..*%.posted$") then
      wrap("the agent graph's pulses", require("isovim.agent_pulses").post)(event.repo, event.id, event.by)
    end
  end)
end

-- It isn't: nothing's watched or running, and nothing's left to carry on when it's back.
function M.stop()
  if pulses.stop_watch then
    pulses.stop_watch()
    pulses.stop_watch = nil
  end
  stop_timer()
  pulses.list = {}
  local state = graph_state()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  end
end

return M
