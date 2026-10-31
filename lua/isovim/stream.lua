-- A chat is a terminal with no process of its own, fed by a tmux control-mode client (`tmux -C`).
-- A tmux client drawing in a terminal redraws one screen in place, so nothing ever scrolls into
-- the buffer; control mode hands over the pane's raw output instead, which scrolls into the
-- buffer like any program's, so normal mode scrolls and searches the whole chat, live.
local panes = require("isovim.panes")

local M = {}

-- nvim's terminal answers the queries in that output (cursor position, device attributes, ...)
-- through the same callback as your keys. tmux already answered them for the pane.
local REPLIES = {
  "\27%[%?[%d;]*c",
  "\27%[>[%d;]*c",
  "\27%[%?[%d;]*%$y",
  "\27%[%d+;%d+R",
  "\27%[%d+n",
  "\27%[%?%d*u",
  "\27P.-\27\\",
  "\27%].-\7",
  "\27%].-\27\\",
}

local function only_replies(data)
  for _, reply in ipairs(REPLIES) do
    data = data:gsub(reply, "")
  end
  return data == ""
end

-- A tmux double-quoted string: control bytes as \ooo; ", \ and $ escaped.
local function quote(data)
  local escaped = data:gsub('[%c"\\$]', function(c)
    if c == '"' or c == "\\" or c == "$" then
      return "\\" .. c
    end
    return ("\\%03o"):format(c:byte())
  end)
  return '"' .. escaped .. '"'
end

-- %output escapes bytes below space, and backslash, as \ooo.
local function unescape(data)
  return (data:gsub("\\([0-7][0-7][0-7])", function(octal)
    return string.char(tonumber(octal, 8))
  end))
end

-- Programs inside tmux (TERM=tmux-256color) set the window name with screen's ESC k ... ESC \,
-- which tmux takes but nvim's terminal prints as text: zsh's prompt shows its title as junk.
local function terminal_output(data)
  return (unescape(data):gsub("\27k.-\27\\", ""))
end

local FLAGS = {
  "alternate_on",
  "cursor_x",
  "cursor_y",
  "cursor_flag",
  "scroll_region_upper",
  "scroll_region_lower",
  "keypad_cursor_flag",
  "keypad_flag",
  "bracket_paste_flag",
  "mouse_standard_flag",
  "mouse_button_flag",
  "mouse_any_flag",
  "mouse_sgr_flag",
}

