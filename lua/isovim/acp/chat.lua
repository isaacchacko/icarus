-- An ACP agent's chat: one buffer, the conversation drawn from its journal (isovim.acp.journal) to
-- look like Claude's screen, and under it the composer, the lines you type, whose text goes to the
-- agent's supervisor over its socket when sent, so nothing an agent sends ever lands in what you're
-- typing. The TUI and iso attach (isovim.acp.attach) both show it.
--
-- Where entries come from: the journal is replayed from the start and then followed, so closing
-- and reopening rebuilds the chat as it was; and the chat subscribes to the supervisor, which
-- pushes each entry as it journals it (M.push), so the agent's text streams token by token without
-- waiting on the filesystem. Entries are taken in seq order, once each, whichever way they came.
--
-- What it looks like, as Claude Code draws its screen (isovim.acp.look has the words, the colors
-- for dark and light backgrounds and the rows under a tool call):
--   ❯ your prompt          on Claude's gray band (and messages from iso send/msg)
--   ● the agent's text     streamed in place (⏺ on macOS), its `code` and **bold** drawn
--   ● Update(app.py)       one line per tool call, as Claude names it, rewritten in place; its
--     ⎿  Added 1 line…     bullet colored by status. Under ⎿ what came back: a diff numbered and
--          1  code         colored, a read's line count, a command's first lines then "… +N
--     … +37 lines          lines"; za opens or collapses any of it
--   ✻ Thought for 3s       the agent's thinking, collapsed until za
--   ─ Bash command ─       a permission or question waiting on you, as Claude's numbered box:
--      1. Yes              its number and <CR> in the composer, or <CR> on an option, answers it;
--      2. No               once answered the box gives way to what was decided
--   ✻ Brewed for 8s        the turn's summary
-- Everything drawn is a pure function of the journal's entries, so a replay draws what live drew.
-- The glyphs are text, so wrapping, search and yanks work in any window; colors, the tool
-- call places and the message marks are extmarks. Long lines wrap under their text (breakindent),
-- never sideways. Collapsing is the chat's own (a call's output is left out of the buffer until
-- opened), not nvim's folds, which nvim doesn't update while you type in the composer; so it holds
-- in every window and in iso attach, and needs no window state.
--
-- The composer is the buffer's last lines (from chat.lines, the conversation's count, on), drawn
-- as Claude's prompt: above it a blank line, its bar (Claude's spinner line while the agent works:
-- glyph, verb, time, tokens, <C-c> to interrupt; how many prompts wait) and a rule; ❯ before its
-- first line; a rule and a hint under it; all virtual text. It's the one place you can change:
-- the buffer is modifiable only while the cursor (and, in visual mode, the selection's other end)
-- is in the composer, so dd, x or p on the conversation is refused as in any read-only buffer, and
-- the keys that start typing (i a o O I A c s C S R gi gI, and c s C S R I A on a selection) take
-- you from the conversation to the end of your draft, typing. A change that still reaches the
-- conversation (dk from the composer's first line, :%s) is caught as it happens (on_bytes) and the
-- chat is drawn again from its journal, the draft as it was before that change. The conversation
-- streams in above the composer, which moves down under your cursor without moving it in your
-- text. nvim's undo records rows, which that would throw off, so the buffer has none: the draft's
-- own states are kept (one per change in normal mode, one per insert) and u <C-r> step through
-- them, so u undoes your typing and never the conversation.
--
-- The view follows new output in a window that shows the buffer's end (the composer's hint, under
-- the last row of its last line however many rows that wraps over), keeping it on the window's
-- bottom row, so the conversation's end sits right above the composer; in the window you're in,
-- only while its cursor is in the composer. One scrolled up, or whose cursor you moved up into the
-- conversation, stays where it is, its winbar showing the composer's bar and "↓ more below" until
-- it shows the end again; sending a prompt or an answer takes every window to the end. While
-- prompts wait, the queue shows in a window of its own under the chat's (isovim.acp.queue), where
-- you can edit it.
--
-- Keys, anywhere in the buffer: ]] [[ your own prompts, ]m [m any message, za zo zc the output of
-- the tool call under the cursor, <C-o> every tool call's and thought's (open while any is
-- collapsed, else collapse; those to come follow it), gf the file on the line, <C-c> cancels the
-- turn (or drops a rewind), u <C-r> your draft's undo and redo. On the conversation, <CR> answers with the box option
-- under the cursor, else goes to the composer; in the composer it sends (queued while the agent
-- works; an answer while a box waits on you), in insert mode too, where <S-CR> (or <M-CR>) is a new
-- line, <Up> <Down> your earlier prompts while it's empty, <C-v> pastes an image
-- (isovim.acp.images). <C-j> and <C-k> walk the column: from the conversation down to the
-- composer, from the composer down to the queue (while it shows) and up to the conversation's
-- end. <C-h> goes to the sidebar, in insert mode too (<BS> is the backspace; <C-l> there comes back
-- typing). <leader>iq goes to the queue, opening it even when empty.
--
-- Sessions: /new and /clear start a new session, /resume picks one the agent had (the history
-- picker; /resume <id> goes straight there), /fork [name] forks the agent whole into a new one;
-- every other /command goes to the agent. <leader>iu puts your prompt under the cursor into the
-- composer to edit, and sending it rewinds there (the bar says so; <C-c> drops it); <leader>if
-- forks the agent at the message under the cursor (isovim.acp.host does the rest).
local acp = require("isovim.acp")
local journal = require("isovim.acp.journal")
local look = require("isovim.acp.look")
local queue = require("isovim.acp.queue")
local images = require("isovim.acp.images")
local safe = require("isovim.safe")
local store = require("isovim.store")
local threads = require("isovim.threads")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_acp_chat")
-- Places: tool calls (with their output's extent) and messages, apart from highlights.
local TOOLS = vim.api.nvim_create_namespace("isovim_acp_tools")
local MESSAGES = vim.api.nvim_create_namespace("isovim_acp_messages")
local MINE = vim.api.nvim_create_namespace("isovim_acp_mine")
-- Markdown's marks in the agent's text; the boxes waiting on you, and their options.
local MD = vim.api.nvim_create_namespace("isovim_acp_markdown")
local BOXES = vim.api.nvim_create_namespace("isovim_acp_boxes")
local OPTIONS = vim.api.nvim_create_namespace("isovim_acp_options")

M.ns = { hl = NS, tools = TOOLS, messages = MESSAGES, mine = MINE, md = MD, boxes = BOXES, options = OPTIONS }

---@class isovim.acp.ToolCall
---@field mark integer
---@field title string
---@field status string
---@field items table[] its ACP content
---@field terminal table<string, string> terminal id -> output so far
---@field exit? integer
---@field body integer how many lines of output it has under it
---@field open? boolean opened (za) or collapsed by you; nil: as <C-o> last set them all, else as it shows by default (a diff open)
---@field more integer how many lines of output are left out while it's collapsed
---@field can_open? boolean it has output to show
---@field tool? string the tool's own name (_meta.claudeCode.toolName)
---@field kind? string ACP's kind of tool (read, edit, execute…)
---@field input? table its arguments (rawInput)
---@field locations? table[] the files it touches, with the line its diff starts at
---@field response? table what the tool returned (_meta.claudeCode.toolResponse)
---@field hidden? boolean drawn another way (AskUserQuestion's box, TodoWrite's plan)
---@field thought? boolean a thought, not a tool call: text is what it thought, secs how long

---@class isovim.acp.Chat
---@field ws string
---@field agent string
---@field buf integer the conversation, then the composer
---@field lines integer how many lines the conversation has: the composer starts on the next
---@field last string the conversation's last line as drawn, for the guard
---@field edit_from? integer while the conversation is being drawn: the buffer's line count before
---@field undo {states: string[][], at: integer} the composer's states, for u and <C-r>
---@field dead? boolean made again (a hot reload, a repair) or closed: its buffer's callbacks let go
---@field broken? boolean a change reached the conversation: it's being drawn again
---@field tick? integer the buffer's changedtick after the drawing's last change
---@field stop fun()
---@field drain fun()
---@field seq integer the last entry drawn
---@field fresh boolean nothing drawn yet: its first line is a placeholder
---@field block? "agent"|"thought"|"other" what the last block is: streaming text or thought, or anything else
---@field block_row? integer the first row of the streaming block
---@field thought? isovim.acp.ToolCall the thought streaming in
---@field boxes isovim.acp.Box[] permissions and questions waiting on you
---@field options table<integer, table> a box's options by their extmark (OPTIONS), for <CR> on one
---@field turn_chars? integer how much the running turn has streamed, for the spinner's tokens
---@field verb? string the running turn's spinner verb
---@field at_start? boolean the streaming block has no text yet
---@field tools table<string, isovim.acp.ToolCall>
---@field queue {id: string, text: string}[] prompts waiting, as the queue window shows them
---@field history string[] your prompts, oldest first, for <Up>/<Down> in the composer
---@field history_images table<string, isovim.acp.Image[]> the images of those that had any, by text
---@field recall? integer which of them the composer shows
---@field busy boolean
---@field since? number when the running turn started
---@field handover boolean the session is on Claude's own screen (iso handover)
---@field all_open? boolean <C-o>'s choice, for every call you haven't opened or collapsed yourself, those to come too
---@field chan? integer the subscription to the supervisor
---@field timer? uv.uv_timer_t

-- Live in _G so a hot reload keeps the chats the old code opened.
_G.isovim_acp_chats = _G.isovim_acp_chats or {} ---@type table<string, isovim.acp.Chat>
local chats = _G.isovim_acp_chats

local RENDER = {}

local DOT = look.DOT
local GLYPH = { message = DOT, thought = "✻", result = "⎿", prompt = "❯" }
local FIRST, REST = look.FIRST, look.REST

local STATUS_HL = {
  pending = "IsovimAcpToolPending",
  in_progress = "IsovimAcpToolRunning",
  completed = "IsovimAcpToolDone",
  failed = "IsovimAcpToolFailed",
}

M.highlights = look.highlights
M.dot = DOT

M.highlights()
vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, {
  group = vim.api.nvim_create_augroup("isovim_acp_chat_hl", { clear = true }),
  pattern = { "*", "background" },
  callback = safe.wrap("the chat's colors", function(ev)
    if ev.event == "OptionSet" and ev.match ~= "background" then
      return
    end
    look.highlights()
  end),
})

local function key(ws, agent)
  return ws .. "/" .. agent
end

local function by_buf(buf)
  for _, chat in pairs(chats) do
    if chat.buf == buf then
      return chat
    end
  end
end

local update_bar, decorate

-- The row after the last line of the conversation: the composer's first. While the conversation is
-- being drawn (edit), counted from the buffer, which only the drawing changes meanwhile.
local function body_end(chat)
  if chat.edit_from then
    return chat.lines + vim.api.nvim_buf_line_count(chat.buf) - chat.edit_from
  end
  return chat.lines
end

-- Whether win's cursor (the current window's by default) is in the composer.
local function in_draft(chat, win)
  return vim.api.nvim_win_get_cursor(win or 0)[1] > chat.lines
end

-- The rows win shows text in: its height but its winbar.
function M.text_rows(win)
  local info = vim.fn.getwininfo(win)[1]
  return info and info.height or vim.api.nvim_win_get_height(win)
end

-- Whether win can be measured and followed: it's open, has rows, and shows a loaded buffer (buf,
-- if given) with lines in it. A restart, a hot reload's rebind or a closed tab can leave a
-- follow or a redraw scheduled for a window that's gone or a buffer that was swapped or unloaded
-- (an unloaded buffer counts 0 lines), and measuring that raised from a scheduled callback.
local function measurable(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local shown = vim.api.nvim_win_get_buf(win)
  return (buf == nil or shown == buf) and vim.api.nvim_buf_is_loaded(shown) and vim.api.nvim_buf_line_count(shown) > 0
    and vim.api.nvim_win_get_height(win) > 0
end

-- The rows from win's top to its buffer's end, filler lines in (the composer's rule and hint under
-- its last line too); more than its height while the end is below it. Lines alone don't say: a
-- long line wraps over many rows, and its last ones can be below the window while its start is on
-- screen. nil for a window it can't measure. Counting stops a little past the window's height:
-- callers only ask whether the end is on screen (or a wheel step below it), and measuring a long
-- chat from its top on every streamed update spun the TUI.
function M.rows_to_end(win)
  if not measurable(win) then
    return nil
  end
  local ok, rows = pcall(function()
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    local cap = vim.api.nvim_win_get_height(win) + 100
    return view.topfill
      + vim.api.nvim_win_text_height(win, { start_row = view.topline - 1, start_vcol = view.skipcol, max_height = cap }).all
  end)
  return ok and rows or nil
end

local function shows_end(win)
  local rows = M.rows_to_end(win)
  return rows ~= nil and rows <= M.text_rows(win)
end

-- The view of win with its buffer's end on its bottom row (the virtual lines under the last line,
-- the composer's rule and hint, the last of it): up from there, whole lines while they fit, then
-- the rows of the next that do (smoothscroll's skipcol) or of the filler above it.
local function end_view(win)
  local row = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - 1
  local below = vim.api.nvim_win_text_height(win, { start_row = row }).all
    - vim.api.nvim_win_text_height(win, { start_row = row, end_row = row }).all
  local left = math.max(1, M.text_rows(win) - below)
  local fill = 0
  while row >= 0 do
    local text = vim.api.nvim_win_text_height(win, { start_row = row, end_row = row, start_vcol = 0 }).all
    if text >= left then
      local skip = text - left
      local skipcol = skip > 0
          and vim.api.nvim_win_text_height(win, { start_row = row, end_row = row, start_vcol = 0, max_height = skip }).end_vcol
        or 0
      return { topline = row + 1, skipcol = skipcol, topfill = 0 }
    end
    fill = vim.api.nvim_win_text_height(win, { start_row = row, end_row = row }).all - text
    if text + fill >= left then
      return { topline = row + 1, skipcol = 0, topfill = left - text }
    end
    left = left - text - fill
    row = row - 1
  end
  return { topline = 1, skipcol = 0, topfill = fill }
end

-- end_view, or nil for a window it can't measure.
function M.end_view(win)
  if not measurable(win) then
    return nil
  end
  local ok, view = pcall(end_view, win)
  return ok and view or nil
end

-- Windows that keep following the chat's end: those that show it, the one you're in only while its
-- cursor is in the composer (moving it up into the conversation, to read or za a tool call, stops it).
local function followers(chat)
  local current = vim.api.nvim_get_current_win()
  return vim.tbl_filter(function(win)
    return measurable(win, chat.buf) and shows_end(win) and (win ~= current or in_draft(chat, win))
  end, vim.fn.win_findbuf(chat.buf))
end

-- Puts the buffer's end on win's bottom row: the composer at the bottom, the conversation's end
-- right above it. Set here: nvim keeps only the cursor's row on screen, and in a window that isn't
-- current may not move its view at all. A cursor in the composer stays where it is in your text;
-- one up in the conversation goes to the composer's end, or nvim would scroll back to it. A window
-- that went away, or shows something else now, stops following.
local function to_end(win)
  local view = M.end_view(win)
  if not view then
    if vim.api.nvim_win_is_valid(win) then
      vim.w[win].isovim_follows = false
    end
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local chat = by_buf(buf)
  if not (chat and in_draft(chat, win)) then
    view.lnum = vim.api.nvim_buf_line_count(buf)
    view.col = #vim.api.nvim_buf_get_lines(buf, view.lnum - 1, view.lnum, false)[1]
  end
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end)
  vim.w[win].isovim_follows = true
end

-- A window that follows keeps the end on its bottom row when it changes size: the queue's window
-- opening under it takes its rows.
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("isovim_acp_chat_follow", { clear = true }),
  callback = safe.wrap("the chat's follow on a resize", function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      local chat = vim.api.nvim_win_is_valid(win) and vim.w[win].isovim_follows and by_buf(vim.api.nvim_win_get_buf(win))
      if chat then
        pcall(to_end, win)
      end
    end
  end),
})

-- Records which windows follow (for a resize), as you move or scroll them.
local function note_followers(chat)
  local follow = followers(chat)
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    vim.w[win].isovim_follows = vim.tbl_contains(follow, win)
  end
end

-- Notes which windows showing the chat don't show its end, so the composer (and its bar) is out of
-- sight there: their winbar shows the bar instead (update_bar).
local function set_unseen(chat)
  local changed = false
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    local unseen = measurable(win, chat.buf) and not shows_end(win)
    if vim.w[win].isovim_unseen ~= unseen then
      vim.w[win].isovim_unseen = unseen
      changed = true
    end
  end
  if changed then
    update_bar(chat)
  end
end

-- You sent something: every window showing the chat goes to its end and follows it again.
local function to_bottom(chat)
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    pcall(to_end, win)
  end
  set_unseen(chat)
end

-- Runs fn with the buffer modifiable, as it is only while your cursor is in the composer.
local function writable(buf, fn)
  local was = vim.bo[buf].modifiable
  -- Already (a batch is): setting an option fires OptionSet, and a batch edits thousands of times.
  if was then
    return fn()
  end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = was
  if not ok then
    error(err, 0)
  end
end

