-- The home page, the whole screen: the contour lines of a field that keeps changing, drawn in
-- braille dots across the window and moving while home shows. Under it the keys and your last few
-- tasks, 1-3 opening them.
--
-- Each braille character is 2 by 4 dots, so the window is a bitmap twice its width and four times
-- its height. The field is a few waves over coordinates that are themselves bent by slower waves,
-- all drifting with time. Its range is cut into levels, and a dot is set wherever the level changes
-- from the dot to its right or below: those are the contour lines. Each character takes the colour
-- of the highest level among its dots, deep blue low to warm yellow high.
local T = require("icarus.theme")

local M = {}

local NAME = "icarus://home"
local NS = vim.api.nvim_create_namespace("icarus_home")
local FRAME_MS = 90
local RECENT = 3
local LEVELS = 11
-- How many field units across the window's height: the size of the hills.
local ZOOM = 3.2
local SPEED = 0.035

local COLORS = T.field

local function highlights()
  for i, color in ipairs(COLORS) do
    vim.api.nvim_set_hl(0, "IcarusHomeLevel" .. i, { fg = color, default = true })
  end
  vim.api.nvim_set_hl(0, "IcarusHomeTitle", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusHomeHint", { link = "IcarusAcpNotice", default = true })
end
highlights()

-- Braille: the bit for the dot at (row, col) in its 2x4 cell, and the character for each 8 bits.
local DOT = { { 0x01, 0x08 }, { 0x02, 0x10 }, { 0x04, 0x20 }, { 0x40, 0x80 } }
local BRAILLE = {}
for bits = 0, 255 do
  BRAILLE[bits] = vim.fn.nr2char(0x2800 + bits)
end

-- In _G, so a hot reload keeps one timer, not two, and the field where it was.
_G.icarus_home = _G.icarus_home or {}
local state = _G.icarus_home
state.frame = state.frame or 0

local sin, cos, floor = math.sin, math.cos, math.floor

-- The field at (x, y) at time t, between about -1 and 1.
local function field(x, y, t)
  -- Bend the coordinates with slow waves, so the hills drift and change shape.
  local u = x + 0.55 * sin(0.8 * y + 0.6 * t) + 0.25 * sin(1.7 * y - 0.9 * t)
  local v = y + 0.55 * cos(0.7 * x - 0.5 * t) + 0.25 * cos(1.5 * x + 0.8 * t)
  return 0.45 * sin(u * 1.1 + 0.3 * t) * cos(v * 0.9 - 0.2 * t)
    + 0.3 * sin(0.7 * u - 1.3 * v + 0.45 * t)
    + 0.25 * cos(1.9 * u + 0.6 * v - 0.35 * t)
end

-- The frame as rows cells high and cols wide: its lines, and for each its colour runs.
local function render(cols, rows, f)
  local w, h = cols * 2, rows * 4
  local t = f * SPEED
  local scale = ZOOM / h
  -- Each dot's level, a row longer and a column wider for the neighbours of the last ones.
  local level = {}
  for y = 0, h do
    local row = {}
    for x = 0, w do
      local value = field(x * scale, y * scale, t)
      row[x] = floor((value + 1) * 0.5 * LEVELS)
    end
    level[y] = row
  end
  local lines, marks = {}, {}
  for r = 0, rows - 1 do
    local cells, runs = {}, {}
    for c = 0, cols - 1 do
      local bits, top = 0, nil
      for dy = 0, 3 do
        local y = r * 4 + dy
        local here, below = level[y], level[y + 1]
        for dx = 0, 1 do
          local x = c * 2 + dx
          local l = here[x]
          if l ~= here[x + 1] or l ~= below[x] then
            bits = bits + DOT[dy + 1][dx + 1]
            local high = math.max(l, here[x + 1], below[x])
            if not top or high > top then
              top = high
            end
          end
        end
      end
      cells[#cells + 1] = BRAILLE[bits]
      if top then
        top = math.max(1, math.min(LEVELS, top))
        local last = runs[#runs]
        -- Every braille character is 3 bytes.
        if last and last[3] == top and last[2] == c * 3 then
          last[2] = (c + 1) * 3
        else
          runs[#runs + 1] = { c * 3, (c + 1) * 3, top }
        end
      end
    end
    lines[#lines + 1] = table.concat(cells)
    marks[#marks + 1] = runs
  end
  return lines, marks
end

local function recent()
  local list = {}
  for _, task in ipairs(require("icarus.tasks").recent()) do
    if not task.sentinel and task.status ~= "cancelled" and task.status ~= "merged" and #list < RECENT then
      list[#list + 1] = task
    end
  end
  return list
end

-- Its buffer, made the first time; its keys set each time, so after a hot reload they run the new code.
function M.buf()
  local buf = vim.fn.bufnr("^" .. NAME .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "icarus_home"
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_set_name(buf, NAME)
  end
  vim.keymap.set("n", "n", function()
    require("icarus").new_chat()
  end, { buffer = buf, nowait = true, desc = "New chat" })
  vim.keymap.set("n", "t", function()
    require("icarus").new_task()
  end, { buffer = buf, nowait = true, desc = "New task" })
  for i = 1, RECENT do
    vim.keymap.set("n", tostring(i), function()
      local task = state.tasks and state.tasks[i]
      if task then
        require("icarus").open_task(require("icarus.tasks").read(task.slug) or task)
      end
    end, { buffer = buf, nowait = true, desc = "Open recent task " .. i })
  end
  vim.keymap.set("n", "q", function()
    vim.cmd("confirm qall")
  end, { buffer = buf, nowait = true, desc = "Quit icarus" })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = vim.api.nvim_create_augroup("icarus_home", { clear = true }),
    callback = function()
      require("icarus.landing").draw()
    end,
  })
  -- No cursor on home: it has nothing to point at.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, { group = "icarus_home", buffer = buf, callback = function()
    require("icarus.landing").hide_cursor(true)
  end })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, { group = "icarus_home", buffer = buf, callback = function()
    require("icarus.landing").hide_cursor(false)
  end })
  -- Quitting from home leaves the terminal its cursor.
  vim.api.nvim_create_autocmd("VimLeavePre", { group = "icarus_home", callback = function()
    require("icarus.landing").hide_cursor(false)
  end })
  vim.api.nvim_create_autocmd("ColorScheme", { group = "icarus_home", callback = highlights })
  return buf
end

-- Hides the cursor (a cursor shape fully blended away), or puts back the one before.
function M.hide_cursor(hide)
  if hide and not state.guicursor then
    vim.api.nvim_set_hl(0, "IcarusHiddenCursor", { blend = 100, nocombine = true })
    state.guicursor = vim.o.guicursor
    vim.o.guicursor = "a:IcarusHiddenCursor"
  elseif not hide and state.guicursor then
    vim.o.guicursor = state.guicursor
    state.guicursor = nil
  end
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- Draws home across its window, and keeps it moving while it shows.
---@param tick? boolean a frame of the animation, not a new look at the tasks
function M.draw(tick)
  local buf = M.buf()
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return stop()
  end
  if not tick or not state.tasks then
    state.tasks = recent()
  end
  -- The words under the picture, each line centred on itself.
  local words, word_marks = { "", "i c a r u s", "", "n  new chat     t  new task     space f  find a task" },
    { {}, { { 0, -1, "IcarusHomeTitle" } }, {}, { { 0, -1, "IcarusHomeHint" } } }
  if #state.tasks > 0 then
    words[#words + 1] = ""
    word_marks[#word_marks + 1] = {}
    for i, task in ipairs(state.tasks) do
      words[#words + 1] = ("%d  %-28s %s"):format(i, task.title, task.status or "")
      word_marks[#word_marks + 1] = { { 0, 1, "IcarusHomeTitle" }, { 3 + #task.title, -1, "IcarusHomeHint" } }
    end
  end
  local cols, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  local rows = math.max(4, height - #words - 1)
  local art, art_marks = render(cols, rows, state.frame)
  local lines, offsets = {}, {}
  for _, line_ in ipairs(art) do
    lines[#lines + 1] = line_
  end
  for _, text in ipairs(words) do
    local pad = math.max(0, math.floor((cols - vim.fn.strdisplaywidth(text)) / 2))
    offsets[#lines + 1] = pad
    lines[#lines + 1] = (" "):rep(pad) .. text
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for row, runs in ipairs(art_marks) do
    for _, run in ipairs(runs) do
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, run[1], { end_col = run[2], hl_group = "IcarusHomeLevel" .. run[3] })
    end
  end
  for i, marks in ipairs(word_marks) do
    local row = #art + i
    for _, mark in ipairs(marks) do
      local text = lines[row]
      local to = mark[2] == -1 and #text or offsets[row] + mark[2]
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, offsets[row] + mark[1], { end_col = to, hl_group = mark[3] })
    end
  end
  if not state.timer then
    state.timer = assert(vim.uv.new_timer())
    state.timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(function()
      state.frame = state.frame + 1
      require("icarus.landing").draw(true)
    end))
  end
end

-- The field for any window: rows of braille, cols wide, at frame f. The board draws it behind its cards.
M.render = render

return M
