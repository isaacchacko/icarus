-- An ACP agent's chat: a buffer drawn from its journal (isovim.acp.journal) to look like Claude's
-- screen, and a composer below it whose text goes to the agent's supervisor over its socket when
-- sent, so nothing an agent sends ever lands in what you're typing. The TUI and iso attach
-- (isovim.acp.attach) both show it.
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
-- in every window and in iso attach, and needs no window state. The view follows new output in a
-- window that shows the chat's end (the last row of its last line, however many rows it wraps
-- over), its end kept on the window's bottom row; wherever its cursor is while you're in the
-- composer, on the last line while you're in the chat. One scrolled up, or whose cursor you moved
-- up, stays where it is, and the composer's bar says there's more below until a window shows the
-- end again; sending a prompt or an answer takes every window to the end. The composer is Claude's
-- prompt: its bar is Claude's spinner line while the agent works (glyph, verb, time, tokens, <C-c>
-- to interrupt) and says how many prompts wait; a rule above and below it, ❯ before it and a hint
-- under it. While prompts wait, the queue shows in a window of its own between the chat and the
-- composer (isovim.acp.queue), where you can edit it. The column stays chat, queue, composer, the
-- composer a fixed height (M.settle).
--
-- Chat keys: ]] [[ your own prompts, ]m [m any message, za zo zc the output of the tool call under
-- the cursor, i a o the composer, <CR> too (or, on a box's option, that answer), <C-c> cancels the
-- turn, gf the file on the line. Composer keys: <CR> sends (queued while the agent works; an answer
-- while a box waits on you), <S-CR> (or <M-CR>) a new line, <C-c> cancels the turn, <Up> <Down>
-- your earlier prompts while it's empty, <Esc> normal mode. <C-j> and <C-k> walk down and up the
-- column, chat → queue (while it shows) → composer, in normal mode in the chat and the queue and in
-- both modes in the composer; <C-j> in the composer does nothing, as nothing is below it.
-- <C-h> goes to the sidebar from all three, in insert mode too (<BS> is the backspace; <C-l> there
-- comes back typing). <C-v> pastes an image (isovim.acp.images). <leader>iq goes to the queue,
-- opening it even when empty.
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
local store = require("isovim.store")

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
---@field open? boolean opened (za) or collapsed by you; nil: as it shows by default (a diff open)
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
---@field buf integer
---@field composer integer
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
---@field unseen boolean output arrived below where you're looking
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
  callback = function(ev)
    if ev.event == "OptionSet" and ev.match ~= "background" then
      return
    end
    look.highlights()
  end,
})

local function key(ws, agent)
  return ws .. "/" .. agent
end

local function by_buf(buf)
  for _, chat in pairs(chats) do
    if chat.buf == buf or chat.composer == buf then
      return chat
    end
  end
end

local update_bar

-- The rows from win's top to its buffer's end, filler lines in; more than its height while the end
-- is below it. Lines alone don't say: a long line wraps over many rows, and its last ones can be
-- below the window while its start is on screen.
function M.rows_to_end(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local ok, rows = pcall(vim.api.nvim_win_text_height, win, { start_row = view.topline - 1, start_vcol = view.skipcol })
  return ok and view.topfill + rows.all or 0
end

local function shows_end(win)
  return M.rows_to_end(win) <= vim.api.nvim_win_get_height(win)
end

-- The view of win with its buffer's last row on its bottom row: up from the end, whole lines while
-- they fit, then the rows of the next that do (smoothscroll's skipcol) or of the filler above it.
function M.end_view(win)
  local left = vim.api.nvim_win_get_height(win)
  local row = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - 1
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

-- Windows that keep following the chat's end: those that show it, wherever their cursor is (yours
-- is in the composer), except the one you're in once you've moved its cursor off the last line.
local function followers(buf)
  local last, current = vim.api.nvim_buf_line_count(buf), vim.api.nvim_get_current_win()
  return vim.tbl_filter(function(win)
    return shows_end(win) and (win ~= current or vim.api.nvim_win_get_cursor(win)[1] == last)
  end, vim.fn.win_findbuf(buf))
end

-- Puts the end of the chat on win's bottom row, the cursor on it. Set here: nvim keeps only the
-- cursor's row on screen, and in a window that isn't current may not move its view at all.
local function to_end(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local view = M.end_view(win)
  view.lnum = vim.api.nvim_buf_line_count(buf)
  view.col = #vim.api.nvim_buf_get_lines(buf, view.lnum - 1, view.lnum, false)[1]
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end)
  vim.w[win].isovim_follows = true
end

-- A window that follows keeps the end on its bottom row when it changes size: the queue's window
-- opening above the composer takes the chat's rows.
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("isovim_acp_chat_follow", { clear = true }),
  callback = function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      local chat = vim.api.nvim_win_is_valid(win) and vim.w[win].isovim_follows and by_buf(vim.api.nvim_win_get_buf(win))
      if chat and chat.buf == vim.api.nvim_win_get_buf(win) then
        pcall(to_end, win)
      end
    end
  end,
})