-- Changes the conversation with fn, which writes only above the composer (from body_end up). The
-- composer moves down with what's added, your cursor in it too; nothing it changes is recorded for
-- undo, and the guard lets it be. Windows at the bottom stay there.
local function edit(chat, fn)
  local buf = chat.buf
  if chat.edit_from then
    return fn(buf)
  end
  local follow = not chat.batch and followers(chat)
  chat.edit_from = vim.api.nvim_buf_line_count(buf)
  local ok, err = pcall(writable, buf, function()
    fn(buf)
  end)
  chat.lines, chat.edit_from = body_end(chat), nil
  chat.last = vim.api.nvim_buf_get_lines(buf, chat.lines - 1, chat.lines, false)[1] or ""
  chat.tick = vim.api.nvim_buf_get_changedtick(buf)
  if not ok then
    error(err, 0)
  end
  if chat.batch then
    return
  end
  decorate(chat)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.tbl_contains(follow, win) then
      pcall(to_end, win)
    else
      vim.w[win].isovim_follows = false
    end
  end
  set_unseen(chat)
end

-- Draws what fn adds as one batch: the windows that followed go to the end once, after it, rather
-- than every window being measured after every entry. A journal read from the start (a chat made,
-- or made again by a hot reload) is thousands of entries, and measuring each took a reload of a
-- long chat many seconds, the TUI frozen meanwhile.
local function batch(chat, fn)
  if chat.batch or not vim.api.nvim_buf_is_loaded(chat.buf) then
    return fn()
  end
  local follow = followers(chat)
  chat.batch = true
  local ok, err = pcall(writable, chat.buf, fn)
  chat.batch = false
  decorate(chat)
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    if vim.tbl_contains(follow, win) then
      pcall(to_end, win)
    else
      vim.w[win].isovim_follows = false
    end
  end
  set_unseen(chat)
  update_bar(chat)
  if not ok then
    error(err, 0)
  end
end

local function line_hl(buf, row, count, hl)
  for i = 0, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = hl })
  end
end

local function span(buf, row, col, end_col, hl, priority)
  vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_col = end_col, hl_group = hl, priority = priority })
end

-- A highlight from col to the end of the line and on to the window's edge, as Claude colors a
-- diff's lines.
local function eol_hl(buf, row, col, hl)
  vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_row = row + 1, end_col = 0, hl_group = hl, hl_eol = true,
    priority = 100 })
end

-- Adds whole lines at the end of the conversation; returns the first one's row.
local draw_tables

local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
    -- The agent's message ends here: a table it ended on is whole, its last line's links too.
    if chat.block == "agent" then
      draw_tables(chat, true)
      require("isovim.links").substitute(buf, body_end(chat) - 1, body_end(chat), function(write)
        write()
      end)
    end
    row = chat.fresh and 0 or body_end(chat)
    vim.api.nvim_buf_set_lines(buf, row, chat.fresh and 1 or row, false, lines)
    if hl then
      line_hl(buf, row, #lines, hl)
    end
  end)
  chat.fresh = false
  chat.block = "other"
  return row
end

