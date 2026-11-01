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
-- What it looks like, as Claude draws it:
--   ❯ your prompt (and messages from iso send/msg)
--   ⏺ the agent's text, streamed in place; ✻ its thinking, dimmed
--   ⏺ Tool title           one line per tool call, rewritten in place; its ⏺ colored by status
--     ⎿  output … +N lines its output collapsed to its first line until za opens it; diffs are
--                         drawn with their line numbers and colored inline, Bash output streams
--                         in from the terminal deltas
--   (queued) a prompt      the queue, kept at the bottom until each prompt goes
-- The glyphs are text, so wrapping, search and yanks work in any window; colors, the tool
-- call places and the message marks are extmarks. Long lines wrap under their text (breakindent),
-- never sideways. Collapsing is the chat's own (a call's output is left out of the buffer until
-- opened), not nvim's folds, which nvim doesn't update while you type in the composer; so it holds
-- in every window and in iso attach, and needs no window state. The view follows new output only in a window whose cursor is on the last line; one scrolled up stays
-- where it is, and the composer's bar says there's more below. The bar above the composer has a
-- spinner while the agent works, how long it's been at it, and how many prompts wait.
--
-- Chat keys: ]] [[ your own prompts, ]m [m any message, za zo zc the output of the tool call under
-- the cursor, i a o <CR> the composer, <C-c> cancels the turn, gf the file on the line. Composer
-- keys: <CR> sends (queued while the agent works), <S-CR> or <C-j> a new line, <C-c> cancels the
-- turn, <Up> <Down> your earlier prompts while it's empty, <Esc> normal mode, <C-k> the chat.
-- <leader>iq edits the queue (isovim.acp.queue).
local acp = require("isovim.acp")
local journal = require("isovim.acp.journal")
local store = require("isovim.store")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_acp_chat")
-- Places: tool calls (with their output's extent) and messages, apart from highlights.
local TOOLS = vim.api.nvim_create_namespace("isovim_acp_tools")
local MESSAGES = vim.api.nvim_create_namespace("isovim_acp_messages")
local MINE = vim.api.nvim_create_namespace("isovim_acp_mine")

M.ns = { hl = NS, tools = TOOLS, messages = MESSAGES, mine = MINE }

---@class isovim.acp.ToolCall
---@field mark integer
---@field title string
---@field status string
---@field items table[] its ACP content
---@field terminal table<string, string> terminal id -> output so far
---@field exit? integer
---@field body integer how many lines of output it has under it
---@field open boolean its whole output shows (za), not only the first line
---@field more integer how many lines of output are left out while it's collapsed

---@class isovim.acp.Chat
---@field ws string
---@field agent string
---@field buf integer
---@field composer integer
---@field stop fun()
---@field drain fun()
---@field seq integer the last entry drawn
---@field fresh boolean nothing drawn yet: its first line is a placeholder
---@field block? "agent"|"thought"|"other" what the last block is: streaming text, or anything else
---@field block_row? integer the first row of the streaming block
---@field block_hl? integer the extmark that colors a thought block
---@field at_start? boolean the streaming block has no text yet
---@field tools table<string, isovim.acp.ToolCall>
---@field queue {id: string, text: string}[] prompts waiting, as the tail shows them
---@field tail integer how many lines the tail (the queue) takes at the end
---@field history string[] your prompts, oldest first, for <Up>/<Down> in the composer
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

local GLYPH = { message = "⏺", thought = "✻", result = "⎿", prompt = "❯" }
local FIRST, REST = "  ⎿  ", "     "
local MAX_BODY = 400

local STATUS_HL = {
  pending = "IsovimAcpToolPending",
  in_progress = "IsovimAcpToolRunning",
  completed = "IsovimAcpToolDone",
  failed = "IsovimAcpToolFailed",
}

function M.highlights()
  local set = function(name, spec)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
  set("IsovimAcpPrompt", { link = "Title" })
  set("IsovimAcpMessage", { link = "Normal" })
  set("IsovimAcpThought", { link = "Comment" })
  set("IsovimAcpToolTitle", { bold = true })
  set("IsovimAcpToolPending", { link = "Comment" })
  set("IsovimAcpToolRunning", { link = "DiagnosticInfo" })
  set("IsovimAcpToolDone", { link = "DiagnosticOk" })
  set("IsovimAcpToolFailed", { link = "DiagnosticError" })
  set("IsovimAcpResult", { link = "Comment" })
  set("IsovimAcpDiffAdd", { link = "DiffAdd" })
  set("IsovimAcpDiffDelete", { link = "DiffDelete" })
  set("IsovimAcpNotice", { link = "Comment" })
  set("IsovimAcpDenied", { link = "WarningMsg" })
  set("IsovimAcpQueued", { link = "Comment" })
  set("IsovimAcpSpinner", { link = "Special" })
end

M.highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("isovim_acp_chat_hl", { clear = true }),
  callback = M.highlights,
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

-- Windows showing the chat with their cursor on its last line, which keep following it.
local function followers(buf)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
  end, vim.fn.win_findbuf(buf))
end

-- Changes the buffer with fn (from: the first row it changes, 0-based). Windows at the bottom stay
-- there.
local function edit(chat, fn, from)
  local buf = chat.buf
  local wins = vim.fn.win_findbuf(buf)
  local follow = followers(buf)
  vim.bo[buf].modifiable = true
  fn(buf)
  vim.bo[buf].modifiable = false
  local last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(follow) do
    pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
  end
  if #wins > 0 and #follow == 0 and not chat.unseen then
    chat.unseen = true
    update_bar(chat)
  end
end

-- The row after the last line of the conversation, where the tail (the queue) starts.
local function body_end(chat)
  return vim.api.nvim_buf_line_count(chat.buf) - chat.tail
end

local function line_hl(buf, row, count, hl)
  for i = 0, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = hl })
  end