-- Records which windows follow (for a resize), as you move or scroll them.
local function note_followers(buf)
  local follow = followers(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.w[win].isovim_follows = vim.tbl_contains(follow, win)
  end
end

-- Whether output sits below what every window showing the chat shows; the composer's bar says so.
local function set_unseen(chat)
  local wins = vim.fn.win_findbuf(chat.buf)
  local unseen = #wins > 0 and #vim.tbl_filter(shows_end, wins) == 0
  if unseen ~= chat.unseen then
    chat.unseen = unseen
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

-- Changes the buffer with fn. Windows at the bottom stay there.
local function edit(chat, fn)
  local buf = chat.buf
  local follow = followers(buf)
  vim.bo[buf].modifiable = true
  fn(buf)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.tbl_contains(follow, win) then
      pcall(to_end, win)
    else
      vim.w[win].isovim_follows = false
    end
  end
  set_unseen(chat)
end

-- The row after the last line of the conversation.
local function body_end(chat)
  return vim.api.nvim_buf_line_count(chat.buf)
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
local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
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
  local dir = store.agent_dir(chat.ws, chat.agent)
  return { dir, vim.uv.fs_realpath(dir) or dir }
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

-- Streams the agent's text onto the end of the conversation, a new message after anything else;
-- its lines after the first are indented under the glyph.
local function add_text(chat, text)
  if chat.block ~= "agent" then
    local row = add_block(chat, { GLYPH.message .. " " })
    span(chat.buf, row, 0, #GLYPH.message, "IsovimAcpMessage")
    mark_message(chat, row, false)
    chat.block, chat.block_row, chat.at_start = "agent", row, true
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
  end)
end

-- Tool calls, thinking: blocks drawn in place, whose output collapses (za)

---@param call isovim.acp.ToolCall
local function is_open(call, kind, count)
  if call.open ~= nil then
    return call.open
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
  local row = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
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
  local open = is_open(call, kind, #rows)
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
    if not call.hidden then
      local row = add_block(chat, { "" })
      call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, row, 0, {})
    end
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

function RENDER.prompt(chat, entry)
  -- Sent now: it leaves the queue.
  local before = #chat.queue
  chat.queue = vim.tbl_filter(function(item)
    return item.id ~= entry.id
  end, chat.queue)
  if #chat.queue ~= before then
    queue.refresh(chat)
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
  mark_message(chat, row, mine)
  if mine and entry.text and chat.history[#chat.history] ~= entry.text then
    chat.history[#chat.history + 1] = entry.text
  end
  if mine and entry.images then
    chat.history_images[entry.text] = entry.images
  end
end

function RENDER.queued(chat, entry)
  chat.queue[#chat.queue + 1] = { id = entry.id or "", text = entry.text or "" }
  queue.refresh(chat)
end

function RENDER.queue(chat, entry)
  chat.queue = vim.tbl_map(function(item)
    return { id = item.id, text = item.text or "" }
  end, entry.items or {})
  queue.refresh(chat)
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
function M.bar_parts(chat)
  local parts = {}
  local function add(text, hl)
    parts[#parts + 1] = { text, hl }
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
    local spec = store.agent(chat.ws, chat.agent) or {}
    add(GLYPH.prompt .. " " .. (spec.name or chat.agent), "IsovimAcpIdle")
  end
  if #chat.queue > 0 then
    add((" · %d queued"):format(#chat.queue), "IsovimAcpSpinnerNote")
  end
  if chat.unseen then
    add(" · ↓ more below", "IsovimAcpSpinnerNote")
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
    if chat.busy and vim.api.nvim_buf_is_valid(chat.buf) then
      return true
    end
  end
  return false
end

update_bar = function(chat)
  if not vim.api.nvim_buf_is_valid(chat.composer) then
    return
  end
  local bar = " "
  for _, part in ipairs(M.bar_parts(chat)) do
    bar = bar .. "%#" .. part[2] .. "#" .. part[1]:gsub("%%", "%%%%")
  end
  for _, win in ipairs(vim.fn.win_findbuf(chat.composer)) do
    vim.wo[win][0].winbar = bar
  end
  if M.decorate_composer then
    M.decorate_composer(chat)
  end
  -- In _G, so a hot reload can stop the one the old code started.
  if any_busy() and not _G.isovim_acp_spinner then
    local spinner = vim.uv.new_timer()
    _G.isovim_acp_spinner = spinner
    spinner:start(100, 100, vim.schedule_wrap(function()
      frame = frame % #FRAMES + 1
      local busy = false
      for _, each in pairs(chats) do
        if each.busy and vim.api.nvim_buf_is_valid(each.composer) then
          busy = true
          update_bar(each)
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
  if not vim.api.nvim_buf_is_valid(chat.buf) then
    return
  end
  local draw = RENDER[entry.kind]
  if draw then
    chat.entry = entry
    draw(chat, entry)
    chat.entry = nil
  end
  update_bar(chat)
end

-- Takes an entry once, in order: one pushed ahead of what's been read (a gap) reads the journal.
local function ingest(chat, entry, pushed)
  local seq = tonumber(entry.seq) or 0
  if seq <= chat.seq then
    return
  end
  if pushed and seq > chat.seq + 1 then
    return chat.drain()
  end
  chat.seq = seq
  render(chat, entry)
end

-- An entry the supervisor pushed (isovim.acp.host, to every subscribed chat).
function M.push(ws, agent, entry)
  local chat = chats[key(ws, agent)]
  if chat and type(entry) == "table" then
    ingest(chat, entry, true)
  end
end

local function reset(chat)
  chat.block, chat.tools, chat.queue, chat.history, chat.seq, chat.fresh = nil, {}, {}, {}, 0, true
  chat.history_images = {}
  chat.marks, chat.boxes, chat.options, chat.thought = {}, {}, {}, nil
  chat.busy, chat.handover = false, false
  if vim.api.nvim_buf_is_valid(chat.buf) then
    for _, ns in ipairs({ NS, TOOLS, MESSAGES, MINE, MD, BOXES, OPTIONS }) do
      vim.api.nvim_buf_clear_namespace(chat.buf, ns, 0, -1)
    end
    edit(chat, function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)
  end
  queue.refresh(chat)
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

local function cancel(chat)
  local ok, result = acp.call(chat.ws, chat.agent, "cancel")
  if not ok then
    vim.notify("isovim: could not cancel " .. chat.agent .. ": " .. tostring(result), vim.log.levels.ERROR)
  elseif not result.cancelled then
    vim.notify("isovim: " .. chat.agent .. " isn't working", vim.log.levels.INFO)
  end
end

-- The file named on the cursor's line (path, path:12), beside the chat.
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
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = true
  vim.api.nvim_open_win(buf, true, { split = "right", win = vim.api.nvim_get_current_win() })
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), 0 })
  end
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

-- Sends what's in the composer and empties it; on failure the text stays and you're told why.
-- During a rewind it's the rewound prompt's new text. While a permission or question waits on you,
-- an answer to it (a number, yes or no, your own words for a question) answers it instead.
function M.submit(composer)
  local chat = by_buf(composer)
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(composer, 0, -1, false), "\n"))
  if not chat or text == "" then
    return
  end
  if chat.rewind then
    local ok, result = acp.call(chat.ws, chat.agent, "rewind", { id = chat.rewind.id, text = text })
    if not ok then
      return say("could not rewind: " .. call_error(result), vim.log.levels.ERROR)
    end
    chat.rewind = nil
    vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "" })
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
      vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "" })
      return
    end
  end
  if command and COMMANDS[command] then
    if COMMANDS[command](chat, rest, command) then
      chat.recall = nil
      vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "" })
    end
    return
  end
  local attached
  text, attached = images.collect(composer, text)
  local ok, result = acp.call(chat.ws, chat.agent, "prompt", { text = text, images = attached })
  if not ok then
    vim.notify("isovim: could not send to " .. chat.agent .. ": " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  chat.recall = nil
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "" })
  to_bottom(chat)
