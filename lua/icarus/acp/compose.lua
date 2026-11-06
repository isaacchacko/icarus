-- The composer: where you type to an agent, the last lines of the chat's own buffer, under the
-- conversation, the agent's status line (M.status) and a rule. Both of a chat's buffers end in one (its details and its thread), and the
-- draft lives in whichever shows: M.carry moves it across.
--
-- An extmark holds the composer's start, and everything above it is the conversation. What draws the
-- conversation goes through M.write, which keeps the composer below what it writes; M.start is where
-- the conversation ends. The mark sticks to the line under it (left gravity), so a line you open
-- above the composer's first stays in the composer, and M.write sets it again after writing.
--
-- The conversation can't be edited: 'modifiable' follows whether the cursor is in the composer. That
-- leaves what reaches up from the composer (dk, dgg, a range), which on_lines sees and M.settle undoes.
-- It's the one thing native undo is for here: M.write runs at undolevels -1, as an undo entry holds
-- line numbers and streaming moves the lines, and otherwise a buffer keeps only your last change or
-- two. u and <C-r> are the draft's own history, of its text, so they can't reach the conversation.
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_compose")
local RULE = ("─"):rep(400)
local UNDO_MAX = 200
-- What M.settle needs of native undo: your last change.
local UNDOLEVELS = 1

-- In _G, so a hot reload keeps them: per buffer with a composer, its chat and where the composer is.
_G.icarus_compose = _G.icarus_compose or { views = {} }
local views = _G.icarus_compose.views

---@class icarus.acp.ComposeView
---@field chat table
---@field mark? integer
---@field start integer the composer's first row, as last set; on_lines can't read the mark, a change has moved it by then
---@field below? integer during M.write, how many lines the composer has
---@field status? table[] the status line's {text, hl} parts, drawn above the rule
---@field quiet? boolean it's icarus changing the buffer, not you
---@field breach? boolean an edit reached above the composer

local function pin(view, buf, row)
  row = math.min(row, vim.api.nvim_buf_line_count(buf) - 1)
  view.start = row
  -- The status line is always a line, blank when there's nothing to say, so the draft doesn't jump
  -- when a turn starts or ends.
  local status = view.status and #view.status > 0 and view.status or { { "", "IcarusAcpRule" } }
  view.mark = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { id = view.mark, right_gravity = false,
    virt_lines = { status, { { RULE, "IcarusAcpRule" } } }, virt_lines_above = true })
end

-- The agent's status line above the rule, in both of the chat's buffers.
---@param parts {[1]: string, [2]: string}[]
function M.status(chat, parts)
  for buf, view in pairs(views) do
    if view.chat == chat and vim.api.nvim_buf_is_valid(buf) and view.mark then
      view.status = parts
      pin(view, buf, M.start(buf))
    end
  end
end

-- Runs fn with the buffer writable and out of undo, as icarus's own change.
local function quietly(buf, fn)
  local view = views[buf]
  local modifiable, undolevels, quiet = vim.bo[buf].modifiable, vim.bo[buf].undolevels, view.quiet
  view.quiet = true
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].undolevels = undolevels
  view.quiet = quiet
  if not ok then
    error(err, 0)
  end
end

-- The row the composer starts on, which is where the conversation ends: where a new line of it goes.
function M.start(buf)
  local view = views[buf]
  if not view then
    return vim.api.nvim_buf_line_count(buf)
  end
  if view.below then
    return vim.api.nvim_buf_line_count(buf) - view.below
  end
  return vim.api.nvim_buf_get_extmark_by_id(buf, NS, view.mark, {})[1] or view.start
end

-- The thread's markdown stops where the conversation does. A draft shows as typed, with no marks
-- hidden, and a key typed in it doesn't reparse a long thread: 35ms a key at 5000 lines, 0.3 without.
local function parse_conversation(buf)
  local highlighter = require("vim.treesitter.highlighter").active[buf]
  if highlighter then
    -- It ends before the last line's newline: a region ending where the composer starts grows with
    -- what's typed there.
    local last = M.start(buf) - 1
    local width = #vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
    highlighter.tree:set_included_regions({ { { 0, 0, 0, last, width, vim.api.nvim_buf_get_offset(buf, last) + width } } })
  end