-- The pane's screen and the modes its program set, as output that puts a fresh terminal in that state.
-- full: lines include the history, which replaces the terminal's; else they're just the screen,
-- redrawn over the history the terminal already holds.
local function replay(pane, lines, full)
  local on = function(flag)
    return pane[flag] == "1"
  end
  local out = { full and "\27c\27[3J" or "\27c" }
  if on("alternate_on") then
    -- The alternate screen has no history; its capture is just the screen.
    out[#out + 1] = "\27[?1049h"
  end
  out[#out + 1] = table.concat(lines, "\r\n")
  local modes = {
    keypad_cursor_flag = "\27[?1h",
    keypad_flag = "\27=",
    bracket_paste_flag = "\27[?2004h",
    mouse_standard_flag = "\27[?1000h",
    mouse_button_flag = "\27[?1002h",
    mouse_any_flag = "\27[?1003h",
    mouse_sgr_flag = "\27[?1006h",
  }
  for flag, set in pairs(modes) do
    if on(flag) then
      out[#out + 1] = set
    end
  end
  out[#out + 1] = ("\27[%d;%dr"):format(tonumber(pane.scroll_region_upper) + 1, tonumber(pane.scroll_region_lower) + 1)
  out[#out + 1] = ("\27[%d;%dH"):format(tonumber(pane.cursor_y) + 1, tonumber(pane.cursor_x) + 1)
  if not on("cursor_flag") then
    out[#out + 1] = "\27[?25l"
  end
  return table.concat(out)
end

-- How much of the pane's history a chat shows; all of it stays in tmux (iso peek, iso attach).
local HISTORY = 10000

-- What nvim sizes the terminal to: the smallest window showing it, less its number/sign columns.
local function term_size(buf)
  local width, height
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    width = math.min(width or math.huge, info.width - info.textoff)
    height = math.min(height or math.huge, info.height)
  end
  return width, height
end

---@class isovim.Stream
---@field job integer
---@field term integer
---@field target string
---@field pending fun(lines?: string[])[][] per command line sent, a handler per command in it
---@field block? string[] lines of the reply being read
---@field partial string
---@field seeding boolean drop output until the screen it follows has been drawn
---@field size? string
---@field seeded_width? integer the width the terminal last got the pane's history at

-- Global so a hot reload keeps the live chats.
_G.isovim_streams = _G.isovim_streams or {}
local streams = _G.isovim_streams ---@type table<integer, isovim.Stream>

-- Each command in the line gets a reply block, in order, until one fails: tmux skips the rest,
-- whose handlers then get nil.
---@param handlers? fun(lines?: string[])[]
local function command(stream, line, handlers)
  table.insert(stream.pending, handlers or { function() end })
  vim.fn.chansend(stream.job, line .. "\n")
end

-- Sizes the pane to the terminal and redraws the terminal from the pane, in one atomic command list.
local function seed(buf)
  local stream = streams[buf]
  local width, height = term_size(buf)
  if not stream or not width then
    return
  end
  stream.size = width .. "x" .. height
  stream.seeding = true
  local formats = vim.tbl_map(function(flag)
    return "#{" .. flag .. "}"
  end, FLAGS)
  -- Replaying history is the slow part (~1s per 50k lines), so it's capped, and a height-only resize
  -- redraws just the screen: the terminal and tmux both move rows between screen and history alike.
  -- A width change can't: tmux reflows the history while the terminal truncates it.
  local pane
  local full = stream.seeded_width ~= width
  local line = ("refresh-client -C %s ; display -p -t %s %s ; capture-pane -p -e %s -t %s"):format(
    stream.size,
    stream.target,
    quote(table.concat(formats, " ")),
    full and ("-S -" .. HISTORY) or "",
    stream.target
  )
  command(stream, line, {
    function() end,
    function(lines)
      local values = vim.split(lines and lines[1] or "", " ")
      if #values == #FLAGS then
        pane = {}
        for i, flag in ipairs(FLAGS) do
          pane[flag] = values[i]
        end
      end
    end,
    function(lines)
      stream.seeding = false
      if not lines or not pane then
        return
      end
      vim.api.nvim_chan_send(stream.term, replay(pane, lines, full))
      stream.seeded_width = width
      -- The terminal draws on its next refresh. With the cursor on the last line, the window
      -- follows new output in normal mode too.
      vim.defer_fn(function()
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
        end
      end, 50)
    end,
  })
end

-- Not every resize fires an event (bufferline hiding the tab line doesn't), so the chat's own
-- output checks too.
local function fit(buf)
  local width, height = term_size(buf)
  if width and width .. "x" .. height ~= streams[buf].size and not streams[buf].seeding and M.alive(buf) then
    seed(buf)
  end
end

local function on_line(buf, line)
  local stream = streams[buf]
  if stream.block then
    if line:match("^%%end ") or line:match("^%%error ") then
      local lines = stream.block
      stream.block = nil
      local handlers = stream.pending[1]
      table.remove(handlers, 1)(lines)
      if line:match("^%%error ") then
        for _, skipped in ipairs(handlers) do
          skipped(nil)
        end
        handlers = {}
      end
      if #handlers == 0 then
        table.remove(stream.pending, 1)
      end
    else
      table.insert(stream.block, line)
    end
    return
  end
  local data = line:match("^%%output %%%d+ (.*)$")
  if data then
    if not stream.seeding then
      vim.api.nvim_chan_send(stream.term, terminal_output(data))
    end
  elseif line:match("^%%begin %d+ %d+ 1$") then
    stream.block = {}
  elseif line:match("^%%layout%-change ") then
    -- The pane was resized, e.g. a phone attached or left: see if the chat still matches.
    vim.defer_fn(function()
      M.check(buf)
    end, 300)
  end
end

-- A chunk of the control client's stdout: whole lines, the last one possibly cut short.
function M.output(buf, data)
  local stream = streams[buf]
  data[1] = stream.partial .. data[1]
  stream.partial = table.remove(data)
  for _, line in ipairs(data) do
    on_line(buf, line)
  end
  fit(buf)
end

-- Whatever leaves a chat drawn differently from its pane (a race, a size change no event reported,
-- a glyph tmux and nvim measure differently), a quiet moment puts it right: the screen is compared
-- with the pane's and, if they differ, redrawn from it. Each repair goes to run/stream-heals.log,
-- with both screens, to find what drifted.
local function heal_log(buf, stream, pane, mine)
  local log = require("isovim.store").run .. "/stream-heals.log"
  local file = io.open(log, "a")
  if not file then
    return
  end
  file:write(("%s %s size=%s win=%s\n--- pane\n%s\n--- chat\n%s\n\n"):format(
    os.date("%F %T"),
    stream.target,
    stream.size,
    vim.inspect({ term_size(buf) }),
    table.concat(pane, "\n"),
    table.concat(mine, "\n")
  ))
  file:close()
end

function M.check(buf)
  local stream = streams[buf]
  local width, height = term_size(buf)
  if not stream or stream.seeding or not width or not M.alive(buf) then
    return
  end
  -- While another client (iso attach, a phone) has sized the pane its way, leave it be: redrawing
  -- would size it back and the two would fight. Its detach resizes the pane, which checks again.
  local pane_size, clients
  local line = ("display -p -t %s %s ; list-clients -F %s ; capture-pane -p -t %s"):format(
    stream.target,
    quote("#{pane_width}x#{pane_height}"),
    quote("#{client_name} #{session_name} #{client_width}x#{client_height} control=#{client_control_mode}"),
    stream.target
  )
  command(stream, line, {
    function(lines)
      pane_size = lines and lines[1]
    end,
    function(lines)
      clients = lines
    end,
    function(lines)
      if not lines or streams[buf] ~= stream or stream.seeding or not vim.api.nvim_buf_is_valid(buf) then
        return
      elseif pane_size ~= stream.size then
        -- Logged once per mismatch, with who's attached: a pane sized other than asked is how a
        -- chat ends up a column off.
        local key = pane_size .. "/" .. stream.size
        if stream.mismatch ~= key then
          stream.mismatch = key
          heal_log(buf, stream, { "pane is " .. tostring(pane_size) .. ", not healed", unpack(clients or {}) }, {})
        end
        return
      end
      stream.mismatch = nil
      local function trimmed(list)
        local out = vim.tbl_map(function(line)
          return (line:gsub("%s+$", ""))
        end, list)
        while #out > 0 and out[#out] == "" do
          table.remove(out)
        end
        return out
      end
      local pane = trimmed(lines)
      local count = vim.api.nvim_buf_line_count(buf)
      local mine = trimmed(vim.api.nvim_buf_get_lines(buf, math.max(0, count - #lines), count, false))
      if not vim.deep_equal(pane, mine) then
        heal_log(buf, stream, pane, mine)
        seed(buf)
      end
    end,
  })
end

---@return boolean
function M.alive(buf)
  local stream = streams[buf]
  return stream ~= nil and vim.fn.jobwait({ stream.job }, 0)[1] == -1
end

-- Types into the chat, as the terminal would.
function M.send(buf, data)
  local stream = streams[buf]
  if stream and M.alive(buf) then
    command(stream, ("send-keys -l -t %s -- %s"):format(stream.target, quote(data)))
  end
end

-- Turns buf, shown in a window, into the live chat of the agent's tmux session.
function M.attach(buf, ws, agent)
  local term = vim.api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      if not only_replies(data) then
        M.send(buf, data)
      end
    end,
  })
  vim.bo[buf].scrollback = 100000
  local stream = { term = term, target = panes.target(ws, agent), pending = {}, partial = "", seeding = true }
  stream.job = vim.fn.jobstart(panes.control_cmd(ws, agent), {
    -- Through require, so after a hot reload every open chat runs the new code, not just new ones.
    on_stdout = function(_, data)
      if streams[buf] == stream then
        require("isovim.stream").output(buf, data)
      end
    end,
    on_exit = function()
      if streams[buf] == stream and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_chan_send(term, "\r\n[stopped]")
      end
    end,
  })
  streams[buf] = stream
  seed(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      streams[buf] = nil
      vim.fn.jobstop(stream.job)
    end,
  })
end

-- The pane follows the terminal's size; a resize redraws from the pane.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter", "TermEnter" }, {
  group = vim.api.nvim_create_augroup("isovim_stream", { clear = true }),
  callback = function()
    for buf in pairs(streams) do
      fit(buf)
    end
  end,
})

return M