end

-- <Up>/<Down> in an empty composer (or one showing an earlier prompt) walk your earlier prompts.
local function recall(chat, dir)
  local lines = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
  local text = table.concat(lines, "\n")
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
  vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, shown)
  images.set(chat.composer, chat.recall and chat.history_images[chat.history[chat.recall]])
  vim.api.nvim_win_set_cursor(0, { #shown, #shown[#shown] })
  return true
end

local function map_chat(chat)
  local buf = chat.buf
  local function map(lhs, fn, desc)
    -- nowait: global ]x/[x maps would otherwise hold these back for 'timeoutlen'.
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "isovim: " .. desc })
  end
  map("]]", function()
    jump(chat, 1, true)
  end, "your next prompt")
  map("[[", function()
    jump(chat, -1, true)
  end, "your previous prompt")
  map("]m", function()
    jump(chat, 1, false)
  end, "next message")
  map("[m", function()
    jump(chat, -1, false)
  end, "previous message")
  for _, lhs in ipairs({ "i", "a", "o" }) do
    map(lhs, function()
      M.focus_composer(chat.ws, chat.agent)
    end, "type to the agent")
  end
  map("<CR>", function()
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
  end, "answer with the option under the cursor, else type to the agent")
  map("<C-c>", function()
    cancel(chat)
  end, "cancel the agent's turn")
  for _, cmd in ipairs({ "za", "zo", "zc" }) do
    map(cmd, function()
      fold(chat, cmd)
    end, "fold the tool call under the cursor")
  end
  map("gf", function()
    open_file(chat)
  end, "open the file on the line beside the chat")
  map("<C-j>", function()
    local win = queue.window(chat)
    if win then
      return vim.api.nvim_set_current_win(win)
    end
    M.focus_composer(chat.ws, chat.agent)
  end, "down to the queue while it shows, else the composer")
  require("isovim").map_to_sidebar(buf)