-- A new block: a blank line between it and the one before. Returns its first line's row.
local function add_block(chat, lines, hl)
  local first = chat.fresh
  local row = add_lines(chat, first and lines or { "", unpack(lines) })
  row = first and row or row + 1
  if hl then
    line_hl(chat.buf, row, #lines, hl)
  end
  return row
end

-- Every message's first line is marked, and your own prompts' again in MINE, for ]] [[ and ]m [m;
-- each mark knows the journal entry that began the message, for a fork or a rewind there.
local function mark_message(chat, row, mine)
  local id = vim.api.nvim_buf_set_extmark(chat.buf, MESSAGES, row, 0, {})
  local entry = chat.entry or {}
  chat.marks[id] = { seq = entry.seq, kind = entry.kind, id = entry.id, text = entry.text, mine = mine }
  if mine then
    vim.api.nvim_buf_set_extmark(chat.buf, MINE, row, 0, {})
  end
end

-- The agent's dir as paths in its tool calls start, for showing them short.
local function dirs(chat)
  if not chat.dirs then
    local dir = store.agent_dir(chat.ws, chat.agent)
    chat.dirs = { dir, vim.uv.fs_realpath(dir) or dir }
  end
  return chat.dirs
end

-- Markdown's marks on rows from..to (0-based, inclusive) of the agent's text.
local function markup(chat, from, to)
  local buf = chat.buf
  vim.api.nvim_buf_clear_namespace(buf, MD, from, to + 1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, from, to + 1, false)) do
    local spans, conceals = look.markdown(line)
    for _, s in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(buf, MD, from + row - 1, s[1], { end_col = s[2], hl_group = s[3] })
    end
    for _, c in ipairs(conceals) do
      vim.api.nvim_buf_set_extmark(buf, MD, from + row - 1, c[1], { end_col = c[2], conceal = "" })
    end
  end
end

-- How wide a table may be drawn: the text width of the widest window showing a chat (this one's
-- first), less the message's indent; 100 with none on screen.
local function table_width(chat)
  local wins = vim.fn.win_findbuf(chat.buf)
  if #wins == 0 then
    wins = vim.tbl_filter(function(win)
      return vim.b[vim.api.nvim_win_get_buf(win)].isovim_acp == true
    end, vim.api.nvim_tabpage_list_wins(0))
  end
  local width = 0
  for _, win in ipairs(wins) do
    width = math.max(width, vim.api.nvim_win_get_width(win))
  end
  return (width > 0 and width or 102) - 2
end

-- Draws the tables in the streaming message whose lines have all come (look.table): a table is
-- whole once a line that isn't one of its rows follows it, or the message ends (whole). Until then
-- it shows as the agent wrote it. chat.table_scan is where to look from: the lines above it hold
-- no table still to draw. Runs inside edit.
draw_tables = function(chat, whole)
  local buf = chat.buf
  local last = body_end(chat) - (whole and 1 or 2)
  local row = math.max(chat.table_scan or chat.block_row, chat.block_row)
  local prefix = function(line)
    return vim.startswith(line, GLYPH.message .. " ") and GLYPH.message .. " " or "  "
  end
  while row <= last do
    local lines = vim.api.nvim_buf_get_lines(buf, row, last + 1, false)
    local function text(i)
      local line = lines[i]
      return line and line:sub(#prefix(line) + 1)
    end
    if not look.table_row(text(1)) then
      row = row + 1
    elseif not text(2) then
      break
    elseif not look.table_alignments(text(2)) then
      row = row + 1
    else
      local n = 3
      while text(n) and look.table_row(text(n)) do
        n = n + 1
      end
      if not text(n) and not whole then
        break
      end
      local rows = {}
      for i = 1, n - 1 do
        rows[i] = text(i)
      end
      local drawn, spans = look.table(rows, table_width(chat))
      local first = prefix(lines[1])
      for i, line in ipairs(drawn) do
        drawn[i] = (i == 1 and first or "  ") .. line
      end
      vim.api.nvim_buf_clear_namespace(buf, NS, row, row + n - 1)
      vim.api.nvim_buf_clear_namespace(buf, MD, row, row + n - 1)
      vim.api.nvim_buf_set_lines(buf, row, row + n - 1, false, drawn)
      if first ~= "  " then
        span(buf, row, 0, #GLYPH.message, "IsovimAcpMessage")
      end
      -- Its cells' markdown is drawn by look.table, its marks taken out: markup has none to find.
      for _, s in ipairs(spans) do
        span(buf, row + s[1], #(s[1] == 0 and first or "  ") + s[2], #(s[1] == 0 and first or "  ") + s[3], s[4], 120)
      end
      last = last + #drawn - (n - 1)
      row = row + #drawn
    end
  end
  chat.table_scan = row
end

-- Streams the agent's text onto the end of the conversation, a new message after anything else;
-- its lines after the first are indented under the glyph.
local function add_text(chat, text)
  if chat.block ~= "agent" then
    local row = add_block(chat, { GLYPH.message .. " " })
    span(chat.buf, row, 0, #GLYPH.message, "IsovimAcpMessage")
    mark_message(chat, row, false)
    chat.block, chat.block_row, chat.at_start, chat.table_scan = "agent", row, true, row
  end
  if chat.at_start then
    text = text:gsub("^\n+", "")
    if text == "" then
      return
    end
    chat.at_start = false
  end
  chat.turn_chars = (chat.turn_chars or 0) + #text
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  local from
  edit(chat, function(buf)
    local row = body_end(chat) - 1
    from = row
    local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
    vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
    markup(chat, from, body_end(chat) - 1)
    if #parts > 1 then
      draw_tables(chat, false)
      -- Its lines that have all come: their iso: addresses as chips (isovim.links). The one still
      -- streaming waits, an address in it maybe cut by a chunk.
      require("isovim.links").substitute(buf, from, body_end(chat) - 1, function(write)
        write()
      end)
    end
  end)
end

-- Tool calls, thinking: blocks drawn in place, whose output collapses (za)

---@param call isovim.acp.ToolCall
local function is_open(chat, call, kind, count)
  if call.open ~= nil then
    return call.open
  elseif chat.all_open ~= nil then
    return chat.all_open
  end
  return look.open_by_default(kind, count)
end

-- The rows under a thought: its text, dimmed, under the ✻.
local function thought_rows(call)
  local rows = {}
  local text = (call.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text ~= "" then
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      rows[#rows + 1] = { line, hl = "IsovimAcpThought" }
    end
  end
  return rows
end

-- Draws a tool call's (or a thought's) line and what's under it in place: all of it when it's
-- open, else what shows collapsed and a line saying how much more there is.
---@param call isovim.acp.ToolCall
local function draw_tool(chat, call)
  local row = call.mark and vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if not row then
    return
  end
  local header, spans = "", {}
  local rows, kind
  if call.thought then
    header = GLYPH.thought .. " " .. (call.secs and ("Thought for " .. look.duration(call.secs)) or "Thinking…")
    spans[1] = { 0, #header, "IsovimAcpThought" }
    rows, kind = thought_rows(call), "thought"
  else
    local name, args = look.header(call, dirs(chat))
    header = GLYPH.message .. " " .. name .. (args and ("(" .. args .. ")") or "")
    spans[1] = { 0, #GLYPH.message, STATUS_HL[call.status] or "IsovimAcpToolPending" }
    spans[2] = { #GLYPH.message + 1, #GLYPH.message + 1 + #name, "IsovimAcpToolTitle" }
    rows, kind = look.body(call, dirs(chat))
  end
  local open = is_open(chat, call, kind, #rows)
  local shown = rows
  call.more = 0
  if not open then
    local count = kind == "thought" and 0 or look.collapsed_count(kind, #rows)
    if #rows > count then
      shown = vim.list_slice(rows, 1, count)
      call.more = #rows - count
      -- A read says its count already; the rest say how many lines are left out.
      if kind ~= "read" and kind ~= "thought" then
        shown[#shown + 1] = { ("… +%s (za to expand)"):format(look.plural(call.more, "line")), hl = "IsovimAcpResultNote",
          note = true }
      end
    end
  end
  call.can_open = #rows > 0
  local lines = { header }
  local indent = call.thought and "  " or nil
  for i, r in ipairs(shown) do
    lines[#lines + 1] = (indent or (i == 1 and FIRST or REST)) .. r[1]
  end
  edit(chat, function(buf)
    local replaced = row + 1 + call.body
    vim.api.nvim_buf_clear_namespace(buf, NS, row, replaced)
    vim.api.nvim_buf_set_lines(buf, row, replaced, false, lines)
    for _, s in ipairs(spans) do
      span(buf, row, s[1], s[2], s[3])
    end
    local hint = call.more > 0 and (kind == "read" or kind == "thought") and "  (za to expand)" or nil
    if hint then
      vim.api.nvim_buf_set_extmark(buf, NS, kind == "thought" and row or row + 1, 0,
        { virt_text = { { hint, "IsovimAcpNotice" } } })
    end
    for i, r in ipairs(shown) do
      local at = row + i
      local pre = indent and #indent or #(i == 1 and FIRST or REST)
      if not indent and i == 1 then
        span(buf, at, 0, pre, "IsovimAcpResultGlyph")
      end
      if r.hl == "IsovimAcpDiffAdd" or r.hl == "IsovimAcpDiffDelete" then
        eol_hl(buf, at, pre, r.hl)
      elseif r.hl then
        span(buf, at, pre, #lines[i + 1], r.hl)
      else
        span(buf, at, pre, #lines[i + 1], "IsovimAcpResult", 90)
      end
      for _, s in ipairs(r.spans or {}) do
        span(buf, at, pre + s[1], math.min(pre + s[2], #lines[i + 1]), s[3], s.syntax and 4200 or 150)
      end
    end
    call.body = #shown
    vim.api.nvim_buf_set_extmark(buf, TOOLS, row, 0, { id = call.mark, end_row = row + call.body, end_col = 0 })
  end)
end

-- A tool call is a block, rewritten in place as its title, status or output changes. One isovim
-- draws another way (AskUserQuestion as its question, TodoWrite as its plan) gets no block.
local function tool(chat, update)
  local id = update.toolCallId or "?"
  local call = chat.tools[id]
  local meta = type(update._meta) == "table" and update._meta or {}
  local claude = type(meta.claudeCode) == "table" and meta.claudeCode or {}
  if not call then
    call = { title = update.title or "tool", status = update.status or "pending", items = {}, terminal = {}, body = 0,
      more = 0, kind = update.kind, tool = claude.toolName }
    chat.tools[id] = call
    local name = look.tool_name(call)
    call.hidden = name ~= nil and look.HIDDEN[name] or false
  end
  -- Apart from making it: a draw refused halfway (E565) comes back here with the call made.
  if not call.hidden and not call.mark then
    local row = add_block(chat, { "" })
    call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, row, 0, {})
  end
  call.title = update.title or call.title
  call.status = update.status or call.status
  call.kind = update.kind or call.kind
  call.tool = call.tool or claude.toolName
  if type(update.rawInput) == "table" and next(update.rawInput) then
    call.input = update.rawInput
  end
  if type(update.locations) == "table" and #update.locations > 0 then
    call.locations = update.locations
  end
  if type(claude.toolResponse) == "table" then
    call.response = claude.toolResponse
  end
  if type(update.content) == "table" then
    call.items = update.content
  end
  local delta, full, exit = meta.terminal_output_delta, meta.terminal_output, meta.terminal_exit
  if type(delta) == "table" and delta.terminal_id then
    call.terminal[delta.terminal_id] = (call.terminal[delta.terminal_id] or "") .. (delta.data or "")
  end
  if type(full) == "table" and full.terminal_id then
    call.terminal[full.terminal_id] = full.data or ""
  end
  if type(exit) == "table" and exit.exit_code ~= vim.NIL then
    call.exit = tonumber(exit.exit_code)
  end
  if not call.hidden then
    draw_tool(chat, call)
  end
end

-- The agent's thinking: a ✻ block, collapsed to "Thinking…" until za, streamed into.
local function thought(chat, text)
  local call = chat.block == "thought" and chat.thought or nil
  if not call then
    local row = add_block(chat, { "" })
    call = { thought = true, text = "", body = 0, more = 0, items = {}, terminal = {},
      started = chat.entry and chat.entry.ts }
    call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, row, 0, {})
    chat.tools["thought:" .. call.mark] = call
    mark_message(chat, row, false)
  end
  call.text = call.text .. text
  chat.turn_chars = (chat.turn_chars or 0) + #text
  draw_tool(chat, call)
  chat.block, chat.thought = "thought", call
end

-- A thought ends when anything else comes: its header says how long it took.
local function end_thought(chat, entry)
  local call = chat.thought
  if chat.block == "thought" and call and not call.secs then
    call.secs = (entry and entry.ts and call.started) and math.max(1, entry.ts - call.started) or nil
    if call.secs then
      draw_tool(chat, call)
    end
  end
  if chat.block == "thought" then
    chat.block = "other"
  end
  chat.thought = nil
end

local PLAN_MARK = { completed = "☒", in_progress = "☐", pending = "☐" }
local PLAN_HL = { completed = "IsovimAcpPlanDone", in_progress = "IsovimAcpPlanActive", pending = "IsovimAcpPlanPending" }

local function plan(chat, update)
  local lines = { GLYPH.message .. " Update Todos" }
  local entries = update.entries or {}
  for i, entry in ipairs(entries) do
    lines[#lines + 1] = (i == 1 and FIRST or REST) .. (PLAN_MARK[entry.status] or "☐") .. " " .. (entry.content or "")
  end
  local row = add_block(chat, lines)
  span(chat.buf, row, 0, #GLYPH.message, "IsovimAcpToolDone")
  span(chat.buf, row, #GLYPH.message + 1, #lines[1], "IsovimAcpToolTitle")
  for i, entry in ipairs(entries) do
    local line = lines[i + 1]
    local pre = #(i == 1 and FIRST or REST)
    if i == 1 then
      span(chat.buf, row + i, 0, pre, "IsovimAcpResultGlyph")
    end
    local mark = #(PLAN_MARK[entry.status] or "☐") + 1
    span(chat.buf, row + i, pre, pre + mark, PLAN_HL[entry.status] == "IsovimAcpPlanDone" and "IsovimAcpNotice" or "IsovimAcpResult")
    span(chat.buf, row + i, pre + mark, #line, PLAN_HL[entry.status] or "IsovimAcpResult")
  end
end

local function prompt_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and GLYPH.prompt .. " " or "  ") .. line
  end
  return lines
end

-- Each [Image #n] in lines (from row on) drawn as a chip.
local function chips(buf, row, lines)
  for i, line in ipairs(lines) do
    for from, to in line:gmatch("()%[Image #%d+%]()") do
      span(buf, row + i - 1, from - 1, to - 1, "IsovimAcpImage", 210)
    end
  end
end

-- Boxes: a permission or a question waiting on you, drawn as Claude draws them, and replaced by
-- what you decided once you have.

-- A rule as wide as any window: virtual text is cut at the window's edge.
local RULE = ("─"):rep(400)

---@class isovim.acp.Box
---@field mark integer its first line (in BOXES), its extent to end_row
---@field kind "permission"|"question"
---@field repo string
---@field names string[] the surfaces it waits on
---@field options string[][] each surface's option labels
---@field other boolean[] each surface takes your own words
---@field multi boolean[]

-- Draws a box's lines at the end of the conversation, its options marked for <CR> on them.
---@param rows {[1]: string, [2]: string?, spans?: table[], option?: {[1]: integer, [2]: integer}}[]
local function add_box(chat, box, rows)
  local lines = vim.tbl_map(function(r)
    return r[1]
  end, rows)
  local row = add_block(chat, lines)
  local buf = chat.buf
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { virt_lines = { { { RULE, "IsovimAcpAskRule" } } }, virt_lines_above = true })
  for i, r in ipairs(rows) do
    if r[2] then
      span(buf, row + i - 1, 0, #r[1], r[2])
    end
    for _, s in ipairs(r.spans or {}) do
      span(buf, row + i - 1, s[1], s[2], s[3], 150)
    end
    if r.option then
      local id = vim.api.nvim_buf_set_extmark(buf, OPTIONS, row + i - 1, 0, {})
      chat.options[id] = { box = box, surface = r.option[1], n = r.option[2] }
    end
  end
  box.mark = vim.api.nvim_buf_set_extmark(buf, BOXES, row, 0, { end_row = row + #lines - 1, end_col = 0 })
  return row
end

-- Takes a box out of the chat (and the blank line before it), putting lines in its place.
local function replace_box(chat, box, lines, hl)
  local pos = vim.api.nvim_buf_get_extmark_by_id(chat.buf, BOXES, box.mark, { details = true })
  if not pos[1] then
    return
  end
  local first, last = pos[1], pos[3].end_row or pos[1]
  local from = first > 0 and first - 1 or first
  edit(chat, function(buf)
    vim.api.nvim_buf_clear_namespace(buf, NS, from, last + 1)
    vim.api.nvim_buf_clear_namespace(buf, OPTIONS, from, last + 1)
    vim.api.nvim_buf_del_extmark(buf, BOXES, box.mark)
    -- A result (⎿) goes right under what it's about, as Claude puts it; anything else is a block.
    local put = #lines > 0 and (vim.startswith(lines[1], FIRST) and lines or { "", unpack(lines) }) or {}
    if first == 0 and #put > 0 then
      table.remove(put, 1)
    end
    vim.api.nvim_buf_set_lines(buf, from, last + 1, false, put)
    if hl and #lines > 0 then
      line_hl(buf, from + #put - #lines, #lines, hl)
    end
  end)
  for id, option in pairs(chat.options) do
    if option.box == box then
      chat.options[id] = nil
    end
  end
  chat.boxes = vim.tbl_filter(function(each)
    return each ~= box
  end, chat.boxes)
  if chat.block ~= "agent" then
    chat.block = "other"
  end
  update_bar(chat)
end

local HINT_ANSWER = "its number and <CR> in the composer, or <CR> on an option"

-- What Claude calls the prompt for a tool: its box's title, what it shows, and its question.
local function permission_rows(chat, entry)
  local call = chat.tools[entry.toolCallId or ""] or {}
  local name = look.tool_name(call) or (entry.tool or ""):match("^(%u%a+)")
  local input = call.input or {}
  local path = input.file_path and look.short(input.file_path, dirs(chat))
  local rows = {}
  local title, question, body
  if name == "Bash" then
    title, question = "Bash command", "Do you want to proceed?"
    local cmd = input.command or look.tool_args("Bash", nil, call.title or entry.tool, dirs(chat)) or entry.tool
    body = {}
    for _, line in ipairs(vim.split(cmd or "", "\n", { plain = true })) do
      body[#body + 1] = { "   " .. line }
    end
    if input.description then
      body[#body + 1] = { "   " .. input.description, "IsovimAcpNotice" }
    end
  elseif name == "Edit" or name == "MultiEdit" or name == "Write" then
    local new = name == "Write" and path and not vim.uv.fs_stat(input.file_path)
    title = new and "Create file" or "Edit file"
    path = path or (entry.tool or ""):match("^%u%a+ (.+)$") or "the file"
    question = new and ("Do you want to create %s?"):format(path) or ("Do you want to make this edit to %s?"):format(path)
    body = { { " " .. path, "IsovimAcpNotice" } }
  else
    title, question = "Tool use", "Do you want to proceed?"
    local tool_name, args = look.header(call.title and call or { title = entry.tool }, dirs(chat))
    body = { { "   " .. tool_name .. (args and ("(" .. args .. ")") or "") } }
  end
  rows[#rows + 1] = { " " .. title, "IsovimAcpAskTitle" }
  vim.list_extend(rows, body)
  rows[#rows + 1] = { "" }
  local q = { " " .. question }
  if path and question:find(path, 1, true) then
    local s = q[1]:find(path, 1, true)
    q.spans = { { s - 1, s - 1 + #path, "IsovimAcpBold" } }
  end
  rows[#rows + 1] = q
  return rows
end

local function option_row(n, label, surface)
  local text = ("   %d. %s"):format(n, label)
  return { text, option = { surface, n }, spans = { { 3, 3 + #tostring(n) + 1, "IsovimAcpOptionNr" } } }
end

-- A permission the agent asked for: a box waiting on you, then what you decided.
function RENDER.permission(chat, entry)
  local decision = entry.decision or "denied"
  local id = entry.toolCallId or entry.name or "?"
  if decision == "asked" then
    local box = { kind = "permission", id = id, repo = entry.repo, names = { entry.name }, options = { { "Allow", "Deny" } },
      other = { false }, multi = { false } }
    local rows = permission_rows(chat, entry)
    rows[#rows + 1] = option_row(1, "Yes", 1)
    rows[#rows + 1] = option_row(2, "No", 1)
    rows[#rows + 1] = { "" }
    rows[#rows + 1] = { (" %s · <leader>in the Inbox"):format(HINT_ANSWER), "IsovimAcpHint" }
    add_box(chat, box, rows)
    chat.boxes[#chat.boxes + 1] = box
    update_bar(chat)
    return
  end
  local box
  for _, each in ipairs(chat.boxes) do
    if each.kind == "permission" and each.id == id then
      box = each
    end
  end
  local by = entry.by and entry.by ~= "user" and entry.by or nil
  local lines, hl
  if decision == "allowed" then
    -- As on Claude's screen: once allowed, the tool just runs. Another agent's say-so is noted.
    lines = by and { ("  ⎿  Allowed by %s"):format(by) } or {}
    hl = "IsovimAcpNotice"
  elseif decision == "denied" then
    local why = entry.reason and (" (" .. entry.reason .. ")") or ""
    lines = { ("  ⎿  Denied by %s%s · %s won't run"):format(by or "you", why, entry.tool or "the tool") }
    hl = "IsovimAcpDenied"
  else
    lines = { ("  ⎿  Permission withdrawn%s"):format(entry.reason and (": " .. entry.reason) or "") }
    hl = "IsovimAcpNotice"
  end
  if box then
    replace_box(chat, box, lines, hl)
  elseif #lines > 0 then
    add_block(chat, lines, hl)
  end
end

-- What the agent asked you (AskUserQuestion): its questions in a box, then the answers.
function RENDER.question(chat, entry)
  if entry.state == "asked" then
    local call = chat.tools[entry.toolCallId or ""] or {}
    local asked = type(call.input) == "table" and type(call.input.questions) == "table" and call.input.questions or {}
    local box = { kind = "question", id = entry.id, repo = entry.repo, names = {}, options = {}, other = {}, multi = {},
      texts = {} }
    local rows = {}
    for i, q in ipairs(entry.questions or {}) do
      box.names[i] = q.name
      box.options[i] = vim.tbl_map(function(option)
        return option.label
      end, q.options or {})
      box.other[i] = q.other == true
      box.multi[i] = q.multi == true
      local header = asked[i] and asked[i].header
      -- The adapter puts the header before the question ("Color: Which color?"); the chip has it.
      local text = q.question or ""
      if header and vim.startswith(text, header .. ": ") then
        text = text:sub(#header + 3)
      end
      box.texts[i] = text
      if i > 1 then
        rows[#rows + 1] = { "" }
      end
      if header then
        local chip = " ☐ " .. header .. " "
        rows[#rows + 1] = { " " .. chip, spans = { { 1, 1 + #chip, "IsovimAcpAskChip" } } }
        rows[#rows + 1] = { "" }
      end
      rows[#rows + 1] = { " " .. text, "IsovimAcpBold" }
      rows[#rows + 1] = { "" }
      for n, option in ipairs(q.options or {}) do
        rows[#rows + 1] = option_row(n, option.label or "", i)
        if option.description and option.description ~= "" then
          rows[#rows + 1] = { "      " .. option.description, "IsovimAcpOptionNote" }
        end
      end
      if box.other[i] then
        rows[#rows + 1] = { ("   %d. Type something."):format(#(q.options or {}) + 1), "IsovimAcpOptionNote" }
      end
      if box.multi[i] then
        rows[#rows + 1] = { "   (any of them: their numbers, space between)", "IsovimAcpOptionNote" }
      end
    end
    rows[#rows + 1] = { "" }
    rows[#rows + 1] = { (" %s · <leader>in the Inbox"):format(HINT_ANSWER), "IsovimAcpHint" }
    add_box(chat, box, rows)
    chat.boxes[#chat.boxes + 1] = box
    update_bar(chat)
    return
  end
  local box
  for _, each in ipairs(chat.boxes) do
    if each.kind == "question" and each.id == entry.id then
      box = each
    end
  end
  if entry.state == "answered" then
    local who = (entry.by and entry.by ~= "user") and entry.by or "User"
    local lines = { ("%s %s answered %s's questions:"):format(GLYPH.message, who, chat.kind == "codex" and "Codex" or "Claude") }
    local texts = box and box.texts or {}
    for i, text in ipairs(entry.answers or {}) do
      local q = texts[i]
      local answer = text:gsub("\n", ", ")
      lines[#lines + 1] = (i == 1 and FIRST or REST) .. "· " .. (q and (q .. " → ") or "") .. answer
    end
    if #lines == 1 then
      lines[2] = FIRST .. "(no answer)"
    end
    if box then
      replace_box(chat, box, {})
    end
    local row = add_block(chat, lines)
    span(chat.buf, row, 0, #GLYPH.message, "IsovimAcpMessage")
    for i = 1, #lines - 1 do
      span(chat.buf, row + i, 0, #lines[i + 1], "IsovimAcpNotice")
    end
  else
    local lines = { ("  ⎿  The question was withdrawn: %s"):format(entry.reason or "cancelled") }
    if box then
      replace_box(chat, box, lines, "IsovimAcpNotice")
    else
      add_block(chat, lines, "IsovimAcpNotice")
    end
  end
end

-- Boxes nothing will answer now (a new session, the agent gone) are taken down.
local function drop_boxes(chat)
  for _, box in ipairs(vim.list_slice(chat.boxes, 1)) do
    replace_box(chat, box, { "  ⎿  No longer waiting on an answer" }, "IsovimAcpNotice")
  end
end

-- The queue window shows the live chat's queue: one being drawn again (a hot reload's, in a buffer
-- of its own) leaves it alone until it's swapped in.
local function refresh_queue(chat)
  if not chat.backlog then
    queue.refresh(chat)
  end
end

function RENDER.prompt(chat, entry)
  -- Sent now: it leaves the queue.
  local before = #chat.queue
  chat.queue = vim.tbl_filter(function(item)
    return item.id ~= entry.id
  end, chat.queue)
  if #chat.queue ~= before then
    refresh_queue(chat)
  end
  -- Yours: typed in a composer or on Claude's screen, or iso spawn's; not one iso send or msg
  -- delivered.
  local mine = entry.via ~= "iso"
  local lines = prompt_lines(entry.text or "")
  local row = add_block(chat, lines)
  span(chat.buf, row, 0, #GLYPH.prompt + 1, "IsovimAcpPromptGlyph")
  span(chat.buf, row, #GLYPH.prompt + 1, #lines[1], "IsovimAcpPrompt")
  for i = 2, #lines do
    span(chat.buf, row + i - 1, 0, #lines[i], "IsovimAcpPrompt")
  end
  chips(chat.buf, row, lines)
  -- Its iso: addresses as chips (isovim.links).
  edit(chat, function(buf)
    require("isovim.links").substitute(buf, row, row + #lines, function(fn)
      fn()
    end)
  end)
  mark_message(chat, row, mine)
  if mine and entry.text and chat.history[#chat.history] ~= entry.text then
    chat.history[#chat.history + 1] = entry.text
  end
  if mine and entry.images then
    chat.history_images[entry.text] = entry.images
  end
end

-- A thread's lines (isovim.threads), when the chat is a thread's view: its title, the posts (yours
-- as your prompts are, the router's as the agent's text), resolved and opened again, and the
-- router's turn on it running (the bar says so).
local THREAD_GLYPH = "\u{f086}" -- fa-comments

local function thread_tab(chat)
  vim.b[chat.buf].isovim_tab = { name = chat.title or "new thread", icon = THREAD_GLYPH, hl = "Special" }
  pcall(vim.cmd.redrawtabline)
end

-- Drawn as the PR view draws (isovim.boxes): a banner (an open or resolved pill, the title bold, a dim
-- line of facts), then each post in a rounded box headed "author · time", yours tinted as your
-- prompts are, the router's border in its bullet's color, markdown and tables inside it; a resolved
-- thread ends with its outcome's box.
local function box_width(chat)
  return math.max(30, table_width(chat) + 1)
end

local function ago(at)
  local secs = math.max(0, os.time() - (at or os.time()))
  return secs < 60 and "now" or secs < 3600 and math.floor(secs / 60) .. "m" or secs < 86400 and math.floor(secs / 3600) .. "h"
    or math.floor(secs / 86400) .. "d"
end

local function clock(at)
  at = at or os.time()
  return os.date("%Y%m%d", at) == os.date("%Y%m%d") and os.date("%H:%M", at) or os.date("%b %d %H:%M", at)
end

-- The banner's two lines, with their marks.
local function banner(chat)
  local boxes = require("isovim.boxes")
  local info = chat.thread_info or {}
  local resolved = chat.resolved ~= nil
  local pill = boxes.seg(resolved and " resolved " or " open ", resolved and "IsovimPrPillDraft" or "IsovimPrPillOpen")
  local first = boxes.cat(pill, boxes.seg(" "), boxes.seg(THREAD_GLYPH .. " " .. (chat.title or chat.thread or ""), "IsovimPrTitle"))
  local facts = { ("\u{f06a9} %s"):format(chat.router or store.router(chat.ws) or "no router"),
    ("\u{f415} started by %s"):format(info.created_by or "?"), ("\u{f43a} %s"):format(ago(info.at)),
    ("%d %s"):format(info.posts or 0, info.posts == 1 and "post" or "posts") }
  if info.last then
    facts[#facts + 1] = "last " .. ago(info.last)
  end
  return { first, boxes.seg(table.concat(facts, "  ·  "), "IsovimPrDim") }
end

-- The banner drawn again where it is (the first two lines) when what it says changed.
local function update_banner(chat)
  if not (chat.thread and chat.banner) or chat.drawing_banner or safe.text_locked() then
    return
  end
  local lines = banner(chat)
  local texts = vim.tbl_map(function(line)
    return line.text
  end, lines)
  if vim.deep_equal(texts, vim.api.nvim_buf_get_lines(chat.buf, 0, 2, false)) then
    return
  end
  chat.drawing_banner = true
  edit(chat, function(buf)
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, 2)
    vim.api.nvim_buf_set_lines(buf, 0, 2, false, texts)
    for i, line in ipairs(lines) do
      for _, mark in ipairs(line.marks) do
        span(buf, i - 1, mark[1], mark[2], mark[3], 150)
      end
    end
  end)
  chat.drawing_banner = nil
end

-- A rounded box of body lines under title, as a block; returns its first row.
local function draw_box(chat, title, body, border, tint, mine)
  local boxes = require("isovim.boxes")
  local width = box_width(chat)
  local lines = { boxes.top(width, title, border) }
  for _, line in ipairs(body) do
    lines[#lines + 1] = boxes.side(width, line, border)
  end
  lines[#lines + 1] = boxes.bottom(width, nil, border)
  local row = add_block(chat, vim.tbl_map(function(line)
    return line.text
  end, lines))
  for i, line in ipairs(lines) do
    for _, mark in ipairs(line.marks) do
      if mark[4] then
        -- A link's chip (isovim.boxes put it there): which address it is, for <Tab>.
        require("isovim.links").register(chat.buf, row + i - 1, mark[1], mark[2], mark[4], {})
      elseif mark[3] then
        span(chat.buf, row + i - 1, mark[1], mark[2], mark[3], 150)
      end
    end
  end
  if tint then
    line_hl(chat.buf, row, #lines, tint)
  end
  mark_message(chat, row, mine)
  return row
end

function RENDER.thread(chat, entry)
  require("isovim.boxes").highlights()
  chat.title = entry.title or entry.id
  chat.thread_info = { created_by = entry.created_by, at = entry.at, posts = 0 }
  thread_tab(chat)
  local lines = banner(chat)
  local row = add_lines(chat, vim.tbl_map(function(line)
    return line.text
  end, lines))
  for i, line in ipairs(lines) do
    for _, mark in ipairs(line.marks) do
      span(chat.buf, row + i - 1, mark[1], mark[2], mark[3], 150)
    end
  end
  chat.banner = true
end

function RENDER.post(chat, entry)
  local boxes = require("isovim.boxes")
  local info = chat.thread_info or {}
  info.posts, info.last = (info.posts or 0) + 1, entry.at
  local mine = entry.by == "user"
  local body = boxes.markdown(entry.text or "", box_width(chat) - 4)
  for _, image in ipairs(entry.images or {}) do
    body[#body + 1] = boxes.seg("\u{f03e} image: " .. vim.fn.fnamemodify(image.path or "", ":t"), "IsovimPrLink")
  end
  local who = mine and "you" or entry.by:match("([^/]+)$") or entry.by
  local title = mine and boxes.cat(boxes.seg(GLYPH.prompt .. " " .. who, "IsovimAcpPromptGlyph"), boxes.seg(" · " .. clock(entry.at), "IsovimPrDim"))
    or boxes.cat(boxes.seg(GLYPH.message .. " ", "IsovimAcpMessage"), boxes.seg(who, "IsovimPrTitle"), boxes.seg(" · " .. clock(entry.at), "IsovimPrDim"))
  draw_box(chat, title, body, mine and "IsovimPrBorder" or "IsovimAcpMessage", mine and "IsovimAcpPrompt" or nil, mine)
  if mine and entry.text and chat.history[#chat.history] ~= entry.text then
    chat.history[#chat.history + 1] = entry.text
  end
  if mine and entry.images then
    chat.history_images[entry.text] = entry.images
  end
  update_banner(chat)
end

function RENDER.resolved(chat, entry)
  local boxes = require("isovim.boxes")
  chat.resolved = { by = entry.by, outcome = entry.outcome }
  local body = entry.outcome and boxes.markdown(entry.outcome, box_width(chat) - 4) or { boxes.seg("No outcome given.", "IsovimPrDim") }
  local who = entry.by == "user" and "you" or (entry.by or "?"):match("([^/]+)$")
  draw_box(chat, boxes.cat(boxes.seg("✓ resolved", "IsovimPrOk"), boxes.seg((" by %s · %s"):format(who, clock(entry.at)), "IsovimPrDim")),
    body, "IsovimPrOk")
  update_banner(chat)
end

-- A question the router asks in the thread (isovim.threads' ask): a box of the thread's style,
-- its options numbered, answered as the chat's boxes are (its number and <CR> in the composer, <CR>
-- on an option), through the question surface isovim.surfaces makes of it; once answered, one line.
function RENDER.ask(chat, entry)
  local boxes = require("isovim.boxes")
  local name = chat.thread .. "-" .. entry.qid
  local options = entry.options or {}
  local box = { kind = "question", id = name, repo = chat.ws, names = { name }, other = { entry.other == true },
    multi = { entry.multi == true }, texts = { entry.question or "" },
    options = { vim.tbl_map(function(option)
      return option.label
    end, options) } }
  local width = box_width(chat) - 4
  local body = vim.tbl_map(function(line)
    line.marks[#line.marks + 1] = { 0, #line.text, "IsovimPrTitle" }
    return line
  end, boxes.markdown(entry.question or "", width))
  body[#body + 1] = boxes.seg("")
  local first_option = #body + 1
  for n, option in ipairs(options) do
    body[#body + 1] = boxes.cat(boxes.seg(("%d. "):format(n), "IsovimAcpOptionNr"),
      boxes.seg((entry.multi and "☐ " or "") .. (option.label or "")))
    if option.description and option.description ~= "" then
      body[#body + 1] = boxes.seg("   " .. option.description, "IsovimPrDim")
    end
  end
  if entry.other then
    body[#body + 1] = boxes.seg(("%d. your own words: %d <words>"):format(#options + 1, #options + 1), "IsovimPrDim")
  end
  if entry.multi then
    body[#body + 1] = boxes.seg("any of them: their numbers, space between", "IsovimPrDim")
  end
  local who = (entry.by or "the router"):match("([^/]+)$")
  local row = draw_box(chat, boxes.cat(boxes.seg("? ", "IsovimAcpAsk"), boxes.seg(who, "IsovimPrTitle"),
    boxes.seg(" asks · " .. clock(entry.at), "IsovimPrDim")), body, "IsovimAcpAsk")
  -- Each option's line, for <CR> on it; the box's extent, to put the answer in its place.
  local line = row + first_option
  for n, option in ipairs(options) do
    local id = vim.api.nvim_buf_set_extmark(chat.buf, OPTIONS, line, 0, {})
    chat.options[id] = { box = box, surface = 1, n = n }
    line = line + 1 + ((option.description and option.description ~= "") and 1 or 0)
  end
  box.mark = vim.api.nvim_buf_set_extmark(chat.buf, BOXES, row, 0, { end_row = row + #body + 1, end_col = 0 })
  chat.boxes[#chat.boxes + 1] = box
end

function RENDER.answered(chat, entry)
  local name = chat.thread .. "-" .. entry.qid
  for _, box in ipairs(vim.list_slice(chat.boxes, 1)) do
    if box.id == name then
      local answer = require("isovim.surfaces").answer_text({ labels = entry.labels or {}, other = entry.other }):gsub("\n", ", ")
      local by = entry.by and entry.by ~= "user" and (" (" .. entry.by:match("([^/]+)$") .. ")") or ""
      replace_box(chat, box, { ("? %s → %s%s"):format(box.texts[1], answer, by) }, "IsovimAcpNotice")
    end
  end
end

function RENDER.renamed(chat, entry)
  chat.title = entry.title or chat.title
  thread_tab(chat)
  local who = entry.by == "user" and "you" or (entry.by or "?"):match("([^/]+)$")
  add_block(chat, { ("renamed “%s” by %s · %s"):format(chat.title, who, clock(entry.at)) },
    "IsovimPrDim")
  update_banner(chat)
end

function RENDER.reopened(chat, entry)
  chat.resolved = nil
  add_block(chat, { ("opened again by %s · %s"):format(entry.by == "user" and "you" or entry.by or "?", clock(entry.at)) }, "IsovimPrDim")
  update_banner(chat)
end

function RENDER.working(chat, entry)
  chat.busy = entry.state == "start"
  chat.since = chat.busy and entry.at or nil
end

function RENDER.queued(chat, entry)
  chat.queue[#chat.queue + 1] = { id = entry.id or "", text = entry.text or "" }
  refresh_queue(chat)
end

function RENDER.queue(chat, entry)
  chat.queue = vim.tbl_map(function(item)
    return { id = item.id, text = item.text or "" }
  end, entry.items or {})
  refresh_queue(chat)
end

function RENDER.update(chat, entry)
  local update = entry.update or {}
  local kind = update.sessionUpdate
  local content = type(update.content) == "table" and update.content or {}
  if kind == "agent_thought_chunk" and content.type == "text" then
    thought(chat, content.text or "")
    return
  end
  if kind == "agent_message_chunk" or kind == "tool_call" or kind == "tool_call_update" or kind == "plan" then
    end_thought(chat, entry)
  end
  if kind == "agent_message_chunk" and content.type == "text" then
    add_text(chat, content.text or "")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    tool(chat, update)
  elseif kind == "plan" then
    plan(chat, update)
  end
end

function RENDER.turn(chat, entry)
  if entry.state == "start" then
    chat.busy, chat.since, chat.turn_id, chat.turn_chars = true, entry.ts, entry.id, 0
    chat.verb = look.verb(entry.id)
  elseif entry.state == "end" then
    end_thought(chat, entry)
    chat.busy = false
    local reason = entry.error or entry.stopReason
    if reason == "cancelled" then
      add_lines(chat, { "  ⎿  Interrupted · What should " .. (chat.kind == "codex" and "Codex" or "Claude") .. " do instead?" },
        "IsovimAcpNotice")
    elseif entry.error or (reason and reason ~= "end_turn") then
      add_lines(chat, { ("  ⎿  Error: the turn ended: %s"):format(reason) }, "IsovimAcpError")
    end
    local _, past = look.verb(entry.id)
    if chat.since and entry.ts and reason ~= "cancelled" then
      local row = add_block(chat, { ("%s %s for %s"):format(GLYPH.thought, past, look.duration(entry.ts - chat.since)) })
      span(chat.buf, row, 0, #vim.api.nvim_buf_get_lines(chat.buf, row, row + 1, false)[1], "IsovimAcpTurnDone")
    end
    chat.since = nil
    drop_boxes(chat)
  end
end

function RENDER.notice(chat, entry)
  if (entry.text or ""):match("^the agent exited") then
    chat.busy = false
    drop_boxes(chat)
  end
  add_block(chat, { "[" .. (entry.text or "") .. "]" }, "IsovimAcpNotice")
end

-- A session the supervisor compacted when a turn ended: not a turn, one dim line.
function RENDER.compact(chat, entry)
  local function k(tokens)
    return ("%dk"):format(math.floor((tonumber(tokens) or 0) / 1000 + 0.5))
  end
  add_block(chat, { entry.error and ("compacting at %s failed: %s"):format(k(entry.before), entry.error)
    or ("compacted %s → %s"):format(k(entry.before), k(entry.after)) }, "IsovimAcpNotice")
end

function RENDER.session(chat, entry)
  chat.busy, chat.handover = false, false
  drop_boxes(chat)
  local sid = entry.sessionId or ""
  local said
  if entry.how == "new" then
    said = entry.cleared and ("[new session %s; /resume brings back the one before]"):format(sid) or nil
  elseif entry.how == "fork" then
    said = ("[forked from %s%s: session %s]"):format(entry.from or "another agent", entry.at and " at a message" or "", sid)
  elseif entry.how == "reload" then
    -- A promotion's reload (isovim.acp.host): its notice says so.
    said = nil
  elseif entry.how == "rewind" then
    said = ("[rewound: going on from before your edited prompt, session %s; %s]"):format(sid, entry.files or "")
  else
    said = ("[%s session %s]"):format(entry.how == "resume" and "resumed" or "loaded", sid)
  end
  if said then
    add_block(chat, { said }, "IsovimAcpNotice")
  end
end

function RENDER.handover(chat, entry)
  if entry.state == "start" then
    chat.handover = true
    add_block(chat, { ("[handed over to Claude's screen: claude --resume %s]"):format(entry.sessionId or "") }, "IsovimAcpNotice")
  else
    chat.handover = false
    add_block(chat, { "[back from Claude's screen]" }, "IsovimAcpNotice")
  end
end

-- The spinner's frames, as Claude's.
local FRAMES = { "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" }
local frame = 1

-- What the bar above the composer says, as {text, hl} parts: while the agent works, Claude's
-- spinner line (its glyph, the turn's verb, how long, about how many tokens, how to interrupt).
---@param chat isovim.acp.Chat
-- The agent's name from its record, read again at most every 2s: the bar and the composer's
-- placeholder draw on every streamed chunk, and reading the record each time (a file read and a
-- JSON decode) was most of a streaming chat's cost, while a rename still shows.
local function agent_name(chat)
  local now = vim.uv.now()
  if not chat.name_read or now - chat.name_read > 2000 then
    chat.name_read, chat.agent_name = now, (store.agent(chat.ws, chat.agent) or {}).name or chat.agent
  end
  return chat.agent_name
end

function M.bar_parts(chat)
  local parts = {}
  local function add(text, hl)
    parts[#parts + 1] = { text, hl }
  end
  if chat.pending_title or chat.thread then
    if chat.pending_title then
      add(THREAD_GLYPH .. " a new thread in " .. chat.ws .. ": its title first", "IsovimAcpSpinner")
    elseif chat.renaming then
      add("✎ its new title: <CR> renames it · <C-c> keeps " .. (chat.title or chat.thread), "IsovimAcpSpinner")
    elseif #chat.boxes > 0 then
      add("? waiting for your answer", "IsovimAcpAsk")
      add(" (its number and <CR>, or <CR> on an option; anything else posts)", "IsovimAcpSpinnerNote")
    elseif chat.busy then
      local sec, usec = vim.uv.gettimeofday()
      local secs = chat.since and math.max(0, math.floor(sec + usec / 1e6 - chat.since)) or 0
      add(FRAMES[frame] .. " ", "IsovimAcpSpinner")
      chat.router = chat.router or store.router(chat.ws) or "the router"
      add(("%s is working on it… (%s)"):format(chat.router, look.duration(secs)), "IsovimAcpSpinnerNote")
    elseif chat.resolved then
      -- Its outcome is in the box above; the bar only says how to open it again.
      add("✓ resolved · r on the thread opens it again", "IsovimAcpIdle")
    else
      add(THREAD_GLYPH .. " " .. (chat.title or chat.thread), "IsovimAcpIdle")
    end
    return parts
  end
  if chat.rewind then
    add("↶ rewind: edit your prompt; <CR> goes on from before it (its files too) · <C-c> drops the rewind", "IsovimAcpSpinner")
  elseif chat.handover then
    add("⇄ on Claude's screen (iso handover); prompts wait", "IsovimAcpSpinner")
  elseif #chat.boxes > 0 then
    local box = chat.boxes[1]
    add(box.kind == "permission" and "? waiting for your permission" or "? waiting for your answer", "IsovimAcpAsk")
    add(" (type its number and <CR>)", "IsovimAcpSpinnerNote")
  elseif chat.busy then
    local sec, usec = vim.uv.gettimeofday()
    local secs = chat.since and math.max(0, math.floor(sec + usec / 1e6 - chat.since)) or 0
    add(FRAMES[frame] .. " ", "IsovimAcpSpinner")
    add((chat.verb or "Working") .. "…", "IsovimAcpSpinnerVerb")
    local notes = { look.duration(secs) }
    local tokens = math.floor(((chat.turn_chars or 0) + 3) / 4)
    if chat.block == "thought" then
      notes[#notes + 1] = "thinking"
    elseif tokens > 0 then
      notes[#notes + 1] = "↓ " .. look.count(tokens) .. " tokens"
    end
    notes[#notes + 1] = "<C-c> to interrupt"
    add(" (" .. table.concat(notes, " · ") .. ")", "IsovimAcpSpinnerNote")
  else
    add(GLYPH.prompt .. " " .. agent_name(chat), "IsovimAcpIdle")
  end
  if #chat.queue > 0 then
    add((" · %d queued"):format(#chat.queue), "IsovimAcpSpinnerNote")
  end
  return parts
end

function M.bar_text(chat)
  return " " .. table.concat(vim.tbl_map(function(p)
    return p[1]
  end, M.bar_parts(chat)))
end

local function any_busy()
  for _, chat in pairs(chats) do
    if chat.busy and vim.api.nvim_buf_is_loaded(chat.buf) then
      return true
    end
  end
  return false
end

-- The bar is drawn over the composer (decorate); a window that doesn't show the buffer's end, the
-- composer out of sight, has it as its winbar, saying so.
update_bar = function(chat)
  if not vim.api.nvim_buf_is_loaded(chat.buf) then
    return
  end
  -- A thread's banner says how long ago: drawn again as the minutes pass.
  if chat.thread and chat.banner and chat.banner_minute ~= math.floor(os.time() / 60) then
    chat.banner_minute = math.floor(os.time() / 60)
    update_banner(chat)
  end
  decorate(chat)
  local bar = " "
  for _, part in ipairs(M.bar_parts(chat)) do
    bar = bar .. "%#" .. part[2] .. "#" .. part[1]:gsub("%%", "%%%%")
  end
  bar = bar .. "%#IsovimAcpSpinnerNote# · ↓ more below"
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    local want = vim.w[win].isovim_unseen and bar or ""
    if vim.wo[win][0].winbar ~= want then
      vim.wo[win][0].winbar = want
    end
  end
  -- In _G, so a hot reload can stop the one the old code started.
  if any_busy() and not _G.isovim_acp_spinner then
    local spinner = vim.uv.new_timer()
    _G.isovim_acp_spinner = spinner
    spinner:start(100, 100, safe.ticker("the chat's spinner", function()
      frame = frame % #FRAMES + 1
      local busy = false
      for _, each in pairs(chats) do
        if each.busy and vim.api.nvim_buf_is_loaded(each.buf) then
          busy = true
          safe.wrap("the chat's spinner", update_bar)(each)
        end
      end
      if not busy and not spinner:is_closing() then
        spinner:close()
        _G.isovim_acp_spinner = nil
      end
    end))
  end
end

local function render(chat, entry)
  if not vim.api.nvim_buf_is_loaded(chat.buf) then
    return
  end
  local draw = RENDER[entry.kind]
  if draw then
    chat.entry = entry
    draw(chat, entry)
    chat.entry = nil
  end
  -- Drawing many at once (a journal read, a hot reload's redraw), the bar is drawn once after.
  if not (chat.batch or chat.backlog) then
    update_bar(chat)
  end
end

local reset, flush

-- Draws an entry; only then is it taken (chat.seq), so one nvim wouldn't let be drawn isn't lost: it
-- returns false for that (E565). One that fails for any other reason is reported, not tried again,
-- as it would fail for good.
local function draw_entry(chat, entry)
  if entry.reset_chat then
    reset(chat)
    return true
  end
  -- Set while it draws, so a read of the journal that lands meanwhile doesn't draw it twice.
  local before = chat.seq
  chat.seq = tonumber(entry.seq) or before
  local ok, err = pcall(render, chat, entry)
  chat.entry = nil
  if not ok and tostring(err):find("E565", 1, true) then
    chat.seq = before
    return false
  end
  if not ok then
    error(err, 0)
  end
  if chat.thread and not chat.seen_soon then
    chat.seen_soon = true
    vim.schedule(function()
      chat.seen_soon = nil
      M.thread_seen(chat)
    end)
  end
  return true
end

-- Holds an entry back while nvim refuses text changes (safe.text_locked: a supervisor's push landing
-- inside an expression mapping, say), in order, and tries again shortly.
local function hold(chat, entry)
  chat.deferred = chat.deferred or {}
  chat.deferred[#chat.deferred + 1] = entry
  chat.deferred_to = entry.reset_chat and 0 or tonumber(entry.seq) or chat.deferred_to
  if not chat.retrying then
    chat.retrying = true
    vim.defer_fn(safe.wrap("the chat's stream", function()
      chat.retrying = false
      if not chat.dead then
        flush(chat)
      end
    end), 50)
  end
end

-- What was held back, drawn now if it can be; what can't stays held, in order.
flush = function(chat)
  local held = chat.deferred
  if not held then
    return
  elseif safe.text_locked() then
    chat.deferred = {}
    return vim.iter(held):each(function(entry)
      hold(chat, entry)
    end)
  end
  chat.deferred, chat.deferred_to = nil, nil
  -- Each on its own: one that fails for good is reported, and doesn't take the rest with it.
  local draw = safe.wrap("the chat's stream", draw_entry)
  batch(chat, function()
    for i, entry in ipairs(held) do
      if draw(chat, entry) == false then
        for j = i, #held do
          hold(chat, held[j])
        end
        return
      end
    end
  end)
end

-- Takes an entry once, in order: one pushed ahead of what's been read (a gap) reads the journal.
local function ingest(chat, entry, pushed)
  local seq = tonumber(entry.seq) or 0
  local top = chat.deferred and chat.deferred_to or chat.seq
  if seq <= top then
    return
  end
  if pushed and seq > top + 1 then
    return chat.drain()
  end
  if chat.deferred or safe.text_locked() or not draw_entry(chat, entry) then
    hold(chat, entry)
  end
end

-- An entry the supervisor pushed (isovim.acp.host, to every subscribed chat).
-- Not during a hot reload, which makes the chat again: the journal, written before each push,
-- brings what was pushed meanwhile.
M.push = safe.wrap("the chat's stream", function(ws, agent, entry)
  if safe.reloading() then
    return
  end
  local chat = chats[key(ws, agent)]
  if chat and type(entry) == "table" and not chat.retiring then
    ingest(chat, entry, true)
  end
end)

-- The conversation emptied, to be drawn again from the journal; the composer, and your cursor in
-- it, stay as they are.
reset = function(chat)
  chat.block, chat.tools, chat.queue, chat.history, chat.seq, chat.fresh = nil, {}, {}, {}, 0, true
  chat.history_images = {}
  chat.marks, chat.boxes, chat.options, chat.thought = {}, {}, {}, nil
  chat.busy, chat.handover, chat.resolved, chat.banner, chat.thread_info = false, false, nil, nil, nil
  if vim.api.nvim_buf_is_loaded(chat.buf) then
    for _, ns in ipairs({ NS, TOOLS, MESSAGES, MINE, MD, BOXES, OPTIONS }) do
      vim.api.nvim_buf_clear_namespace(chat.buf, ns, 0, -1)
    end
    edit(chat, function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, body_end(chat), false, { "" })
    end)
  end
  refresh_queue(chat)
end

-- The journal was replaced: the chat starts over, once nvim lets it be drawn. What was held back was
-- of the journal that's gone.
local function start_over(chat)
  if safe.text_locked() then
    chat.deferred = nil
    return hold(chat, { reset_chat = true })
  end
  chat.deferred, chat.deferred_to = nil, nil
  reset(chat)
end

-- Subscribes to the supervisor's entries, if it's up and the chat isn't already.
local function subscribe(chat)
  if chat.chan and vim.api.nvim_get_chan_info(chat.chan).id then
    return true
  end
  chat.chan = nil
  local sock = acp.socket(chat.ws, chat.agent)
  if not vim.uv.fs_stat(sock) then
    return false
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  if not ok or chan == 0 then
    return false
  end
  local called = pcall(function()
    local id = vim.rpcrequest(chan, "nvim_get_api_info")[1]
    vim.rpcrequest(chan, "nvim_exec_lua", "return require('isovim.acp.host').call('subscribe', ...)", { { chan = id } })
  end)
  if not called then
    pcall(vim.fn.chanclose, chan)
    return false
  end
  chat.chan = chan
  -- What was journaled before it subscribed.
  chat.drain()
  return true
end

-- The row of the next (dir 1) or previous (-1) message after the cursor; only yours with mine.
local function jump(chat, dir, mine)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, mine and MINE or MESSAGES, 0, -1, {})) do
    local candidate = mark[2]
    if dir > 0 and candidate > row or dir < 0 and candidate < row then
      if not target or (dir > 0 and candidate < target) or (dir < 0 and candidate > target) then
        target = candidate
      end
    end
  end
  if target then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  end
end

-- za zo zc on the tool call under the cursor, from its line or its output: toggle, open or collapse
-- its output. Anywhere else the keys keep their meaning, for any other fold.
local function fold(chat, cmd)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local marks = vim.api.nvim_buf_get_extmarks(chat.buf, TOOLS, { row, 0 }, 0, { details = true, limit = 1 })
  local mark = marks[1]
  local first, last = mark and mark[2], mark and (mark[4].end_row or mark[2])
  if not first or row > last then
    return pcall(vim.cmd, "normal! " .. cmd)
  end
  local call
  for _, each in pairs(chat.tools) do
    if each.mark == mark[1] then
      call = each
    end
  end
  if not call then
    return
  end
  local now = call.more == 0 and call.can_open
  local open = (cmd == "zo") or (cmd == "za" and not now) or false
  if open == now or (open and call.more == 0) then
    return
  end
  call.open = open
  draw_tool(chat, call)
  local at = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if at and not open then
    vim.api.nvim_win_set_cursor(0, { math.min(row, at + call.body) + 1, 0 })
  end
end

local placed

-- <C-o>: every tool call's output and every thought opened while any is collapsed, else all
-- collapsed; and those still to come, until <C-o> again (za on one still sets that one). Drawn as
-- one change, the cursor kept on the call it was in.
local function toggle_all(chat)
  local calls = placed(chat)
  local open = false
  for _, call in ipairs(calls) do
    if call.can_open and call.more > 0 then
      open = true
    end
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local here = row < chat.lines and vim.api.nvim_buf_get_extmarks(chat.buf, TOOLS, { row, 0 }, 0, { limit = 1 })[1]
  chat.all_open = open
  edit(chat, function()
    for _, call in ipairs(calls) do
      call.open = nil
      draw_tool(chat, call)
    end
  end)
  local at = here and vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, here[1], {})[1]
  if at and at < row then
    vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
  end
end

local function cancel(chat)
  if chat.thread or chat.pending_title then
    return vim.notify("isovim: the router's turns run in its own chat (<leader>ir); <C-c> there stops one")
  end
  local ok, result = acp.call(chat.ws, chat.agent, "cancel")
  if not ok then
    vim.notify("isovim: could not cancel " .. chat.agent .. ": " .. tostring(result), vim.log.levels.ERROR)
  elseif not result.cancelled then
    vim.notify("isovim: " .. chat.agent .. " isn't working", vim.log.levels.INFO)
  end
end

-- The file named on the cursor's line (path, path:12), as a tab in the chat's window (isovim.show).
local function open_file(chat)
  local file = vim.fn.expand("<cfile>")
  local line = vim.api.nvim_get_current_line()
  local start = line:find(file, 1, true)
  local lnum = start and line:sub(start + #file):match("^:(%d+)")
  local dir = store.agent_dir(chat.ws, chat.agent)
  local path = vim.fn.filereadable(file) == 1 and vim.fn.fnamemodify(file, ":p") or dir .. "/" .. file
  if vim.fn.filereadable(path) == 0 then
    return vim.notify("isovim: no file " .. file, vim.log.levels.WARN)
  end
  require("isovim").show(path, lnum)
end

local function scratch(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

-- A toast in the TUI (Snacks), a plain message in iso attach.
local function say(text, level)
  if rawget(_G, "Snacks") then
    Snacks.notify(text, { title = "isovim", level = level or vim.log.levels.INFO })
  else
    vim.notify("isovim: " .. text, level or vim.log.levels.INFO)
  end
end

local function call_error(result)
  return (tostring(result):gsub("^.-:%d+: ", ""))
end

-- Forks the agent into a new one (iso fork), at the message whose journal entry is seq or whole,
-- and opens it once it's up.
function M.fork(chat, seq, name)
  local cmd = { require("isovim.panes").bin, "fork", chat.ws .. "/" .. chat.agent }
  if seq then
    vim.list_extend(cmd, { "--at", tostring(seq) })
  end
  if name and name ~= "" then
    vim.list_extend(cmd, { "--name", name })
  end
  say(("forking %s%s..."):format(chat.agent, seq and " at that message" or ""))
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    local addr = vim.trim(result.stdout or ""):match("([^\n]+)$")
    local ws, id = (addr or ""):match("^(.*)/([^/]+)$")
    if result.code ~= 0 or not ws then
      return say("could not fork " .. chat.agent .. ": " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
    end
    say(("%s is a fork of %s"):format(addr, chat.agent))
    local isovim = package.loaded["isovim"]
    if isovim and isovim.open and isovim.refresh then
      pcall(isovim.refresh)
      pcall(isovim.open, ws, id)
    end
  end))
end

-- The history picker: the sessions this agent has had; the one you pick is resumed.
function M.history(chat)
  local ok, result = acp.call(chat.ws, chat.agent, "sessions")
  if not ok then
    return say("its sessions: " .. call_error(result), vim.log.levels.ERROR)
  end
  local items = result.sessions or {}
  if #items == 0 then
    return say(chat.agent .. " has no sessions yet")
  end
  vim.ui.select(items, {
    prompt = ("Sessions of %s"):format(chat.agent),
    format_item = function(item)
      return ("%s %s · %s · %s%s"):format(item.current and "●" or " ", os.date("%Y-%m-%d %H:%M", item.used or item.started or 0),
        item.title or "(no prompt yet)", item.id:sub(1, 8), item.current and " (now)" or "")
    end,
  }, function(item)
    if item and not item.current then
      local resumed, err = acp.call(chat.ws, chat.agent, "resume", { id = item.id })
      if not resumed then
        say("could not resume it: " .. call_error(err), vim.log.levels.ERROR)
      end
    end
  end)
end

-- The slash commands isovim runs itself; every other one goes to the agent as typed.
local COMMANDS = {}

function COMMANDS.new(chat, _, command)
  local ok, result = acp.call(chat.ws, chat.agent, "new_session", { command = command })
  if not ok then
    say(("/%s: %s"):format(command, call_error(result)), vim.log.levels.ERROR)
  end
  return ok
end

COMMANDS.clear = COMMANDS.new

function COMMANDS.resume(chat, rest)
  if rest == "" then
    M.history(chat)
    return true
  end
  local ok, result = acp.call(chat.ws, chat.agent, "resume", { id = rest })
  if not ok then
    say("/resume: " .. call_error(result), vim.log.levels.ERROR)
  end
  return ok
end

function COMMANDS.fork(chat, rest)
  M.fork(chat, nil, rest)
  return true
end

-- Answers the box waiting on you, as Claude's prompt takes a number: text is an option's number
-- (several, space between, for a multi question), yes or no for a permission, or your own words
-- for a question that takes them. The first of its questions not yet answered gets it. Returns
-- whether it was an answer (else the text is a prompt), and why not when it was meant as one.
---@return boolean answered, string? err
function M.answer(chat, text, box)
  box = box or chat.boxes[1]
  if not box then
    return false
  end
  local surfaces = require("isovim.surfaces")
  local which, entry
  for i, name in ipairs(box.names) do
    local each = surfaces.get(box.repo, name)
    if each and each.type == "question" and not each.answer then
      which, entry = i, each
      break
    end
  end
  if not entry then
    return false
  end
  local words = vim.split(vim.trim(text), "[%s,]+", { trimempty = true })
  local numbers = #words > 0 and vim.iter(words):all(function(word)
    return tonumber(word) ~= nil
  end)
  local value
  if box.kind == "permission" then
    local lower = vim.trim(text):lower()
    if lower == "1" or lower == "y" or lower == "yes" then
      value = "Allow"
    elseif lower == "2" or lower == "n" or lower == "no" then
      value = "Deny"
    else
      return false
    end
  elseif numbers then
    local labels = {}
    for _, word in ipairs(words) do
      local label = box.options[which][tonumber(word)]
      if not label then
        return true, ("%s isn't one of its options (1-%d)"):format(word, #box.options[which])
      end
      labels[#labels + 1] = label
    end
    if #labels > 1 and not box.multi[which] then
      return true, "it takes one option"
    end
    value = { labels = labels }
  elseif box.other[which] then
    value = { labels = {}, other = vim.trim(text) }
  else
    return false
  end
  local answer, err = surfaces.answer(entry, value)
  if not answer then
    return true, err
  end
  to_bottom(chat)
  return true
end

-- The composer: your draft, the buffer's lines from the conversation's end on.

local function draft(chat)
  return vim.api.nvim_buf_get_lines(chat.buf, chat.lines, -1, false)
end

-- What you've typed in the agent's composer (to keep it over a restart, isovim.update).
function M.draft(chat)
  return draft(chat)
end

-- Puts win's cursor at the end of your draft.
local function to_draft(chat, win)
  local last = vim.api.nvim_buf_line_count(chat.buf)
  vim.api.nvim_win_set_cursor(win, { last, #(vim.api.nvim_buf_get_lines(chat.buf, last - 1, last, false)[1] or "") })
  if win == vim.api.nvim_get_current_win() then
    vim.bo[chat.buf].modifiable = true
  end
end

-- The draft's undo (see the top): a state is recorded each time it differs from the last, after a
-- change in normal mode and once an insert ends.
local UNDO_MAX = 200

local function record(chat)
  local undo, lines = chat.undo, draft(chat)
  if #lines == 0 or vim.deep_equal(lines, undo.states[undo.at]) then
    return
  end
  for i = #undo.states, undo.at + 1, -1 do
    undo.states[i] = nil
  end
  undo.states[#undo.states + 1] = lines
  if #undo.states > UNDO_MAX then
    table.remove(undo.states, 1)
  end
  undo.at = #undo.states
end

-- Puts lines in the composer in place of your draft (a prompt sent, recalled, put back to rewind,
-- or a draft kept over a restart); u brings back what was there.
function M.set_draft(chat, lines)
  record(chat)
  writable(chat.buf, function()
    vim.api.nvim_buf_set_lines(chat.buf, chat.lines, -1, false, lines)
  end)
  record(chat)
  decorate(chat)
end

-- u and <C-r> (count times): the draft as it was before or after, the cursor at the start of the
-- first line that differs, as vim's undo puts it.
local function step(chat, dir)
  record(chat)
  local undo = chat.undo
  local at = math.max(1, math.min(#undo.states, undo.at + dir * vim.v.count1))
  if at == undo.at then
    return vim.api.nvim_echo({ { dir < 0 and "Already at oldest change" or "Already at newest change" } }, false, {})
  end
  local before, after = undo.states[undo.at], undo.states[at]
  undo.at = at
  writable(chat.buf, function()
    vim.api.nvim_buf_set_lines(chat.buf, chat.lines, -1, false, after)
  end)
  local row = 1
  while row < #after and before[row] == after[row] do
    row = row + 1
  end
  vim.api.nvim_win_set_cursor(0, { chat.lines + row, 0 })
  decorate(chat)
end

-- Sends what's in the composer and empties it; on failure the text stays and you're told why.
-- During a rewind it's the rewound prompt's new text. While a permission or question waits on you,
-- an answer to it (a number, yes or no, your own words for a question) answers it instead.
function M.submit(buf)
  local chat = by_buf(buf)
  if not chat then
    return
  end
  local text = vim.trim(table.concat(draft(chat), "\n"))
  if text == "" then
    return
  end
  if chat.thread or chat.pending_title then
    return M.post_thread(chat, text)
  end
  if chat.rewind then
    local ok, result = acp.call(chat.ws, chat.agent, "rewind", { id = chat.rewind.id, text = text })
    if not ok then
      return say("could not rewind: " .. call_error(result), vim.log.levels.ERROR)
    end
    chat.rewind = nil
    M.set_draft(chat, { "" })
    update_bar(chat)
    return to_bottom(chat)
  end
  local command, rest = text:match("^/(%a+)%s*(.-)$")
  if not command and #chat.boxes > 0 then
    local answered, err = M.answer(chat, text)
    if answered then
      if err then
        return say("could not answer: " .. err, vim.log.levels.WARN)
      end
      M.set_draft(chat, { "" })
      return
    end
  end
  if command and COMMANDS[command] then
    if COMMANDS[command](chat, rest, command) then
      chat.recall = nil
      M.set_draft(chat, { "" })
    end
    return
  end
  local attached
  text, attached = images.collect(chat.buf, text)
  local ok, result = acp.call(chat.ws, chat.agent, "prompt", { text = text, images = attached })
  if not ok then
    vim.notify("isovim: could not send to " .. chat.agent .. ": " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  chat.recall = nil
  M.set_draft(chat, { "" })
  to_bottom(chat)
end

-- <Up>/<Down> in an empty composer (or one showing an earlier prompt) walk your earlier prompts.
local function recall(chat, dir)
  local text = table.concat(draft(chat), "\n")
  local showing = chat.recall and chat.history[chat.recall] == text
  if text ~= "" and not showing then
    return false
  end
  local index = showing and chat.recall + dir or (dir < 0 and #chat.history or nil)
  if not index or index < 1 then
    return true
  end
  chat.recall = index <= #chat.history and index or nil
  local shown = chat.recall and vim.split(chat.history[chat.recall], "\n", { plain = true }) or { "" }
  M.set_draft(chat, shown)
  images.set(chat.buf, chat.recall and chat.history_images[chat.history[chat.recall]])
  vim.api.nvim_win_set_cursor(0, { chat.lines + #shown, #shown[#shown] })
  return true
end

-- Puts you in the agent's composer, in insert mode at the end of your draft: in the window you're
-- in if it shows the chat, else the first that does.
function M.focus_composer(ws, agent)
  local chat = M.get(ws, agent)
  if not chat then
    return false
  end
  local win = vim.api.nvim_get_current_buf() == chat.buf and vim.api.nvim_get_current_win() or vim.fn.bufwinid(chat.buf)
  if win == -1 then
    return false
  end
  -- Modifiable before the window is entered, or entering it would leave insert mode (init.lua).
  vim.bo[chat.buf].modifiable = true
  to_draft(chat, win)
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert({ bang = true })
  pcall(to_end, win)
  return true
end

-- The buffer is modifiable only while the cursor, and in visual mode the selection's other end, is
-- in the composer; typing that gets up into the conversation (a click, <C-o>k) stops there.
local function guard_cursor(chat, event)
  if vim.api.nvim_get_current_buf() ~= chat.buf or chat.edit_from then
    return
  end
  local row = vim.fn.line(".")
  local mode = vim.api.nvim_get_mode().mode
  -- Come into from another buffer while typing (a thread opened from a chat's composer): typing
  -- goes on at the end of the draft, the cursor there rather than on the conversation's top line.
  if (event == "BufEnter" or event == "WinEnter") and mode:sub(1, 1) == "i" and row <= chat.lines then
    to_draft(chat, vim.api.nvim_get_current_win())
    return
  end
  if mode:find("^[vVsS\22\19]") then
    row = math.min(row, vim.fn.line("v"))
  end
  local mine = row > chat.lines
  if vim.bo[chat.buf].modifiable ~= mine then
    vim.bo[chat.buf].modifiable = mine
  end
  if not mine and (mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R") then
    vim.cmd.stopinsert()
  end
end

local remake

-- A change reached the conversation: it's drawn again from the journal, your draft as it was
-- before that change.
local function repair(chat)
  if chat.dead or not vim.api.nvim_buf_is_valid(chat.buf) then
    return
  end
  vim.cmd.stopinsert()
  remake(chat, chat.undo.states[chat.undo.at])
  say("the conversation is read-only: put back as it was", vim.log.levels.WARN)
end

-- Catches a change of yours that reaches the conversation, as it happens: one that starts above
-- the conversation's last line, or changes it. The drawing's own (edit) are let be.
local function guard(chat)
  local token = {}
  chat.guard = token
  vim.api.nvim_buf_attach(chat.buf, false, {
    on_bytes = function(_, buf, _, row)
      if chat.dead or chat.guard ~= token then
        return true
      end
      if chat.edit_from or chat.broken then
        return
      end
      local last = row >= chat.lines - 1 and vim.api.nvim_buf_get_lines(buf, chat.lines - 1, chat.lines, false)[1]
      if last ~= chat.last then
        chat.broken = true
        safe.schedule("putting the conversation back", function()
          repair(chat)
        end)
      end
    end,
  })
end

-- After a change of yours: the composer keeps a line (dd on its only one), the draft's state is
-- recorded for undo (in normal mode; an insert's once it ends), and it's drawn again. One the
-- drawing made is let be.
local function changed(chat, typing)
  local buf = chat.buf
  if chat.broken or chat.dead or chat.edit_from or vim.api.nvim_buf_get_changedtick(buf) == chat.tick then
    return
  end
  if vim.api.nvim_buf_line_count(buf) <= chat.lines then
    writable(buf, function()
      vim.api.nvim_buf_set_lines(buf, chat.lines, chat.lines, false, { "" })
    end)
    if vim.api.nvim_get_current_buf() == buf then
      to_draft(chat, vim.api.nvim_get_current_win())
    end
  end
  if not typing then
    record(chat)
  end
  decorate(chat)
end

-- Keys that start typing (see the top). One a plugin has mapped (LazyVim's s and S are flash's
-- jumps) is left to it.
local TYPING = { "i", "a", "o", "O", "I", "A", "c", "s", "C", "S", "R", "gi", "gI" }
local TYPING_VISUAL = { "c", "s", "C", "S", "R", "I", "A" }

-- Keys that change text: on the conversation each says, quietly, that it's read-only (M.read_only)
-- instead of vim's E21; in the composer they're vim's own.
local EDITING = { "d", "D", "x", "X", "p", "P", "J", "gJ", "r", "~", ">", "<", "=", "g~", "gu", "gU", "g?", "&", ".",
  "<C-a>", "<C-x>", "<Del>" }
local EDITING_VISUAL = { "d", "D", "x", "X", "p", "P", "J", "gJ", "r", "~", ">", "<", "=", "u", "U", "g?", "<C-a>",
  "<C-x>", "<Del>" }

-- An edit tried on the conversation: one quiet line, at most every few seconds.
local told_at = -math.huge
function M.read_only()
  if vim.uv.now() - told_at > 3000 then
    told_at = vim.uv.now()
    vim.api.nvim_echo({ { "the conversation is read-only: i to write in your draft", "IsovimAcpHint" } }, false, {})
  end
end

local function global_maps(mode)
  local lhs = {}
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    lhs[map.lhs] = true
  end
  return lhs
end

local function map_keys(chat)
  local buf = chat.buf
  local function map(modes, lhs, fn, desc, opts)
    vim.keymap.set(modes, lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true, desc = "isovim: " .. desc }, opts or {}))
  end
  local function mine()
    return in_draft(chat)
  end
  local to_composer = ("<Cmd>lua require('isovim.acp.chat').focus_composer(%q, %q)<CR>"):format(chat.ws, chat.agent)
  -- Not nowait, so a longer map that starts with one (surround's cs) still gets its keys.
  local taken = global_maps("n")
  local rename = "<Cmd>lua require('isovim.acp.chat').rename_thread()<CR>"
  for _, lhs in ipairs(TYPING) do
    -- A thread's R on the conversation renames it.
    local thread_rename = lhs == "R" and (chat.thread or chat.pending_title)
    if not taken[lhs] then
      map("n", lhs, function()
        return mine() and lhs or (thread_rename and rename or to_composer)
      end, thread_rename and "rename the thread (in the composer: replace mode)"
        or "type to the agent (from the conversation: at the end of your draft)", { expr = true, nowait = false })
    end
  end
  taken = global_maps("x")
  for _, lhs in ipairs(TYPING_VISUAL) do
    if not taken[lhs] then
      map("x", lhs, function()
        return math.min(vim.fn.line("."), vim.fn.line("v")) > chat.lines and lhs or "<Esc>" .. to_composer
      end, "type to the agent (from the conversation: at the end of your draft)", { expr = true, nowait = false })
    end
  end
  local refuse = "<Cmd>lua require('isovim.acp.chat').read_only()<CR>"
  local resolve = "<Cmd>lua require('isovim.acp.chat').resolve_thread()<CR>"
  for _, lhs in ipairs(EDITING) do
    local thread_r = lhs == "r" and (chat.thread or chat.pending_title)
    map("n", lhs, function()
      return mine() and lhs or (thread_r and resolve or refuse)
    end, thread_r and "resolve the thread, or open it again (in the composer: replace a character)"
      or "edit (in the composer; the conversation is read-only)", { expr = true, nowait = false })
  end
  for _, lhs in ipairs(EDITING_VISUAL) do
    map("x", lhs, function()
      return math.min(vim.fn.line("."), vim.fn.line("v")) > chat.lines and lhs or refuse
    end, "edit (in the composer; the conversation is read-only)", { expr = true, nowait = false })
  end
  map("n", "]]", function()
    jump(chat, 1, true)
  end, "your next prompt")
  map("n", "[[", function()
    jump(chat, -1, true)
  end, "your previous prompt")
  map("n", "]m", function()
    jump(chat, 1, false)
  end, "next message")
  map("n", "[m", function()
    jump(chat, -1, false)
  end, "previous message")
  map("n", "<CR>", function()
    if mine() then
      return M.submit(buf)
    end
    -- On an [Image #n] chip in the conversation: that image, as a tab (isovim.image).
    if require("isovim.image").open_chip(chat) then
      return
    end
    -- On an option of a box waiting on you: that's the answer.
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local mark = vim.api.nvim_buf_get_extmarks(buf, OPTIONS, { row, 0 }, { row, -1 }, {})[1]
    local option = mark and chat.options[mark[1]]
    if option then
      local box = option.box
      local name = box.names[option.surface]
      local surfaces = require("isovim.surfaces")
      local entry = name and surfaces.get(box.repo, name)
      if not entry or entry.answer then
        return say("that question isn't waiting any more")
      end
      local label = box.options[option.surface][option.n]
      local answer, err = surfaces.answer(entry, box.multi[option.surface] and { labels = { label } } or label)
      if not answer then
        say("could not answer: " .. tostring(err), vim.log.levels.WARN)
      end
      return
    end
    M.focus_composer(chat.ws, chat.agent)
  end, "send the draft; on the conversation, answer with the option under the cursor or open the [Image #n] under it, else type to the agent")
  map("i", "<CR>", function()
    M.submit(buf)
  end, "send to the agent")
  -- A new line without sending: <CR> here is the key's own, not the mapping above. <M-CR> for a
  -- terminal that sends <S-CR> as <CR>.
  map("i", "<S-CR>", "<CR>", "new line")
  map("i", "<M-CR>", "<CR>", "new line")
  -- At the composer's very start these would join its first line onto the conversation's last.
  for _, lhs in ipairs({ "<BS>", "<C-w>", "<C-u>" }) do
    map("i", lhs, function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      return (row == chat.lines + 1 and col == 0) and "" or lhs
    end, "delete before the cursor, back to the composer's start", { expr = true })
  end
  map({ "n", "i" }, "<C-c>", function()
    if chat.renaming then
      local before = chat.renaming
      chat.renaming = nil
      M.set_draft(chat, before)
      return update_bar(chat)
    elseif chat.rewind then
      chat.rewind = nil
      M.set_draft(chat, { "" })
      return update_bar(chat)
    end
    cancel(chat)
  end, "cancel the agent's turn (or the rewind you're editing)")
  for _, key_dir in ipairs({ { "<Up>", -1 }, { "<Down>", 1 } }) do
    map({ "n", "i" }, key_dir[1], function()
      if mine() and recall(chat, key_dir[2]) then
        return
      end
      -- Typing, up from the composer's first line stays put: the conversation isn't for typing in.
      if vim.fn.mode() == "i" and key_dir[2] < 0 and vim.fn.line(".") == chat.lines + 1 then
        return
      end
      vim.api.nvim_feedkeys(vim.keycode(key_dir[1]), "n", false)
    end, "earlier prompts while the composer is empty")
  end
  for _, lhs in ipairs({ "u", "g-" }) do
    -- A thread's u on the conversation marks it unread; in the draft it's the draft's undo.
    local thread_u = lhs == "u" and chat.thread
    map("n", lhs, function()
      if thread_u and not mine() then
        return M.thread_unread(chat)
      end
      step(chat, -1)
    end, thread_u and "mark the thread unread (in the composer: undo)" or "undo in the composer")
  end
  for _, lhs in ipairs({ "<C-r>", "g+" }) do
    map("n", lhs, function()
      step(chat, 1)
    end, "redo in the composer")
  end
  map({ "n", "i" }, "<C-j>", function()
    if not mine() then
      return M.focus_composer(chat.ws, chat.agent)
    end
    local win = queue.window(chat)
    if win then
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(win)
    end
  end, "down: from the conversation to the composer, from the composer to the queue while it shows")
  map({ "n", "i" }, "<C-k>", function()
    if not mine() then
      return vim.cmd.wincmd("k")
    end
    vim.cmd.stopinsert()
    vim.api.nvim_win_set_cursor(0, { chat.lines, 0 })
  end, "up: from the composer to the conversation's end")
  for _, cmd in ipairs({ "za", "zo", "zc" }) do
    map("n", cmd, function()
      fold(chat, cmd)
    end, "fold the tool call under the cursor")
  end
  -- Normal mode only: in insert mode <C-o> is vim's, one normal command from the draft.
  map("n", "<C-o>", function()
    toggle_all(chat)
  end, "open every tool call's output and thought, or collapse them all")
  -- An iso: link under the cursor opens its target (isovim.links, which maps <Tab> too).
  map("n", "gf", function()
    local addr = require("isovim.links").at_cursor()
    if addr then
      return require("isovim.links").open(addr)
    end
    open_file(chat)
  end, "open the file on the line as a tab")
  require("isovim").map_to_sidebar(buf, { "n", "i" })
end

-- The chat's, the queue's and the composer's keys, for the help (`?` in the sidebar).
M.help_keys = {
  chat = {
    { "]] / [[", "your next / previous prompt" },
    { "]m / [m", "the next / previous message" },
    { "za zo zc", "fold the tool call's output under the cursor" },
    { "<C-o>", "open every tool call's output and thought, or collapse them all (those to come too)" },
    { "i a o O I A c C <CR>", "on the conversation: to the end of your draft, typing (<CR> on a box's option answers with it)" },
    { "u / <C-r>", "undo / redo in the composer, never the conversation" },
    { "<C-c>", "cancel the agent's turn (or the rewind you're editing)" },
    { "<C-j> / <C-k>", "down to the composer, then the queue while it shows / up from the composer to the conversation" },
    { "<C-h>", "the sidebar, in insert mode too (<C-l> there comes back)" },
  },
  queue = {
    { "edit, :w", "edit, reorder or delete lines; :w makes it the queue" },
    { "<CR>", "send the prompt on the line now (cancels the turn)" },
    { "q", "hide the queue until another prompt queues" },
    { "<C-k>", "up to the composer" },
    { "<C-h>", "the sidebar, in insert mode too (<C-l> there comes back)" },
    { "<leader>iq", "go to the queue, opening it even when empty" },
  },
  thread = {
    { "<CR>", "in its composer: post to the router (a new thread's first <CR> takes its title)" },
    { "r", "on the thread: resolve it, or open it again" },
    { "u", "on the thread: mark it unread, back in the Inbox until you open it again (in the composer, undo)" },
    { "1 <CR>", "while the router's question waits: its number (or an option's name) in the composer answers it; <CR> on an option too" },
    { "R", "on the thread (or :IsovimThreadRename): rename it, its title in the composer (<CR> renames, <C-c> keeps it); r in the sidebar too" },
    { "t / <leader>it", "a new thread: t on a repo's (or agent's) row in the sidebar, <leader>it in the current repo" },
    { "", "otherwise as a chat: insert keys go to the draft, u undoes it, ]] [[ your posts" },
  },
  composer = {
    { "<CR>", "send (queued while the agent works)" },
    { "<S-CR> / <M-CR>", "a new line" },
    { "<Up> / <Down>", "your earlier prompts while it's empty" },
    { "<C-v>", "paste the clipboard's image as an [Image #n] chip" },
    { "<C-h>", "the sidebar, in insert mode too, in place of backspace (<BS>); <C-l> there comes back typing" },
  },
}

-- The chat's window options, for any window that shows it.
local function chat_window(win)
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.breakindent, wo.breakindentopt = true, true, true, "list:-1"
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn, wo.foldcolumn = false, false, "no", "", "0"
  wo.list, wo.spell, wo.colorcolumn, wo.foldenable = false, false, "", false
  -- Scrolled by screen rows, so a line longer than the window still shows its end. No scrolloff:
  -- only you and following move the view, never nvim chasing the cursor to keep rows around it.
  wo.smoothscroll, wo.scrolloff = true, 0
  wo.fillchars = "eob: "
  -- Markdown's marks (`code`, **bold**) hidden, as Claude draws them, on the cursor's line too.
  wo.conceallevel, wo.concealcursor = 2, "nc"
end

-- The composer as Claude's prompt (see the top), drawn again whenever its lines, its bar or its
-- hint change.
local COMPOSER = vim.api.nvim_create_namespace("isovim_acp_composer")
local RULE_LINE = { { RULE, "IsovimAcpRule" } }

local function composer_hint(chat)
  if chat.pending_title then
    return "  <CR> starts the thread with this title · then your first post · <C-h> the sidebar"
  elseif chat.thread and #chat.boxes > 0 then
    return "  its number (or an option's name) and <CR> answers · anything else posts · <CR> on an option above"
  elseif chat.thread then
    return "  <CR> posts to the router · <S-CR> new line · <C-v> image · on the thread: r resolves it, u marks it unread · <C-h> the sidebar"
  end
  local around = (queue.window(chat) and "<C-j> the queue · " or "") .. "<C-k> the chat · <C-h> the sidebar"
  if #chat.boxes > 0 then
    return "  type its number and <CR> to answer · or <CR> on an option above · <leader>in the Inbox"
  elseif chat.busy then
    return "  <CR> queues it · <C-c> interrupts · " .. (queue.window(chat) and around or "<leader>iq the queue · " .. around)
  end
  -- Where to go before what to type, so a narrow window cuts the latter.
  return "  <CR> send · <S-CR> new line · <C-v> image · " .. around .. " · <Up> earlier prompts · /new /resume /fork"
end

decorate = function(chat)
  local buf = chat.buf
  if chat.edit_from or chat.backlog or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local first, count = chat.lines, vim.api.nvim_buf_line_count(buf)
  if count <= first then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, COMPOSER, 0, -1)
  local bar = { { " " } }
  vim.list_extend(bar, M.bar_parts(chat))
  vim.api.nvim_buf_set_extmark(buf, COMPOSER, first, 0, { virt_lines = { { { "" } }, bar, RULE_LINE },
    virt_lines_above = true, virt_lines_leftcol = true })
  for row = first, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, COMPOSER, row, 0, { virt_text = { { row == first and "❯ " or "  ",
      "IsovimAcpComposerGlyph" } }, virt_text_pos = "inline", right_gravity = false })
  end
  vim.api.nvim_buf_set_extmark(buf, COMPOSER, count - 1, 0,
    { virt_lines = { RULE_LINE, { { composer_hint(chat), "IsovimAcpHint" } } }, virt_lines_leftcol = true })
  if count - first == 1 and vim.api.nvim_buf_get_lines(buf, first, count, false)[1] == "" and chat.pending_title then
    vim.api.nvim_buf_set_extmark(buf, COMPOSER, first, 0, { virt_text = { { "The thread's title…", "IsovimAcpHint" } },
      virt_text_pos = "overlay" })
  elseif count - first == 1 and vim.api.nvim_buf_get_lines(buf, first, count, false)[1] == "" and chat.thread then
    vim.api.nvim_buf_set_extmark(buf, COMPOSER, first, 0, { virt_text = { { ("Post in %s…"):format(chat.title or chat.thread),
      "IsovimAcpHint" } }, virt_text_pos = "overlay" })
  elseif count - first == 1 and vim.api.nvim_buf_get_lines(buf, first, count, false)[1] == "" then
    vim.api.nvim_buf_set_extmark(buf, COMPOSER, first, 0, { virt_text = { { ("Message %s…"):format(agent_name(chat)),
      "IsovimAcpHint" } }, virt_text_pos = "overlay" })
  end
end

-- The chat's autocmds, so a hot reload can take them off its buffer.
local GROUP = vim.api.nvim_create_augroup("isovim_acp_chat", { clear = false })
-- The old code's, which kept the composer's window in its place under the chat.
pcall(vim.api.nvim_del_augroup_by_name, "isovim_acp_column")

-- The options and variables of a chat's buffer.
-- A thread's surface's base, as isovim.surfaces lists it.
local function thread_base(chat)
  return "threads/" .. chat.thread .. ".jsonl"
end

-- A thread's view is a chat whose agent is "thread:<id>" ("thread:new" before it has a title).
local function thread_of(agent)
  return agent:match("^thread:(t%d+)$"), agent == "thread:new"
end

local function setup_buffer(ws, agent, name, buf)
  vim.bo[buf].filetype = "isovim_acp"
  -- Wrapped lines line up under the text after their glyph.
  vim.bo[buf].formatlistpat = [[^\s*\(❯\|⏺\|✻\|⎿\)\s\+]]
  local thread, pending = thread_of(agent)
  if thread or pending then
    -- A tab ranked with the surfaces (isovim.tabs), in its repo's scope; not an agent's.
    vim.b[buf].isovim_ws, vim.b[buf].isovim_scope = ws, ws
    vim.b[buf].isovim_surface = ws .. "/" .. (thread or "new thread")
    vim.b[buf].isovim_agent_kind, vim.b[buf].isovim_acp = "thread", true
  else
    vim.b[buf].isovim_id, vim.b[buf].isovim_ws, vim.b[buf].isovim_agent = ws, ws, agent
    vim.b[buf].isovim_agent_name, vim.b[buf].isovim_agent_kind, vim.b[buf].isovim_acp = name, "claude", true
  end
  vim.bo[buf].buflisted = true
  -- No smooth scrolling: its animation moves the cursor after a jump (so a key right after one acts
  -- on a line it passes through), and it lags a chat that follows its end; the same for
  -- mini.animate (LazyVim's mini-animate extra), which animates scrolls and cursor moves. No indent
  -- guides.
  vim.b[buf].snacks_scroll, vim.b[buf].snacks_indent = false, false
  vim.b[buf].minianimate_disable = true
  -- No completion menu, whose keys would take <Up>, <Down> and <CR> (blink.cmp reads this).
  vim.b[buf].completion = false
  -- No undo of nvim's: the composer keeps its own (see the top).
  vim.bo[buf].undolevels = -1
end

-- A chat's state, drawn into buf: an empty conversation (its placeholder line) and lines, the
-- composer's.
local function new_chat(ws, agent, buf, lines)
  local spec = store.agent(ws, agent) or {}
  lines = lines and #lines > 0 and lines or { "" }
  local chat = { ws = ws, agent = agent, buf = buf, tools = {}, queue = {}, history = {}, history_images = {}, seq = 0,
    fresh = true, busy = false, handover = false, marks = {}, boxes = {}, options = {}, kind = spec.kind or "claude",
    lines = 1, last = "", undo = { states = { lines }, at = 1 } }
  chat.thread, chat.pending_title = thread_of(agent)
  chat.pending_title = chat.pending_title or nil
  for _, ns in ipairs({ NS, TOOLS, MESSAGES, MINE, MD, BOXES, OPTIONS, COMPOSER }) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", unpack(lines) })
  return chat
end

-- The chat's autocmds and keys on its buffer. A hot reload takes them off (unbind) and binds them
-- again with its own code.
local function bind(chat)
  local ws, agent, buf = chat.ws, chat.agent, chat.buf
  images.setup(buf, store.path(ws) .. "/images", {
    first = function()
      local each = by_buf(buf)
      return each and each.lines or 0
    end,
    enter = function()
      local each = by_buf(buf)
      if each then
        to_draft(each, vim.api.nvim_get_current_win())
      end
    end,
  })
  -- Window options follow the buffer into any window that shows it (a layout rebuilt, :b), and its
  -- queue window under each (later, as a chat being opened is still placing windows; windows
  -- placed inside another autocmd, as selecting a workspace rebuilds its layout, fire none:
  -- isovim.layout calls M.settle).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the chat's window", function()
      -- Every window showing it: the one it entered needn't be current (isovim.show sets a
      -- window's buffer before going to it), and that one kept its numbers.
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        chat_window(win)
      end
      -- A thread come back to: what you marked unread is read again.
      if chat.thread then
        require("isovim.surfaces").opened(ws, thread_base(chat))
      end
      update_bar(chat)
      M.settle(chat)
    end),
  })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "WinClosed" }, {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the chat's queue window", function()
      M.settle(chat)
    end),
  })
  -- Scrolled or moved: whether each window follows, and shows the composer.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the chat's follow", function()
      note_followers(chat)
      set_unseen(chat)
    end),
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged", "BufEnter", "WinEnter" }, {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the composer's guard", function(ev)
      guard_cursor(chat, ev.event)
    end),
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the composer's look", function()
      changed(chat, false)
    end),
  })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the composer's look", function()
      changed(chat, true)
    end),
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = GROUP,
    buffer = buf,
    callback = safe.wrap("the composer's undo", function()
      record(chat)
    end),
  })
  map_keys(chat)
  -- Its links' <Tab>, chips drawn again on coming back, yanks giving addresses (isovim.links),
  -- written as the drawing writes the conversation.
  require("isovim.links").attach(buf, function(fn)
    edit(chat, fn)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = buf,
    once = true,
    callback = safe.wrap("closing the chat", function()
      chat.stop()
      if chats[key(ws, agent)] == chat then
        chats[key(ws, agent)] = nil
      end
      safe.schedule("closing the chat", function()
        queue.close(ws, agent)
      end)
    end),
  })
  -- Its tab closed (Snacks.bufdelete, :bd) unloads it rather than wiping it, and an unloaded
  -- buffer forgets it's a scratch one: opened again it came back empty, as a file with a swap
  -- (E325 when another nvim held one) that kept isovim from restarting. The chat goes whole
  -- instead, queue too, as a surface's view does; opening it again draws it afresh.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = GROUP,
    buffer = buf,
    callback = function()
      safe.schedule("closing the chat", function()
        if chats[key(ws, agent)] == chat and not vim.api.nvim_buf_is_loaded(buf) then
          M.close(ws, agent)
        end
      end)
    end,
  })
end

-- Takes off what bind put on the chat's buffer (and an old composer's), and what an isovim from
-- before GROUP put there (it had none).
local function unbind(chat, composer)
  for _, buf in ipairs({ chat.buf, composer }) do
    for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
      if au.group == nil or au.group == GROUP then
        vim.api.nvim_del_autocmd(au.id)
      end
    end
    for _, mode in ipairs({ "n", "i", "x" }) do
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if vim.startswith(map.desc or "", "isovim: ") then
          pcall(vim.api.nvim_buf_del_keymap, buf, mode, map.lhs)
        end
      end
    end
  end
end

-- Follows the agent's journal from its start, or from where an old follower got to (from), and its
-- supervisor. While the chat has a backlog (a hot reload drawing it again) entries wait there, and
-- the supervisor is subscribed to once it's swapped in.
local function follow(chat, from)
  local ws, agent = chat.ws, chat.agent
  if chat.pending_title then
    chat.stop, chat.drain, chat.journal_at = function()
      chat.dead = true
    end, function() end, function()
      return 0
    end
    return
  elseif chat.thread then
    -- A thread's file, not a journal; no supervisor to subscribe to.
    local stop, at, drain = threads.follow(ws, chat.thread, safe.wrap("the thread", function(entry)
      ingest(chat, entry, false)
    end), safe.wrap("the thread", function()
      start_over(chat)
    end), from)
    chat.drain, chat.journal_at = drain, at
    chat.stop = function()
      chat.dead = true
      stop()
    end
    return
  end
  -- Each entry on its own, so one that fails to draw doesn't stop the rest.
  chat.stop, chat.drain, chat.journal_at = journal.follow(ws, agent, safe.wrap("the chat's journal", function(entry)
    if chat.backlog then
      chat.backlog[#chat.backlog + 1] = entry
    else
      ingest(chat, entry, false)
    end
  end), safe.wrap("the chat's journal", function()
    if chat.backlog then
      chat.backlog, chat.backlog_at = {}, 1
    end
    start_over(chat)
  end), function(read)
    batch(chat, read)
  end, from)
  if not chat.backlog then
    subscribe(chat)
  end
  -- What the journal can't say: whether the supervisor is still at it (it may have died mid-turn).
  local ok, state = acp.call(ws, agent, "status")
  if ok and type(state) == "table" then
    chat.busy, chat.handover = state.busy == true, state.handover == true
  else
    chat.busy = false
  end
  -- A supervisor that comes back (a restart, a handover's end) is subscribed to again.
  chat.timer = vim.uv.new_timer()
  chat.timer:start(1000, 1000, safe.ticker("the chat's subscription", function()
    if not chat.dead and not chat.backlog and vim.api.nvim_buf_is_loaded(chat.buf) then
      subscribe(chat)
    end
  end))
  local stop = chat.stop
  chat.unfollow = stop
  chat.stop = function()
    chat.dead = true
    stop()
    if chat.timer and not chat.timer:is_closing() then
      chat.timer:stop()
      chat.timer:close()
    end
    if chat.chan then
      pcall(vim.fn.chanclose, chat.chan)
      chat.chan = nil
    end
  end
end

-- A new chat, or with old (a repair, an old code's chat) the same chat made again on old's buffer
-- and drawn again. lines are the composer's to begin with.
local function make(ws, agent, old, lines)
  local spec = store.agent(ws, agent) or {}
  local name = (spec.name or agent)
  local thread, pending = thread_of(agent)
  local buf = old and old.buf or scratch(thread and ("isovim-thread://%s/%s"):format(ws, thread)
    or pending and ("isovim-thread://%s/new"):format(ws) or ("isovim-acp://%s/%s · %s"):format(ws, agent, name))
  setup_buffer(ws, agent, name, buf)
  local chat = new_chat(ws, agent, buf, lines)
  if thread or pending then
    thread_tab(chat)
  end
  bind(chat)
  follow(chat)
  guard(chat)
  decorate(chat)
  return chat
end

-- Soon (once whatever is placing windows is done): each chat's queue window under each window
-- showing it (isovim.acp.queue), or chat's alone.
---@param chat? isovim.acp.Chat
function M.settle(chat)
  vim.schedule(function()
    for _, each in pairs(chat and { chat } or chats) do
      if not each.dead and vim.api.nvim_buf_is_loaded(each.buf) then
        safe.wrap("the chat's queue window", queue.sync)(each)
        safe.wrap("the chat's bar", update_bar)(each)
      end
    end
  end)
end

---@return isovim.acp.Chat?
function M.get(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat and vim.api.nvim_buf_is_loaded(chat.buf) then
    return chat
  end
end

-- Opens (or collapses) the output of the tool call whose line is row (0-based).
function M.set_open(ws, agent, row, open)
  local chat = M.get(ws, agent)
  for _, call in pairs(chat and chat.tools or {}) do
    if call.mark and vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1] == row then
      call.open = open
      draw_tool(chat, call)
      return true
    end
  end
  return false
end

-- The chat a buffer belongs to.
---@return isovim.acp.Chat?
function M.of_buf(buf)
  return by_buf(buf or vim.api.nvim_get_current_buf())
end

-- Shows the agent's chat in win, at its end; coming from another buffer, with the cursor at the
-- end of your draft.
---@return isovim.acp.Chat
function M.open(ws, agent, win)
  local chat = M.get(ws, agent)
  if not chat then
    M.close(ws, agent)
    chat = make(ws, agent)
    chats[key(ws, agent)] = chat
  end
  local shown = vim.api.nvim_win_get_buf(win) == chat.buf
  vim.api.nvim_win_set_buf(win, chat.buf)
  if not shown then
    to_draft(chat, win)
  end
  pcall(to_end, win)
  set_unseen(chat)
  update_bar(chat)
  M.settle(chat)
  return chat
end

-- The supervisor replaced the journal (a session switch): read it again from the start.
M.reload = safe.wrap("the chat's journal", function(ws, agent)
  local chat = not safe.reloading() and chats[key(ws, agent)]
  if chat then
    chat.rewind = nil
    chat.drain()
  end
end)

-- The message at or above row (0-based): its mark's entry info; only your prompts with mine.
local function message_at(chat, row, mine)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, MESSAGES, { row, 0 }, 0, {})) do
    local info = chat.marks[mark[1]]
    if info and info.seq and (not mine or info.mine) then
      return info
    end
  end
end

-- The chat you're in, and the row the cursor is on in its conversation (nil in the composer).
local function here()
  local chat = by_buf(vim.api.nvim_get_current_buf())
  if not chat then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return chat, row < chat.lines and row or nil
end

-- <leader>iu: your prompt under the cursor (in the composer, your last) goes into the composer to
-- edit; sending it rewinds there (isovim.acp.host's rewind).
function M.rewind_at_cursor()
  local chat, row = here()
  if chat and (chat.thread or chat.pending_title) then
    return say("rewind: a thread is a view of its router's chat; rewind there")
  elseif not chat then
    return say("rewind: put the cursor on one of your prompts in an ACP agent's chat")
  end
  local info = message_at(chat, row or chat.lines - 1, true)
  if not info or info.kind ~= "prompt" or not info.id then
    return say("rewind: no prompt of yours at or above the cursor")
  end
  chat.rewind = { id = info.id, text = info.text or "" }
  M.set_draft(chat, vim.split(info.text or "", "\n", { plain = true }))
  M.focus_composer(chat.ws, chat.agent)
  update_bar(chat)
  return chat.rewind
end

-- <leader>if: a fork of the agent at the message under the cursor (in the composer, all of it).
function M.fork_at_cursor()
  local chat, row = here()
  if chat and (chat.thread or chat.pending_title) then
    return say("fork: a thread is a view of its router's chat; fork that")
  elseif not chat then
    return say("fork: open an ACP agent's chat first")
  end
  local info = row and message_at(chat, row, false) or nil
  if row and not info then
    return say("fork: no message at or above the cursor")
  end
  M.fork(chat, info and info.seq or nil)
end

-- The tool calls and thoughts drawn in the chat, top to bottom.
placed = function(chat)
  local calls = vim.tbl_filter(function(call)
    return call.mark ~= nil
  end, vim.tbl_values(chat.tools or {}))
  local function row(call)
    return vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1] or -1
  end
  table.sort(calls, function(a, b)
    return row(a) < row(b)
  end)
  return calls
end

-- old's choice of which calls show their output (opened, by place, and <C-o>'s), on chat drawn again
-- from the same journal, as one change.
local function keep_open(chat, old, opened)
  chat.all_open = old.all_open
  edit(chat, function()
    for i, call in ipairs(placed(chat)) do
      if call.open ~= opened[i] or chat.all_open ~= nil then
        call.open = opened[i]
        draw_tool(chat, call)
      end
    end
  end)
end

-- The chat made again by the current code on its own buffer (its keys, autocmds and drawing then
-- run it), drawn again from its journal: after a hot reload (M.rebind), or a change that reached
-- the conversation (repair). What the journal doesn't hold is kept: where each window was scrolled,
-- a cursor in the composer at its place in your draft, the draft and its undo, the tool calls you
-- opened or collapsed, a rewind you're editing. lines, if given, are the draft instead (a repair:
-- the cursor goes to its end). A chat of the old code, whose composer was a buffer of its own,
-- gives that buffer's text (and images) to the one buffer, and the composer and its window go.
remake = function(old, lines)
  local k = key(old.ws, old.agent)
  local composer = old.composer and old.composer ~= old.buf and vim.api.nvim_buf_is_valid(old.composer) and old.composer or nil
  local count = old.lines or vim.api.nvim_buf_line_count(old.buf)
  local repairing = lines ~= nil
  lines = lines or (composer and vim.api.nvim_buf_get_lines(composer, 0, -1, false))
    or vim.api.nvim_buf_get_lines(old.buf, count, -1, false)
  local views, at, opened, follows = {}, {}, {}, {}
  for _, win in ipairs(vim.fn.win_findbuf(old.buf)) do
    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    follows[win] = vim.w[win].isovim_follows
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    if row > count then
      at[win] = { row - count, col }
    end
  end
  local current = vim.api.nvim_get_current_win()
  if composer and vim.api.nvim_win_get_buf(current) == composer and vim.fn.bufwinid(old.buf) ~= -1 then
    local win = vim.fn.bufwinid(old.buf)
    at[win] = vim.api.nvim_win_get_cursor(current)
    vim.api.nvim_set_current_win(win)
  end
  for i, call in ipairs(placed(old)) do
    opened[i] = call.open
  end
  pcall(old.stop)
  old.dead = true
  unbind(old, composer)
  if composer then
    images.move(composer, old.buf)
    pcall(vim.api.nvim_buf_delete, composer, { force = true })
  end
  local chat = make(old.ws, old.agent, old, lines)
  chat.rewind, chat.recall = old.rewind, old.recall
  if old.undo and vim.deep_equal(old.undo.states[old.undo.at], draft(chat)) then
    chat.undo = old.undo
  end
  keep_open(chat, old, opened)
  chats[k] = chat
  local count_now = vim.api.nvim_buf_line_count(chat.buf)
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == chat.buf then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
      if repairing and win == vim.api.nvim_get_current_win() then
        to_draft(chat, win)
      elseif at[win] then
        pcall(vim.api.nvim_win_set_cursor, win, { math.min(chat.lines + at[win][1], count_now), at[win][2] })
      end
      -- One that followed the end goes on following it, past what came while it was made again.
      if follows[win] then
        pcall(to_end, win)
      end
    end
  end
  guard_cursor(chat)
  update_bar(chat)
  M.settle(chat)
  return chat
end

-- Hot reloads' redraws, waiting their turn: each chat is drawn again by the new code into a buffer
-- of its own, a few milliseconds at a time so your keys never wait on it, while the old chat goes on
-- as it was; once it's done, its conversation takes the old one's place in the chat's buffer, under
-- which your draft stays as it is (isovim.tabs, windows and layout keep the buffer). In _G, so a
-- reload during one drops it.
_G.isovim_acp_builds = _G.isovim_acp_builds or {}
local builds = _G.isovim_acp_builds
local BUDGET = 8e6 -- ns of drawing per turn of the loop

local function drop(build)
  if build.chat.stop then
    pcall(build.chat.stop)
  end
  pcall(vim.api.nvim_buf_delete, build.chat.buf, { force = true })
  build.old.retiring = nil
end

-- The chat drawn again in its own buffer takes old's place: its conversation's lines and marks
-- (their ids kept, as the chat's places refer to them) replace old's, above old's draft.
local function swap(build)
  local old, chat = build.old, build.chat
  local k = key(old.ws, old.agent)
  if chats[k] ~= old or old.dead or not vim.api.nvim_buf_is_loaded(old.buf) then
    return drop(build)
  end
  local hidden, buf, count = chat.buf, old.buf, old.lines
  local views, at, opened = {}, {}, {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = { view = vim.api.nvim_win_call(win, vim.fn.winsaveview), follows = vim.w[win].isovim_follows }
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    if row > count then
      at[win] = { row - count, col }
    end
  end
  for i, call in ipairs(placed(old)) do
    opened[i] = call.open
  end
  pcall(old.stop)
  old.dead = true
  unbind(old)
  local namespaces = vim.tbl_values(M.ns)
  for _, ns in ipairs(namespaces) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, count)
  end
  writable(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, count, false, vim.api.nvim_buf_get_lines(hidden, 0, chat.lines, false))
  end)
  for _, ns in ipairs(namespaces) do
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(hidden, ns, 0, -1, { details = true })) do
      local opts = mark[4]
      opts.ns_id, opts.id = nil, mark[1]
      vim.api.nvim_buf_set_extmark(buf, ns, mark[2], mark[3], opts)
    end
  end
  pcall(vim.api.nvim_buf_delete, hidden, { force = true })
  chat.buf, chat.backlog, chat.backlog_at = buf, nil, nil
  chat.last = vim.api.nvim_buf_get_lines(buf, chat.lines - 1, chat.lines, false)[1] or ""
  chat.tick = vim.api.nvim_buf_get_changedtick(buf)
  chat.rewind, chat.recall, chat.undo = old.rewind, old.recall, old.undo or chat.undo
  keep_open(chat, old, opened)
  bind(chat)
  guard(chat)
  chats[k] = chat
  subscribe(chat)
  decorate(chat)
  local last = vim.api.nvim_buf_line_count(buf)
  for win, was in pairs(views) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      if at[win] then
        pcall(vim.api.nvim_win_set_cursor, win, { math.min(chat.lines + at[win][1], last), at[win][2] })
      end
      if was.follows then
        pcall(to_end, win)
      elseif not at[win] then
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(was.view)
        end)
      end
    end
  end
  guard_cursor(chat)
  queue.refresh(chat)
  set_unseen(chat)
  update_bar(chat)
  M.settle(chat)
end

local ingest_safely = safe.wrap("the chat's journal", function(chat, entry)
  ingest(chat, entry, false)
end)

local pump
pump = safe.wrap("drawing the chats again", function()
  -- Nothing can be drawn under textlock (E565): shortly.
  if safe.text_locked() then
    return vim.defer_fn(pump, 50)
  end
  local start = vim.uv.hrtime()
  while builds[1] do
    local chat = builds[1].chat
    -- Its journal read in its own turn, not all of them at once in the reload's.
    if not chat.stop then
      follow(chat)
    end
    local over = false
    batch(chat, function()
      while chat.backlog[chat.backlog_at] and not over do
        ingest_safely(chat, chat.backlog[chat.backlog_at])
        chat.backlog_at = chat.backlog_at + 1
        over = vim.uv.hrtime() - start > BUDGET
      end
    end)
    if over then
      return vim.defer_fn(pump, 1)
    end
    swap(table.remove(builds, 1))
  end
end)

-- After a hot reload the open chats take the new code. Their keys, autocmds, guard and journal
-- follower are bound again, which is all it takes while the chat's drawing (this file,
-- isovim.acp.look) is what drew them. When it changed (redraw), each is drawn again (builds above),
-- those on screen first. A chat of the old code, whose composer was a buffer of its own, is made
-- again at once (remake).
function M.rebind(redraw)
  -- Under textlock nothing can be drawn (E565): shortly.
  if safe.text_locked() then
    return vim.defer_fn(function()
      require("isovim.acp.chat").rebind(redraw)
    end, 50)
  end
  for _, build in ipairs(builds) do
    drop(build)
  end
  for i = #builds, 1, -1 do
    builds[i] = nil
  end
  local spinner = _G.isovim_acp_spinner
  if spinner and not spinner:is_closing() then
    spinner:close()
  end
  _G.isovim_acp_spinner = nil
  local broken = {}
  for _, old in ipairs(vim.tbl_values(chats)) do
    local composer = old.composer and old.composer ~= old.buf and old.composer or nil
    -- One whose tab was closed before the code that closes it whole (its buffer unloaded, or
    -- loaded again as a file) is closed, and opened afresh where it shows.
    local intact = vim.api.nvim_buf_is_loaded(old.buf) and vim.bo[old.buf].buftype == "nofile"
      and (not composer or vim.api.nvim_buf_is_loaded(composer) and vim.bo[composer].buftype == "nofile")
    if not intact then
      broken[#broken + 1] = { old = old, composer = composer, win = vim.fn.bufwinid(old.buf) }
    elseif composer then
      remake(old)
    elseif not redraw or old.thread or old.pending_title then
      local from = old.journal_at and old.journal_at()
      pcall(old.stop)
      old.dead = nil
      unbind(old)
      bind(old)
      follow(old, from)
      guard(old)
      decorate(old)
      update_bar(old)
    else
      local hidden = vim.api.nvim_create_buf(false, true)
      local chat = new_chat(old.ws, old.agent, hidden)
      chat.backlog, chat.backlog_at = {}, 1
      old.retiring = true
      table.insert(builds, vim.fn.bufwinid(old.buf) ~= -1 and 1 or #builds + 1, { old = old, chat = chat })
    end
  end
  if builds[1] then
    vim.defer_fn(pump, 1)
  end
  -- The fresh one goes into its window before the old buffers are wiped, so the window stays.
  for _, each in ipairs(broken) do
    local old = each.old
    pcall(old.stop)
    old.dead = true
    chats[key(old.ws, old.agent)] = nil
    queue.close(old.ws, old.agent)
    unbind(old, each.composer)
    for _, buf in ipairs({ old.buf, each.composer }) do
      pcall(vim.api.nvim_buf_set_name, buf, vim.api.nvim_buf_get_name(buf) .. " (closing)")
    end
    if each.win ~= -1 and vim.api.nvim_win_is_valid(each.win) then
      safe.wrap("opening the chat again", M.open)(old.ws, old.agent, each.win)
    end
    if each.composer then
      pcall(vim.api.nvim_buf_delete, each.composer, { force = true })
    end
    pcall(vim.api.nvim_buf_delete, old.buf, { force = true })
  end
end

-- Threads (isovim.threads): a thread's view is this chat on its file, its composer posting to it.

-- The user has read what the thread's view shows, while a window shows it: a router post they had
-- not seen no longer waits on them.
function M.thread_seen(chat)
  if chat.thread and not chat.dead and vim.fn.bufwinid(chat.buf) ~= -1
    and threads.mark_seen(chat.ws, chat.thread, chat.seq) then
    local surfaces = package.loaded["isovim.surfaces"]
    if surfaces then
      surfaces.recheck()
    end
  end
end

-- u on a thread's conversation: back in the Inbox until you open it again. One resolved isn't
-- listed, so there's nothing to go back to.
function M.thread_unread(chat)
  if chat.resolved then
    return vim.api.nvim_echo({ { "it's resolved: r opens it again", "Comment" } }, false, {})
  end
  require("isovim.surfaces").mark_unread({ repo = chat.ws, type = "thread", base = thread_base(chat) })
end

-- Shows the chat as a tab in the main window (isovim.show), at its end, typing in its composer.
local function show_thread(chat)
  local win = vim.fn.bufwinid(chat.buf)
  if win == -1 then
    win = require("isovim").show(chat.buf)
  end
  chat_window(win)
  vim.api.nvim_set_current_win(win)
  M.focus_composer(chat.ws, chat.agent)
  update_bar(chat)
  M.settle(chat)
  M.thread_seen(chat)
  return chat
end

-- Opens thread id of repo; at its question qid, if given (from the Inbox).
function M.open_thread(repo, id, qid)
  local agent = "thread:" .. id
  local chat = M.get(repo, agent)
  if not chat then
    if not vim.uv.fs_stat(threads.file(repo, id)) then
      return say(("%s has no thread %s"):format(repo, id), vim.log.levels.WARN)
    end
    chat = make(repo, agent)
    chats[key(repo, agent)] = chat
  end
  show_thread(chat)
  local box = qid and vim.iter(chat.boxes):find(function(each)
    return each.id == id .. "-" .. qid
  end)
  local at = box and vim.api.nvim_buf_get_extmark_by_id(chat.buf, BOXES, box.mark, {})[1]
  if at then
    -- In normal mode on the question, its options under the cursor.
    vim.schedule(function()
      vim.cmd.stopinsert()
      local win = vim.fn.bufwinid(chat.buf)
      if win ~= -1 then
        pcall(vim.api.nvim_win_set_cursor, win, { at + 1, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zt")
        end)
      end
    end)
  end
  return chat
end

-- A new thread in repo: its view opens with the composer asking for its title first.
function M.new_thread(repo)
  local why = threads.refusal(repo)
  if why then
    return say("no thread: " .. why, vim.log.levels.WARN)
  end
  local chat = M.get(repo, "thread:new")
  if not chat then
    chat = make(repo, "thread:new")
    chats[key(repo, "thread:new")] = chat
  end
  return show_thread(chat)
end

-- <CR> in a thread's composer: its title (a new thread), else a post, sent to the router as a
-- prompt tagged with the thread (its supervisor posts the turn's last message back).
function M.post_thread(chat, text)
  if chat.renaming then
    local title, err = threads.rename(chat.ws, chat.thread, "user", text)
    if not title then
      return say("not renamed: " .. tostring(err), vim.log.levels.WARN)
    end
    local before = chat.renaming
    chat.renaming = nil
    M.set_draft(chat, before)
    return update_bar(chat)
  elseif chat.pending_title then
    local id, err = threads.new(chat.ws, text, "user")
    if not id then
      return say("no thread: " .. tostring(err), vim.log.levels.WARN)
    end
    M.set_draft(chat, { "" })
    -- It becomes the thread's view: keyed, named and bound as one.
    pcall(chat.stop)
    chats[key(chat.ws, chat.agent)] = nil
    unbind(chat)
    chat.agent, chat.thread, chat.pending_title, chat.dead = "thread:" .. id, id, nil, nil
    chats[key(chat.ws, chat.agent)] = chat
    pcall(vim.api.nvim_buf_set_name, chat.buf, ("isovim-thread://%s/%s"):format(chat.ws, id))
    vim.b[chat.buf].isovim_surface = chat.ws .. "/" .. id
    bind(chat)
    follow(chat)
    update_bar(chat)
    return
  elseif chat.resolved then
    return say("this thread is resolved: r on it opens it again", vim.log.levels.WARN)
  end
  -- While a question waits: a bare number (several, for a multi one), an option's label, or the
  -- own-words number then words answers it; anything else is a post.
  local box = chat.boxes[1]
  if box then
    local labels, answer = box.options[1], nil
    local words = vim.split(text, "[%s,]+", { trimempty = true })
    local n, rest = text:match("^(%d+)%s+(.+)$")
    if n and tonumber(n) == #labels + 1 and box.other[1] then
      answer = rest
    elseif vim.iter(words):all(function(word)
      return tonumber(word) ~= nil
    end) or vim.iter(labels):any(function(label)
      return label:lower() == text:lower()
    end) then
      answer = text
    end
    if answer then
      local answered, err = M.answer(chat, answer, box)
      if answered then
        if err then
          return say("could not answer: " .. err, vim.log.levels.WARN)
        end
        return M.set_draft(chat, { "" })
      end
    end
  end
  local attached
  text, attached = images.collect(chat.buf, text)
  local post, err = threads.post(chat.ws, chat.thread, "user", text, attached)
  if not post then
    return say("could not post: " .. tostring(err), vim.log.levels.ERROR)
  end
  chat.recall = nil
  M.set_draft(chat, { "" })
  to_bottom(chat)
  local router = store.router(chat.ws)
  if not router then
    return say(chat.ws .. " has no router to send it to; it's kept in the thread", vim.log.levels.WARN)
  end
  local cmd = { require("isovim.panes").bin, "send", router }
  for _, image in ipairs(attached or {}) do
    vim.list_extend(cmd, { "--image", image.path })
  end
  cmd[#cmd + 1] = threads.prompt(chat.ws, chat.thread, chat.title or chat.thread, text)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      say(("posted, but %s wasn't told: %s"):format(router, vim.trim(result.stderr or "")), vim.log.levels.WARN)
    end
  end))
end

-- R on a thread's conversation (or :IsovimThreadRename): its title in the composer to edit, <CR>
-- renaming it, <C-c> keeping it; what you were writing comes back either way.
function M.rename_thread()
  local chat = by_buf(vim.api.nvim_get_current_buf())
  if not (chat and chat.thread) then
    return say("rename: open a thread first")
  end
  if not chat.renaming then
    chat.renaming = draft(chat)
  end
  M.set_draft(chat, { chat.title or "" })
  M.focus_composer(chat.ws, chat.agent)
  update_bar(chat)
end

vim.api.nvim_create_user_command("IsovimThreadRename", function()
  require("isovim.acp.chat").rename_thread()
end, { desc = "isovim: rename the thread on screen" })

-- r on a thread's conversation: resolved by you, or opened again.
function M.resolve_thread()
  local chat = by_buf(vim.api.nvim_get_current_buf())
  if not (chat and chat.thread) then
    return
  end
  local status, err = threads.resolve(chat.ws, chat.thread, "user", nil, chat.resolved ~= nil)
  if not status then
    say(tostring(err), vim.log.levels.WARN)
  end
end

-- The agent went away: its chat and queue go too.
function M.close(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat then
    chat.stop()
    chats[key(ws, agent)] = nil
    queue.close(ws, agent)
    if vim.api.nvim_buf_is_valid(chat.buf) then
      pcall(vim.api.nvim_buf_delete, chat.buf, { force = true })
    end
  end
end

return M