end

local function span(buf, row, col, end_col, hl)
  vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_col = end_col, hl_group = hl })
end

-- Adds whole lines at the end of the conversation (above the tail); returns the first one's row.
local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
    row = chat.fresh and 0 or body_end(chat)
    vim.api.nvim_buf_set_lines(buf, row, chat.fresh and 1 or row, false, lines)
    if hl then
      line_hl(buf, row, #lines, hl)
    end
  end, chat.fresh and 0 or body_end(chat))
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

-- Every message's first line is marked, and your own prompts' again in MINE, for ]] [[ and ]m [m.
local function mark_message(chat, row, mine)
  vim.api.nvim_buf_set_extmark(chat.buf, MESSAGES, row, 0, {})
  if mine then
    vim.api.nvim_buf_set_extmark(chat.buf, MINE, row, 0, {})
  end
end

-- Streams the agent's text (or its thinking) onto the end of the conversation, a new message
-- after anything else; its lines after the first are indented under the glyph.
local function add_text(chat, text, kind)
  if chat.block ~= kind then
    local glyph = kind == "thought" and GLYPH.thought or GLYPH.message
    local row = add_block(chat, { glyph .. " " })
    span(chat.buf, row, 0, #glyph, kind == "thought" and "IsovimAcpThought" or "IsovimAcpMessage")
    mark_message(chat, row, false)
    chat.block, chat.block_row, chat.block_hl, chat.at_start = kind, row, nil, true
  end
  if chat.at_start then
    text = text:gsub("^\n+", "")
    if text == "" then
      return
    end
    chat.at_start = false
  end
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  edit(chat, function(buf)
    local row = body_end(chat) - 1
    local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
    vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
    if kind == "thought" then
      local last = body_end(chat) - 1
      local width = #(vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or "")
      chat.block_hl = vim.api.nvim_buf_set_extmark(buf, NS, chat.block_row, 0,
        { id = chat.block_hl, end_row = last, end_col = width, hl_group = "IsovimAcpThought" })
    end
  end, body_end(chat) - 1)
end

local function strip_ansi(text)
  return (text:gsub("\27%[[%d;?]*[%a]", ""):gsub("\27%][^\7]*\7", ""):gsub("\r\n", "\n"):gsub("\r", ""))
end

-- A path as the agent's dir sees it.
local function short(chat, path)
  local dir = store.agent_dir(chat.ws, chat.agent)
  local real = vim.uv.fs_realpath(dir) or dir
  for _, base in ipairs({ dir, real }) do
    if path and vim.startswith(path, base .. "/") then
      return path:sub(#base + 2)
    end
  end
  return path or "a file"
end

-- Text content without the code fence the adapter wraps command output in.
local function text_lines(text)
  local lines = vim.split(strip_ansi(text or ""), "\n", { plain = true })
  if lines[1] and lines[1]:match("^```") then
    table.remove(lines, 1)
    while lines[#lines] == "" do
      lines[#lines] = nil
    end
    if lines[#lines] and lines[#lines]:match("^```%s*$") then
      lines[#lines] = nil
    end
  end
  return lines
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- A diff's lines: what changed with a line of context, each with its line number, and the hl of
-- the line ("+" added, "-" removed).
---@return {[1]: string, [2]: string?}[] lines, string summary
local function diff_lines(chat, item)
  local old = item.oldText ~= vim.NIL and item.oldText or nil
  local new = item.newText ~= vim.NIL and item.newText or ""
  local path = short(chat, item.path)
  local out = {}
  if not old then
    local lines = vim.split(new, "\n", { plain = true })
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    for i, line in ipairs(lines) do
      out[#out + 1] = { ("%4d + %s"):format(i, line), "IsovimAcpDiffAdd" }
    end
    return out, ("Wrote %s to %s"):format(plural(#lines, "line"), path)
  end
  local function nl(text)
    return text:sub(-1) == "\n" and text or text .. "\n"
  end
  local diff = (vim.text and vim.text.diff or vim.diff)(nl(old), nl(new), { result_type = "unified", ctxlen = 1 })
  local added, removed, o, n = 0, 0, 0, 0
  for line in tostring(diff or ""):gmatch("([^\n]*)\n") do
    local a, c = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if a then
      if #out > 0 then
        out[#out + 1] = { "   ⋮" }
      end
      o, n = tonumber(a), tonumber(c)
    elseif line:sub(1, 1) == "-" then
      out[#out + 1] = { ("%4d - %s"):format(o, line:sub(2)), "IsovimAcpDiffDelete" }
      o, removed = o + 1, removed + 1
    elseif line:sub(1, 1) == "+" then
      out[#out + 1] = { ("%4d + %s"):format(n, line:sub(2)), "IsovimAcpDiffAdd" }
      n, added = n + 1, added + 1
    elseif line:sub(1, 1) == " " then
      out[#out + 1] = { ("%4d   %s"):format(n, line:sub(2)) }
      o, n = o + 1, n + 1
    end
  end
  return out, ("Updated %s with %s and %s"):format(path, plural(added, "addition"), plural(removed, "removal"))
end

-- What goes under a tool call: its text, diffs and terminal output, the first line after ⎿.
---@param call isovim.acp.ToolCall
---@return {[1]: string, [2]: string?}[]
local function body_lines(chat, call)
  local rows = {}
  local shown_terminals = {}
  local function plain(lines)
    for _, line in ipairs(lines) do
      rows[#rows + 1] = { line }
    end
  end
  for _, item in ipairs(call.items) do
    if item.type == "content" and type(item.content) == "table" and item.content.type == "text" then
      plain(text_lines(item.content.text))
    elseif item.type == "diff" then
      local lines, summary = diff_lines(chat, item)
      rows[#rows + 1] = { summary }
      vim.list_extend(rows, lines)
    elseif item.type == "terminal" then
      shown_terminals[item.terminalId or ""] = true
      plain(text_lines(call.terminal[item.terminalId or ""] or ""))
    end
  end
  -- Output that came before the content naming its terminal.
  for id, output in pairs(call.terminal) do
    if not shown_terminals[id] then
      plain(text_lines(output))
    end
  end
  while #rows > 0 and vim.trim(rows[#rows][1]) == "" do
    rows[#rows] = nil
  end
  while #rows > 0 and vim.trim(rows[1][1]) == "" do
    table.remove(rows, 1)
  end
  if #rows > MAX_BODY then
    local more = #rows - MAX_BODY
    rows = vim.list_slice(rows, 1, MAX_BODY)
    rows[#rows + 1] = { ("… +%s"):format(plural(more, "line")) }
  end
  for i, row in ipairs(rows) do
    row[1] = (i == 1 and FIRST or REST) .. row[1]
  end
  return rows
end

local function title_of(title)
  title = (title or "tool"):gsub("\n.*", " …")
  return (title:gsub("^`(.*)`$", "%1"))
end

-- Draws a tool call's line and its output in place: all of it when it's open, else its first line
-- and how much more there is.
---@param call isovim.acp.ToolCall
local function draw_tool(chat, call)
  local row = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if not row then
    return
  end
  local header = GLYPH.message .. " " .. title_of(call.title)
  local body = body_lines(chat, call)
  call.more = (not call.open and #body > 1) and #body - 1 or 0
  if call.more > 0 then
    body = { body[1] }
  end
  local lines = { header }
  for _, line in ipairs(body) do
    lines[#lines + 1] = line[1]
  end
  edit(chat, function(buf)
    local replaced = row + 1 + call.body
    vim.api.nvim_buf_clear_namespace(buf, NS, row, replaced)
    vim.api.nvim_buf_set_lines(buf, row, replaced, false, lines)
    span(buf, row, 0, #GLYPH.message, STATUS_HL[call.status] or "IsovimAcpToolPending")
    span(buf, row, #GLYPH.message + 1, #header, "IsovimAcpToolTitle")
    local said = (call.exit and call.exit ~= 0 and ("exit " .. call.exit)) or (call.status == "failed" and "failed") or nil
    if said then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { virt_text = { { "  " .. said, "IsovimAcpToolFailed" } } })
    end
    for i, line in ipairs(body) do
      vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = line[2] or "IsovimAcpResult" })
    end
    if call.more > 0 then
      vim.api.nvim_buf_set_extmark(buf, NS, row + 1, 0,
        { virt_text = { { ("  … +%s (za)"):format(plural(call.more, "line")), "IsovimAcpNotice" } } })
    end
    call.body = #body
    vim.api.nvim_buf_set_extmark(buf, TOOLS, row, 0, { id = call.mark, end_row = row + call.body, end_col = 0 })
  end, row)
end

-- A tool call is a block, rewritten in place as its title, status or output changes.
local function tool(chat, update)
  local id = update.toolCallId or "?"
  local call = chat.tools[id]
  if not call then
    call = { title = update.title or "tool", status = update.status or "pending", items = {}, terminal = {}, body = 0,
      open = false, more = 0 }
    local row = add_block(chat, { "" })
    call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, row, 0, {})
    chat.tools[id] = call
  end
  call.title = update.title or call.title
  call.status = update.status or call.status
  if type(update.content) == "table" then
    call.items = update.content
  end
  local meta = type(update._meta) == "table" and update._meta or {}
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
  draw_tool(chat, call)
end

local PLAN_MARK = { completed = "☒", in_progress = "◐", pending = "☐" }

local function plan(chat, update)
  local lines = { GLYPH.message .. " Update Todos" }
  for i, entry in ipairs(update.entries or {}) do
    lines[#lines + 1] = (i == 1 and FIRST or REST) .. (PLAN_MARK[entry.status] or "☐") .. " " .. (entry.content or "")
  end
  local row = add_block(chat, lines)
  span(chat.buf, row, 0, #GLYPH.message, "IsovimAcpToolDone")
  span(chat.buf, row, #GLYPH.message + 1, #lines[1], "IsovimAcpToolTitle")
  line_hl(chat.buf, row + 1, #lines - 1, "IsovimAcpResult")
end

local function prompt_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and GLYPH.prompt .. " " or "  ") .. line
  end
  return lines
end

-- The tail: what's queued, under everything else, until each prompt goes.
local function draw_tail(chat)
  local lines = {}
  if #chat.queue > 0 then
    lines[1] = ""
    for _, item in ipairs(chat.queue) do
      lines[#lines + 1] = ("(queued) %s"):format((item.text or ""):gsub("\n", " ⏎ "))
    end
  end
  edit(chat, function(buf)
    local from = body_end(chat)
    vim.api.nvim_buf_clear_namespace(buf, NS, from, -1)
    vim.api.nvim_buf_set_lines(buf, from, -1, false, lines)
    line_hl(buf, from, #lines, "IsovimAcpQueued")
  end, body_end(chat))
  chat.tail = #lines
  local queue = package.loaded["isovim.acp.queue"]
  if queue then
    queue.refresh(chat.ws, chat.agent, chat.queue)
  end
end

local RENDER = {}

function RENDER.prompt(chat, entry)
  -- Sent now: it leaves the queue.
  local before = #chat.queue
  chat.queue = vim.tbl_filter(function(item)
    return item.id ~= entry.id
  end, chat.queue)
  if #chat.queue ~= before then
    draw_tail(chat)
  end
  -- Yours: typed in a composer or on Claude's screen, or iso spawn's; not one iso send or msg
  -- delivered.
  local mine = entry.via ~= "iso"
  local row = add_block(chat, prompt_lines(entry.text or ""), "IsovimAcpPrompt")
  mark_message(chat, row, mine)
  if mine and entry.text and chat.history[#chat.history] ~= entry.text then
    chat.history[#chat.history + 1] = entry.text
  end
end

function RENDER.queued(chat, entry)
  chat.queue[#chat.queue + 1] = { id = entry.id or "", text = entry.text or "" }
  draw_tail(chat)
end

function RENDER.queue(chat, entry)
  chat.queue = vim.tbl_map(function(item)
    return { id = item.id, text = item.text or "" }
  end, entry.items or {})
  draw_tail(chat)
end

function RENDER.update(chat, entry)
  local update = entry.update or {}
  local kind = update.sessionUpdate
  local content = type(update.content) == "table" and update.content or {}
  if kind == "agent_message_chunk" and content.type == "text" then
    add_text(chat, content.text or "", "agent")
  elseif kind == "agent_thought_chunk" and content.type == "text" then
    add_text(chat, content.text or "", "thought")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    tool(chat, update)
  elseif kind == "plan" then
    plan(chat, update)
  end
end

function RENDER.turn(chat, entry)
  if entry.state == "start" then
    chat.busy, chat.since = true, entry.ts
  elseif entry.state == "end" then
    chat.busy = false
    if entry.error or (entry.stopReason and entry.stopReason ~= "end_turn") then
      add_block(chat, { ("[turn ended: %s]"):format(entry.error or entry.stopReason) }, "IsovimAcpNotice")
    end
  end
end

function RENDER.permission(chat, entry)
  add_block(chat, { ("%s: %s (%s)"):format(entry.decision or "denied", entry.tool or "a tool",
    entry.reason or "approvals not built yet") }, "IsovimAcpDenied")
end

function RENDER.notice(chat, entry)
  if (entry.text or ""):match("^the agent exited") then
    chat.busy = false
  end
  add_block(chat, { "[" .. (entry.text or "") .. "]" }, "IsovimAcpNotice")
end

function RENDER.session(chat, entry)
  chat.busy, chat.handover = false, false
  if entry.how ~= "new" then
    add_block(chat, { ("[%s session %s]"):format(entry.how == "resume" and "resumed" or "loaded", entry.sessionId or "") },
      "IsovimAcpNotice")
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
local spinner ---@type uv.uv_timer_t?

-- What the bar above the composer says.
---@param chat isovim.acp.Chat
function M.bar_text(chat)
  local parts = {}
  if chat.handover then
    parts[1] = "⇄ on Claude's screen (iso handover); prompts wait"
  elseif chat.busy then
    local secs = chat.since and math.max(0, math.floor(os.time() - chat.since)) or 0
    parts[1] = ("%s Working… (%ds · <C-c> to cancel)"):format(FRAMES[frame], secs)
  else
    local spec = store.agent(chat.ws, chat.agent) or {}
    parts[1] = "❯ " .. (spec.name or chat.agent)
  end
  if #chat.queue > 0 then
    parts[#parts + 1] = ("%d queued (<leader>iq)"):format(#chat.queue)
  end
  if chat.unseen then
    parts[#parts + 1] = "↓ more below"
  end
  return " " .. table.concat(parts, " · ")
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
  local text = M.bar_text(chat):gsub("%%", "%%%%")
  local hl = (chat.busy or chat.handover) and "%#IsovimAcpSpinner#" or "%#IsovimAcpNotice#"
  for _, win in ipairs(vim.fn.win_findbuf(chat.composer)) do
    vim.wo[win][0].winbar = hl .. text
  end
  if any_busy() and not spinner then
    spinner = vim.uv.new_timer()
    spinner:start(100, 100, vim.schedule_wrap(function()
      frame = frame % #FRAMES + 1
      local busy = false
      for _, each in pairs(chats) do
        if each.busy and vim.api.nvim_buf_is_valid(each.composer) then
          busy = true
          update_bar(each)
        end
      end
      if not busy and spinner then
        spinner:stop()
        spinner:close()
        spinner = nil
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
    draw(chat, entry)
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
  chat.block, chat.tools, chat.queue, chat.history, chat.seq, chat.tail, chat.fresh = nil, {}, {}, {}, 0, 0, true
  chat.busy, chat.handover = false, false
  if vim.api.nvim_buf_is_valid(chat.buf) then
    for _, ns in ipairs({ NS, TOOLS, MESSAGES, MINE }) do
      vim.api.nvim_buf_clear_namespace(chat.buf, ns, 0, -1)
    end
    edit(chat, function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)
  end
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
  local open = (cmd == "zo") or (cmd == "za" and not call.open) or false
  if open == call.open or (open and call.more == 0) then
    return
  end
  call.open = open
  draw_tool(chat, call)
  local now = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if now and not open then
    vim.api.nvim_win_set_cursor(0, { math.min(row, now + 1) + 1, 0 })
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

-- Sends what's in the composer and empties it; on failure the text stays and you're told why.
function M.submit(composer)
  local chat = by_buf(composer)
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(composer, 0, -1, false), "\n"))
  if not chat or text == "" then
    return
  end
  local ok, result = acp.call(chat.ws, chat.agent, "prompt", { text = text })
  if not ok then
    vim.notify("isovim: could not send to " .. chat.agent .. ": " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  chat.recall = nil
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "" })
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
  for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
    map(lhs, function()
      M.focus_composer(chat.ws, chat.agent)
    end, "type to the agent")
  end
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
end

local function map_composer(chat)
  local buf = chat.composer
  local function map(modes, lhs, fn, desc, opts)
    vim.keymap.set(modes, lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true, desc = "isovim: " .. desc }, opts or {}))
  end
  map({ "n", "i" }, "<CR>", function()
    M.submit(buf)
  end, "send to the agent")
  -- A new line without sending: <CR> here is the key's own, not the mapping above.
  map("i", "<S-CR>", "<CR>", "new line")
  map("i", "<C-j>", "<CR>", "new line")
  map({ "n", "i" }, "<C-c>", function()
    cancel(chat)
  end, "cancel the agent's turn")
  for _, key_dir in ipairs({ { "<Up>", -1 }, { "<Down>", 1 } }) do
    map({ "n", "i" }, key_dir[1], function()
      if not recall(chat, key_dir[2]) then
        vim.api.nvim_feedkeys(vim.keycode(key_dir[1]), "n", false)
      end
    end, "earlier prompts while the composer is empty")
  end
  map({ "n", "i" }, "<C-k>", function()
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(chat.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end, "go to the chat")
end

-- The chat's window options, for any window that shows it.
local function chat_window(win)
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.breakindent, wo.breakindentopt = true, true, true, "list:-1"
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn, wo.foldcolumn = false, false, "no", "", "0"
  wo.list, wo.spell, wo.colorcolumn, wo.foldenable = false, false, "", false
  wo.fillchars = "eob: "
end

local function make(ws, agent)
  local spec = store.agent(ws, agent) or {}
  local name = (spec.name or agent)
  local buf = scratch(("isovim-acp://%s/%s · %s"):format(ws, agent, name))
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

  local composer = scratch(("isovim-acp://%s/%s/composer"):format(ws, agent))
  vim.bo[composer].filetype = "isovim_composer"
  vim.b[composer].isovim_agent = agent
  -- Its workspace's, so it comes and goes with the chat when you switch workspaces.
  vim.b[composer].isovim_ws = ws
  vim.b[composer].isovim_composer = true
  vim.b[composer].snacks_indent = false
  -- No completion menu, whose keys would take <Up>, <Down> and <CR> (blink.cmp reads this).
  vim.b[composer].completion = false

  local chat = { ws = ws, agent = agent, buf = buf, composer = composer, tools = {}, queue = {}, history = {}, seq = 0,
    tail = 0, fresh = true, busy = false, handover = false, unseen = false }
  -- Window options follow the buffer into any window that shows it (a layout rebuilt, :b).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      chat_window(vim.api.nvim_get_current_win())
    end,
  })
  -- Back at the bottom: nothing unseen.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    buffer = buf,
    callback = function()
      if chat.unseen and #followers(buf) > 0 then
        chat.unseen = false
        update_bar(chat)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = composer,
    callback = function()
      local wo = vim.wo[vim.api.nvim_get_current_win()][0]
      wo.winfixheight, wo.number, wo.relativenumber, wo.wrap = true, false, false, true
      wo.signcolumn, wo.statuscolumn, wo.foldcolumn, wo.fillchars = "no", "", "0", "eob: "
      update_bar(chat)
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
    buffer = buf,
    once = true,
    callback = function()
      chat.stop()
      chats[key(ws, agent)] = nil
      if vim.api.nvim_buf_is_valid(composer) then
        vim.schedule(function()
          pcall(vim.api.nvim_buf_delete, composer, { force = true })
        end)
      end
    end,
  })
  return chat
end

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
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(chat.buf), 0 })
  if old_composer ~= -1 and vim.fn.bufwinid(chat.composer) == -1 then
    vim.api.nvim_win_set_buf(old_composer, chat.composer)
  elseif vim.fn.bufwinid(chat.composer) == -1 then
    vim.api.nvim_open_win(chat.composer, false, { split = "below", win = win, height = 5 })
  end
  update_bar(chat)
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

-- The agent went away: its chat and composer go too.
function M.close(ws, agent)
  local chat = chats[key(ws, agent)]
  if chat then
    chat.stop()
    chats[key(ws, agent)] = nil
    for _, buf in ipairs({ chat.composer, chat.buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

return M