end

local function map_composer(chat)
  local buf = chat.composer
  local function map(modes, lhs, fn, desc, opts)
    vim.keymap.set(modes, lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true, desc = "isovim: " .. desc }, opts or {}))
  end
  map({ "n", "i" }, "<CR>", function()
    M.submit(buf)
  end, "send to the agent")
  -- A new line without sending: <CR> here is the key's own, not the mapping above. <M-CR> for a
  -- terminal that sends <S-CR> as <CR>.
  map("i", "<S-CR>", "<CR>", "new line")
  map("i", "<M-CR>", "<CR>", "new line")
  -- Nothing is below the composer: <C-j>, which walks down the column, stays.
  map({ "n", "i" }, "<C-j>", "<Nop>", "nothing below the composer")
  map({ "n", "i" }, "<C-c>", function()
    if chat.rewind then
      chat.rewind = nil
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      return update_bar(chat)
    end
    cancel(chat)
  end, "cancel the agent's turn (or the rewind you're editing)")
  for _, key_dir in ipairs({ { "<Up>", -1 }, { "<Down>", 1 } }) do
    map({ "n", "i" }, key_dir[1], function()
      if not recall(chat, key_dir[2]) then
        vim.api.nvim_feedkeys(vim.keycode(key_dir[1]), "n", false)
      end
    end, "earlier prompts while the composer is empty")
  end
  map({ "n", "i" }, "<C-k>", function()
    vim.cmd.stopinsert()
    local win = queue.window(chat) or vim.fn.bufwinid(chat.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end, "up to the queue while it shows, else the chat")
  require("isovim").map_to_sidebar(buf, { "n", "i" })
end

-- The chat's, the queue's and the composer's keys, for the help (`?` in the sidebar).
M.help_keys = {
  chat = {
    { "]] / [[", "your next / previous prompt" },
    { "]m / [m", "the next / previous message" },
    { "za zo zc", "fold the tool call's output under the cursor" },
    { "i a o <CR>", "type to the agent (<CR> on a box's option answers with it)" },
    { "<C-c>", "cancel the agent's turn" },
    { "<C-j>", "down to the queue while it shows, else the composer" },
    { "<C-h>", "the sidebar, on the row you left (<C-l> there comes back)" },
  },
  queue = {
    { "edit, :w", "edit, reorder or delete lines; :w makes it the queue" },
    { "<CR>", "send the prompt on the line now (cancels the turn)" },
    { "q", "hide the queue until another prompt queues" },
    { "<C-k> / <C-j>", "up to the chat / down to the composer" },
    { "<C-h>", "the sidebar, in insert mode too (<C-l> there comes back)" },
    { "<leader>iq", "go to the queue, opening it even when empty" },
  },
  composer = {
    { "<CR>", "send (queued while the agent works)" },
    { "<S-CR> / <M-CR>", "a new line" },
    { "<Up> / <Down>", "your earlier prompts while it's empty" },
    { "<C-c>", "cancel the turn (or the rewind you're editing)" },
    { "<C-k>", "up to the queue while it shows, else the chat" },
    { "<C-j>", "nothing: the composer is the bottom" },
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

-- The composer as Claude's prompt: a rule above and below it, ❯ before its first line, a hint
-- under it, and what to type while it's empty. Redrawn as you type (the rule below follows the
-- last line).
local COMPOSER = vim.api.nvim_create_namespace("isovim_acp_composer")
local RULE_LINE = { { ("─"):rep(400), "IsovimAcpRule" } }

-- The rule above the first line shows only while the window keeps a filler line at its top.
local function show_top_rule(chat)
  for _, win in ipairs(vim.fn.win_findbuf(chat.composer)) do
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      if view.topline == 1 and (view.topfill or 0) < 1 then
        view.topfill = 1
        vim.fn.winrestview(view)
      end
    end)
  end
end

local function composer_hint(chat)
  local up = (queue.window(chat) and "<C-k> the queue" or "<C-k> the chat") .. " · <C-h> the sidebar"
  if #chat.boxes > 0 then
    return "  type its number and <CR> to answer · or <CR> on an option in the chat · <leader>in the Inbox"
  elseif chat.busy then
    return "  <CR> queues it · <C-c> interrupts · " .. (queue.window(chat) and up or "<leader>iq the queue · " .. up)
  end
  -- Where to go before what to type, so a narrow window cuts the latter.
  return "  <CR> send · <S-CR> new line · <C-v> image · " .. up .. " · <Up> earlier prompts · /new /resume /fork"
end

local function decorate_composer(chat)
  local buf = chat.composer
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local hint = composer_hint(chat)
  local empty = last == 0 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  local drawn = table.concat({ hint, last, tostring(empty) }, "|")
  if chat.composer_drawn == drawn and #vim.api.nvim_buf_get_extmarks(buf, COMPOSER, 0, -1, { limit = 1 }) > 0 then
    return show_top_rule(chat)
  end
  chat.composer_drawn = drawn
  vim.api.nvim_buf_clear_namespace(buf, COMPOSER, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, COMPOSER, 0, 0, { virt_lines = { RULE_LINE }, virt_lines_above = true,
    virt_lines_leftcol = true })
  vim.api.nvim_buf_set_extmark(buf, COMPOSER, last, 0,
    { virt_lines = { RULE_LINE, { { hint, "IsovimAcpHint" } } }, virt_lines_leftcol = true })
  if empty then
    local spec = store.agent(chat.ws, chat.agent) or {}
    vim.api.nvim_buf_set_extmark(buf, COMPOSER, 0, 0, { virt_text = { { ("Message %s…"):format(spec.name or chat.agent),
      "IsovimAcpHint" } }, virt_text_pos = "overlay" })
  end
  show_top_rule(chat)
end
M.decorate_composer = decorate_composer

local function composer_window(win)
  local wo = vim.wo[win][0]
  wo.winfixheight, wo.number, wo.relativenumber, wo.wrap = true, false, false, true
  wo.signcolumn, wo.foldcolumn, wo.fillchars = "no", "0", "eob: "
  wo.statuscolumn = "%#IsovimAcpComposerGlyph#%{v:lnum == 1 && v:virtnum == 0 ? '❯ ' : '  '}"
  wo.breakindent = false
end

-- The chat's autocmds, so a hot reload can take them off its buffers.
local GROUP = vim.api.nvim_create_augroup("isovim_acp_chat", { clear = false })

-- A new chat, or with old (a hot reload) the same chat made again on old's buffers and drawn again.
local function make(ws, agent, old)
  local spec = store.agent(ws, agent) or {}
  local name = (spec.name or agent)
  local buf = old and old.buf or scratch(("isovim-acp://%s/%s · %s"):format(ws, agent, name))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "isovim_acp"
  -- Wrapped lines line up under the text after their glyph.
  vim.bo[buf].formatlistpat = [[^\s*\(❯\|⏺\|✻\|⎿\)\s\+]]
  vim.b[buf].isovim_id, vim.b[buf].isovim_ws, vim.b[buf].isovim_agent = ws, ws, agent
  vim.b[buf].isovim_agent_name, vim.b[buf].isovim_agent_kind, vim.b[buf].isovim_acp = name, "claude", true
  vim.bo[buf].buflisted = true
  -- No smooth scrolling: its animation moves the cursor after a jump (so a key right after one acts
  -- on a line it passes through), and it lags a chat that follows its end. No indent guides.
  vim.b[buf].snacks_scroll, vim.b[buf].snacks_indent = false, false

  local composer = old and old.composer or scratch(("isovim-acp://%s/%s/composer"):format(ws, agent))
  vim.bo[composer].filetype = "isovim_composer"
  vim.b[composer].isovim_agent = agent
  -- Its workspace's, so it comes and goes with the chat when you switch workspaces.
  vim.b[composer].isovim_ws = ws
  vim.b[composer].isovim_composer = true
  vim.b[composer].snacks_indent = false
  -- No completion menu, whose keys would take <Up>, <Down> and <CR> (blink.cmp reads this).
  vim.b[composer].completion = false

  images.setup(composer, store.path(ws) .. "/images")

  local chat = { ws = ws, agent = agent, buf = buf, composer = composer, tools = {}, queue = {}, history = {}, history_images = {}, seq = 0,
    fresh = true, busy = false, handover = false, unseen = false, marks = {}, boxes = {}, options = {},
    kind = spec.kind or "claude" }
  if old then
    reset(chat)
  end
  -- Window options follow the buffer into any window that shows it (a layout rebuilt, :b).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = GROUP,
    buffer = buf,
    callback = function()
      chat_window(vim.api.nvim_get_current_win())
    end,
  })
  -- Scrolled or moved: whether it follows; back at the bottom, nothing unseen.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = GROUP,
    buffer = buf,
    callback = function()
      note_followers(buf)
      if chat.unseen then
        set_unseen(chat)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = GROUP,
    buffer = composer,
    callback = function()
      composer_window(vim.api.nvim_get_current_win())
      update_bar(chat)
    end,
  })
  -- The queue window follows the composer's: above each window showing it, gone with it. Later,
  -- as a chat being opened is still placing windows. (Windows placed inside another autocmd, as
  -- selecting a workspace rebuilds its layout, fire none: isovim.layout calls M.settle.)
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinClosed" }, {
    group = GROUP,
    buffer = composer,
    callback = function()
      M.settle(chat)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = GROUP,
    buffer = composer,
    callback = function()
      decorate_composer(chat)
    end,
  })
  map_chat(chat)
  map_composer(chat)
  chat.stop, chat.drain = journal.follow(ws, agent, function(entry)
    ingest(chat, entry, false)
  end, function()
    reset(chat)
  end)
  subscribe(chat)
  -- What the journal can't say: whether the supervisor is still at it (it may have died mid-turn).
  local ok, state = acp.call(ws, agent, "status")
  if ok and type(state) == "table" then
    chat.busy, chat.handover = state.busy == true, state.handover == true
  else
    chat.busy = false
  end
  -- A supervisor that comes back (a restart, a handover's end) is subscribed to again.
  chat.timer = vim.uv.new_timer()
  chat.timer:start(1000, 1000, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then
      subscribe(chat)
    end
  end))
  local stop = chat.stop
  chat.unfollow = stop
  chat.stop = function()
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
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = buf,
    once = true,
    callback = function()
      chat.stop()
      chats[key(ws, agent)] = nil
      vim.schedule(function()
        queue.close(ws, agent)
        if vim.api.nvim_buf_is_valid(composer) then
          pcall(vim.api.nvim_buf_delete, composer, { force = true })
        end
      end)
    end,
  })
  return chat