end

-- Changes the conversation with fn, the composer staying under it and the draft untouched.
function M.write(buf, fn)
  local view = views[buf]
  if not view or view.below then
    return fn(buf)
  end
  view.below = vim.api.nvim_buf_line_count(buf) - M.start(buf)
  local ok, err = pcall(quietly, buf, fn)
  local row = vim.api.nvim_buf_line_count(buf) - view.below
  view.below = nil
  pin(view, buf, row)
  parse_conversation(buf)
  if not ok then
    error(err, 0)
  end
end

-- The buffer holding chat's draft.
function M.holder(chat)
  return chat.draft.buf
end

-- The draft's lines in buf.
function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, M.start(buf), -1, false)
end

local function put(buf, lines)
  local row = M.start(buf)
  quietly(buf, function()
    vim.api.nvim_buf_set_lines(buf, row, -1, false, lines)
  end)
  pin(views[buf], buf, row)
end

-- Changes the draft with fn(buf), whatever the cursor is on.
function M.edit(buf, fn)
  quietly(buf, fn)
end

-- Whether row (0-based; the cursor's by default, in the current window) is in the composer.
function M.inside(buf, row)
  row = row or vim.api.nvim_win_get_cursor(0)[1] - 1
  return row >= M.start(buf)
end

-- 'modifiable' follows the cursor of the window you're in.
function M.follow(buf)
  if vim.api.nvim_get_current_buf() == buf and views[buf] then
    local inside = M.inside(buf)
    if vim.bo[buf].modifiable ~= inside then
      vim.bo[buf].modifiable = inside
    end
  end
end

-- Where the cursor is in win's composer, {rows from its first line, col}; nil in the conversation.
function M.cursor(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local start = M.start(buf)
  return row - 1 >= start and { row - 1 - start, col } or nil
end

-- Puts win's cursor in its composer: at (from M.cursor), or at the draft's end.
function M.place(win, at)
  local buf = vim.api.nvim_win_get_buf(win)
  local start, count = M.start(buf), vim.api.nvim_buf_line_count(buf)
  local row = at and math.min(start + at[1], count - 1) or count - 1
  local col = at and at[2] or #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_win_set_cursor(win, { row + 1, col })
  M.follow(buf)
end

-- The draft's history: what it was at each stop, a stop being the end of an insert or a change.
function M.history(chat)
  local draft = chat.draft
  local lines = M.lines(draft.buf)
  if not vim.deep_equal(lines, draft.seen) then
    table.insert(draft.undo, draft.seen)
    if #draft.undo > UNDO_MAX then
      table.remove(draft.undo, 1)
    end
    draft.seen, draft.redo = lines, {}
  end
end

local function restore(chat, lines)
  local buf = chat.draft.buf
  put(buf, lines)
  chat.draft.seen = lines
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    M.place(win)
  end
end

local function step(chat, from, to)
  M.history(chat)
  local draft = chat.draft
  for _ = 1, vim.v.count1 do
    local lines = table.remove(draft[from])
    if not lines then
      break
    end
    table.insert(draft[to], draft.seen)
    restore(chat, lines)
  end
end

function M.undo(chat)
  step(chat, "undo", "redo")
end

function M.redo(chat)
  step(chat, "redo", "undo")
end

-- Sent: an empty composer, with no history to undo into.
function M.clear(chat)
  local draft = chat.draft
  put(draft.buf, { "" })
  draft.undo, draft.redo, draft.seen = {}, {}, { "" }
end

-- Makes the draft lines, as if you'd typed them: a chat opening with one already.
function M.set(chat, lines)
  put(chat.draft.buf, lines)
  chat.draft.seen = lines
end

-- The draft to buf, the buffer about to show.
function M.carry(chat, to)
  local draft = chat.draft
  local from = draft.buf
  if from == to then
    return
  end
  if vim.api.nvim_buf_is_valid(from) and views[from] then
    put(to, M.lines(from))
    put(from, { "" })
  end
  draft.buf = to
  require("icarus.acp.images").refresh(to)
end

-- After a change: an edit that reached the conversation is undone, and the composer always has a line.
function M.settle(buf)
  local view = views[buf]
  if not view then
    return
  end
  if view.breach then
    view.breach, view.quiet = false, true
    -- The cursor may have landed in the conversation, which 'modifiable' has followed.
    vim.bo[buf].modifiable = true
    pcall(vim.cmd, "silent undo")
    view.quiet = false
    pin(view, buf, view.start)
    if vim.api.nvim_get_current_buf() == buf then
      M.place(0)
    end
    vim.notify("The conversation can't be edited", vim.log.levels.WARN)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count <= view.start then
    quietly(buf, function()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
    end)
    pin(view, buf, count)
    if vim.api.nvim_get_current_buf() == buf then
      M.place(0)
    end
  end
  M.follow(buf)
end

function M.on_lines(buf, first)
  local view = views[buf]
  if view and not view.quiet and first < view.start then
    view.breach = true
  end
end

-- An insert can't leave the composer: the arrows and a click stop at its top.
function M.clamp(buf)
  if views[buf] and not M.inside(buf) then
    -- A change reaching up can leave the mark past the last line, until M.settle puts it right.
    vim.api.nvim_win_set_cursor(0, { math.min(M.start(buf) + 1, vim.api.nvim_buf_line_count(buf)), 0 })
  end
end

local function at_start(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return row - 1 <= M.start(buf) and col == 0
end

-- The composer's keys in buf. Again (a hot reload's rebind) they're mapped again.
function M.keys(buf, chat)
  -- A backspace on its very first character would join it to the conversation.
  for _, key in ipairs({ "<BS>", "<C-h>", "<C-w>", "<C-u>" }) do
    vim.keymap.set("i", key, function()
      return at_start(buf) and "" or key
    end, { buffer = buf, expr = true, desc = "Delete, within the composer" })
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
  end
  -- In the conversation there's nothing to undo, and the draft may be off screen.
  for _, lhs in ipairs({ "u", "g-" }) do
    map(lhs, function()
      if M.inside(buf) then
        M.undo(chat)
      end
    end, "Undo in the composer")
  end
  for _, lhs in ipairs({ "<C-r>", "g+" }) do
    map(lhs, function()
      if M.inside(buf) then
        M.redo(chat)
      end
    end, "Redo in the composer")
  end
  -- Its record of a line goes by line number, and the lines move under it.
  map("U", function() end, "Nothing: u undoes in the composer")
end

-- Gives buf a composer, under what it holds. Again, it does nothing.
function M.init(chat, buf)
  if views[buf] then
    return
  end
  local view = { chat = chat, start = vim.api.nvim_buf_line_count(buf) }
  views[buf] = view
  vim.bo[buf].undolevels = UNDOLEVELS
  chat.draft = chat.draft or { buf = buf, undo = {}, redo = {}, seen = { "" } }
  quietly(buf, function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
  end)
  pin(view, buf, view.start)
  parse_conversation(buf)
  vim.api.nvim_buf_attach(buf, false, { on_lines = function(_, changed, _, first)
    require("icarus.acp.compose").on_lines(changed, first)
  end })
  local group = vim.api.nvim_create_augroup("icarus_compose_" .. buf, { clear = true })
  local function on(events, fn)
    vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn })
  end
  on({ "BufEnter", "WinEnter", "CursorMoved" }, function()
    require("icarus.acp.compose").follow(buf)
  end)
  on("CursorMovedI", function()
    require("icarus.acp.compose").clamp(buf)
  end)
  on({ "TextChanged", "TextChangedI" }, function()
    local compose = require("icarus.acp.compose")
    compose.settle(buf)
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" and chat.draft.buf == buf then
      compose.history(chat)
    end
  end)
  on("InsertLeave", function()
    if chat.draft.buf == buf then
      require("icarus.acp.compose").history(chat)
    end
  end)
  on("BufWipeout", function()
    views[buf] = nil
  end)
end

return M