end

-- The composer's height, its bar included. Nothing changes it: a drag, :resize or a layout
-- restored is put back (M.settle).
local COMPOSER_HEIGHT = 6

-- Where a window sits in winlayout(): the col or row node holding it, and its index there.
local function parent_of(win, node)
  node = node or vim.fn.winlayout()
  if node[1] == "leaf" then
    return nil
  end
  for i, child in ipairs(node[2]) do
    if child[1] == "leaf" and child[2] == win then
      return node, i
    end
    local parent, j = parent_of(win, child)
    if parent then
      return parent, j
    end
  end
end

local function leaves(node, out)
  out = out or {}
  if node[1] == "leaf" then
    out[#out + 1] = node[2]
  else
    for _, child in ipairs(node[2]) do
      leaves(child, out)
    end
  end
  return out
end

local function is_queue(win)
  return vim.b[vim.api.nvim_win_get_buf(win)].isovim_queue == true
end

-- A window that got between the chat and its composer, or under the composer, goes beside the
-- chat; a queue window there just closes (queue.sync puts back the one that belongs).
local function move_beside(node, chat_win)
  for _, win in ipairs(leaves(node)) do
    if is_queue(win) then
      pcall(vim.api.nvim_win_close, win, false)
    else
      pcall(vim.fn.win_splitmove, win, chat_win, { vertical = true, rightbelow = true })
    end
  end
end

-- The chat's column, as it always is: the chat (or the row it sits in, a file beside it), the
-- queue window while it shows, and the composer at the bottom, COMPOSER_HEIGHT tall. Anything
-- else that got between or under them goes beside the chat; a composer away from its chat goes
-- back under it.
---@param chat isovim.acp.Chat
local function arrange(chat)
  local here = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    here[win] = true
  end
  local chat_win = vim.fn.bufwinid(chat.buf)
  for _, cwin in ipairs(vim.fn.win_findbuf(chat.composer)) do
    if here[cwin] and chat_win ~= -1 then
      local node, i = parent_of(cwin)
      local above = 0
      if node and node[1] == "col" then
        for j = #node[2], i + 1, -1 do
          move_beside(node[2][j], chat_win)
        end
        for j = i - 1, 1, -1 do
          local child = node[2][j]
          if vim.tbl_contains(leaves(child), chat_win) then
            above = j
            break
          elseif not (child[1] == "leaf" and is_queue(child[2])) then
            move_beside(child, chat_win)
          end
        end
      end
      if above == 0 then
        pcall(vim.fn.win_splitmove, cwin, chat_win, { rightbelow = true })
      end
      if vim.api.nvim_win_is_valid(cwin) and vim.api.nvim_win_get_height(cwin) ~= COMPOSER_HEIGHT then
        pcall(vim.api.nvim_win_set_height, cwin, COMPOSER_HEIGHT)
      end
    end
  end
  queue.sync(chat)
end

-- Soon (once whatever is placing windows is done): each chat's column put right (arrange), with
-- its queue window where its composer shows; or chat's alone.
local settling = false
---@param chat? isovim.acp.Chat
function M.settle(chat)
  vim.schedule(function()
    if settling then
      return
    end
    settling = true
    for _, each in pairs(chat and { chat } or chats) do
      if vim.api.nvim_buf_is_valid(each.buf) and vim.api.nvim_buf_is_valid(each.composer) then
        pcall(arrange, each)
        update_bar(each)
      end
    end
    settling = false
  end)
end

-- Whenever windows change (a drag on a separator, :resize, a split, a layout restored), the chat
-- columns on screen are put right again.
vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "WinResized", "VimResized" }, {
  group = vim.api.nvim_create_augroup("isovim_acp_column", { clear = true }),
  callback = function()
    if not settling and next(chats) then
      M.settle()
    end
  end,
})

---@return isovim.acp.Chat?
function M.get(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat and vim.api.nvim_buf_is_valid(chat.buf) and vim.api.nvim_buf_is_valid(chat.composer) then
    return chat
  end
end

-- Opens (or collapses) the output of the tool call whose line is row (0-based).
function M.set_open(ws, agent, row, open)
  local chat = M.get(ws, agent)
  for _, call in pairs(chat and chat.tools or {}) do
    if vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1] == row then
      call.open = open
      draw_tool(chat, call)
      return true
    end
  end
  return false
end

-- The chat a buffer belongs to (the chat's or its composer's).
---@return isovim.acp.Chat?
function M.of_buf(buf)
  return by_buf(buf or vim.api.nvim_get_current_buf())
end

-- Shows the agent's chat in win, with its composer in a split below unless it's on screen.
---@return isovim.acp.Chat
function M.open(ws, agent, win)
  local chat = M.get(ws, agent)
  if not chat then
    M.close(ws, agent)
    chat = make(ws, agent)
    chats[key(ws, agent)] = chat
  end
  -- Replacing another agent's chat (shown nowhere else), its composer gives way to this one's.
  local shown = by_buf(vim.api.nvim_win_get_buf(win))
  local replaced = shown and shown ~= chat and shown.buf == vim.api.nvim_win_get_buf(win) and #vim.fn.win_findbuf(shown.buf) == 1
  local old_composer = replaced and vim.fn.bufwinid(shown.composer) or -1
  vim.api.nvim_win_set_buf(win, chat.buf)
  -- Another workspace's chat entering the window selects it, which closes the old composer's.
  if old_composer ~= -1 and vim.api.nvim_win_is_valid(old_composer) and vim.fn.bufwinid(chat.composer) == -1 then
    vim.api.nvim_win_set_buf(old_composer, chat.composer)
  elseif vim.fn.bufwinid(chat.composer) == -1 then
    vim.api.nvim_open_win(chat.composer, false, { split = "below", win = win, height = COMPOSER_HEIGHT })
  end
  -- At the end, once the composer has taken its rows.
  pcall(to_end, win)
  set_unseen(chat)
  update_bar(chat)
  M.settle(chat)
  return chat
end

-- Puts you in the agent's composer, in insert mode at its end.
function M.focus_composer(ws, agent)
  local chat = M.get(ws, agent)
  local win = chat and vim.fn.bufwinid(chat.composer) or -1
  if win == -1 then
    return false
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert({ bang = true })
  return true
end

-- The supervisor replaced the journal (a session switch): read it again from the start.
function M.reload(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat then
    chat.rewind = nil
    chat.drain()
  end
end

-- The message at or above row (0-based): its mark's entry info; only your prompts with mine.
local function message_at(chat, row, mine)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, MESSAGES, { row, 0 }, 0, {})) do
    local info = chat.marks[mark[1]]
    if info and info.seq and (not mine or info.mine) then
      return info
    end
  end
end

-- The chat you're in (its buffer or its composer), and the row the cursor is on in the chat (nil
-- in the composer).
local function here()
  local buf = vim.api.nvim_get_current_buf()
  local chat = by_buf(buf)
  if not chat then
    return nil
  end
  return chat, buf == chat.buf and vim.api.nvim_win_get_cursor(0)[1] - 1 or nil
end

-- <leader>iu: your prompt under the cursor (in the composer, your last) goes into the composer to
-- edit; sending it rewinds there (isovim.acp.host's rewind).
function M.rewind_at_cursor()
  local chat, row = here()
  if not chat then
    return say("rewind: put the cursor on one of your prompts in an ACP agent's chat")
  end
  local info = message_at(chat, row or vim.api.nvim_buf_line_count(chat.buf) - 1, true)
  if not info or info.kind ~= "prompt" or not info.id then
    return say("rewind: no prompt of yours at or above the cursor")
  end
  chat.rewind = { id = info.id, text = info.text or "" }
  local lines = vim.split(info.text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, lines)
  if M.focus_composer(chat.ws, chat.agent) then
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  end
  update_bar(chat)
  return chat.rewind
end

-- <leader>if: a fork of the agent at the message under the cursor (in the composer, all of it).
function M.fork_at_cursor()
  local chat, row = here()
  if not chat then
    return say("fork: open an ACP agent's chat first")
  end
  local info = row and message_at(chat, row, false) or nil
  if row and not info then
    return say("fork: no message at or above the cursor")
  end
  M.fork(chat, info and info.seq or nil)
end

-- The tool calls and thoughts drawn in the chat, top to bottom.
local function placed(chat)
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

-- After a hot reload each open chat is made again by the new code on its own buffers (its keys,
-- autocmds and drawing then run it), drawn again from its journal. What the journal doesn't hold
-- is kept: where each window was scrolled, the composer's text, the tool calls you opened or
-- collapsed, a rewind you're editing. Autocmds of an isovim from before GROUP had none.
function M.rebind()
  local spinner = _G.isovim_acp_spinner
  if spinner and not spinner:is_closing() then
    spinner:close()
  end
  _G.isovim_acp_spinner = nil
  for k, old in pairs(chats) do
    if vim.api.nvim_buf_is_valid(old.buf) and vim.api.nvim_buf_is_valid(old.composer) then
      local views, opened = {}, {}
      for _, win in ipairs(vim.fn.win_findbuf(old.buf)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      end
      for i, call in ipairs(placed(old)) do
        opened[i] = call.open
      end
      pcall(old.stop)
      for _, buf in ipairs({ old.buf, old.composer }) do
        for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
          if au.group == nil or au.group == GROUP then
            vim.api.nvim_del_autocmd(au.id)
          end
        end
        for _, mode in ipairs({ "n", "i" }) do
          for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if vim.startswith(map.desc or "", "isovim: ") then
              vim.api.nvim_buf_del_keymap(buf, mode, map.lhs)
            end
          end
        end
      end
      local chat = make(old.ws, old.agent, old)
      chat.rewind, chat.recall, chat.unseen = old.rewind, old.recall, old.unseen
      for i, call in ipairs(placed(chat)) do
        if opened[i] ~= nil and call.open ~= opened[i] then
          call.open = opened[i]
          draw_tool(chat, call)
        end
      end
      chats[k] = chat
      for win, view in pairs(views) do
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(view)
        end)
      end
      update_bar(chat)
    end
  end
end

-- The agent went away: its chat, composer and queue go too.
function M.close(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat then
    chat.stop()
    chats[key(ws, agent)] = nil
    queue.close(ws, agent)
    for _, buf in ipairs({ chat.composer, chat.buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

return M
