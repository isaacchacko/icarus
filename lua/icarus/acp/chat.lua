-- A chat: the conversation in one buffer, drawn as Claude Code draws its screen (the words, colors and
-- tool rows are icarus.acp.look's), and under it in the same buffer the composer, where you type
-- (icarus.acp.compose). Its session (icarus.acp.session) runs while icarus does.
--
--   ❯ your prompt          on Claude's gray band
--   ⏺ the agent's text     streamed in place, its `code`, **bold** and tables drawn
--   ⏺ Update(app.py)       one line per tool call, rewritten in place, its bullet colored by status;
--     ⎿  Added 1 line…     under ⎿ what came back (a numbered diff, a read's count, a command's
--     … +37 lines          first lines); za opens or collapses it
--   ✻ Thought for 3s       the agent's thinking, collapsed until za
--   ─ Bash command ─       a permission waiting on you, as Claude's numbered box: its number and <CR>
--      1. Allow            in the composer, or <CR> on an option, answers it
--   ✻ Brewed for 8s        the turn's summary
--
-- The window's winbar is Claude's spinner line while the agent works. <CR> sends (in insert mode
-- too, where <S-CR> is a new line), <C-c> interrupts the turn. A prompt sent while the agent works
-- waits its turn. A cursor in the composer goes down with it as the conversation grows; one in the
-- conversation stays where you left it.
--
-- A hot reload (icarus.reload) keeps the open chats: they live in _G, what the session hears comes
-- in through require (M.hear), so the new code draws it, and M.rebind maps their keys to it. What's
-- drawn already stays as the old code drew it.
local compose = require("icarus.acp.compose")
local images = require("icarus.acp.images")
local look = require("icarus.acp.look")
local tables = require("icarus.acp.tables")
local thread = require("icarus.acp.thread")
local session = require("icarus.acp.session")
local chats = require("icarus.chats")

local M = {}

local NS = vim.api.nvim_create_namespace("icarus_chat")
local TOOLS = vim.api.nvim_create_namespace("icarus_chat_tools")
local MD = vim.api.nvim_create_namespace("icarus_chat_markdown")
local BOXES = vim.api.nvim_create_namespace("icarus_chat_boxes")
local OPTIONS = vim.api.nvim_create_namespace("icarus_chat_options")

local DOT = look.DOT
local GLYPH = { message = DOT, thought = "✻", prompt = "❯" }
local FIRST, REST = look.FIRST, look.REST
local RULE = ("─"):rep(400)

local STATUS_HL = {
  pending = "IcarusAcpToolPending",
  in_progress = "IcarusAcpToolRunning",
  completed = "IcarusAcpToolDone",
  failed = "IcarusAcpToolFailed",
}

---@class icarus.ToolCall
---@field mark? integer its line, in TOOLS, extending over its output
---@field title string
---@field status string
---@field items table[] its ACP content
---@field terminal table<string, string> terminal id -> output so far
---@field exit? integer
---@field body integer how many lines of output are drawn under it
---@field open? boolean opened or collapsed with za; nil: as it shows by default
---@field tool? string the tool's own name (_meta.claudeCode.toolName)
---@field kind? string
---@field input? table
---@field locations? table[]
---@field response? table
---@field hidden? boolean drawn another way (TodoWrite as its plan)
---@field thought? boolean a thought: text is what it thought, secs how long
---@field text? string
---@field started? number
---@field secs? number

---@class icarus.Box a permission waiting on you
---@field mark integer its first line in BOXES, extending to its last
---@field options {optionId: string, name: string, kind: string}[]
---@field answer fun(option?: string)
---@field tool string what it asks to run

---@class icarus.Chat
---@field record icarus.ChatRecord
---@field buf integer the conversation
---@field draft table what's typed in the composer: its buffer and its history (icarus.acp.compose)
---@field session icarus.acp.Session
---@field fresh boolean nothing drawn yet: the buffer's one line is empty
---@field block? "agent"|"thought"|"other"
---@field block_row? integer the streaming message's first row
---@field at_start? boolean the streaming message has no text yet
---@field table_scan? integer where the streaming message's next table may start
---@field thought? icarus.ToolCall the thought streaming in
---@field tools table<string, icarus.ToolCall>
---@field boxes icarus.Box[]
---@field options table<integer, {box: icarus.Box, n: integer}> by extmark (OPTIONS)
---@field busy boolean
---@field since? number
---@field verb? string
---@field turn_chars integer

_G.icarus_open_chats = _G.icarus_open_chats or {}
local open_chats = _G.icarus_open_chats ---@type table<string, icarus.Chat>

local function now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

local function dirs(chat)
  local cwd = chat.record.cwd
  return { cwd, vim.uv.fs_realpath(cwd) or cwd }
end

-- Changes the conversation with fn.
local function edit(chat, fn)
  compose.write(chat.buf, fn)
end

local function span(buf, row, col, end_col, hl, priority)
  vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_col = end_col, hl_group = hl, priority = priority })
end

local function line_hl(buf, row, count, hl)
  for i = 0, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = hl })
  end
end

-- A highlight from col on to the window's edge, as Claude colors a diff's lines.
local function eol_hl(buf, row, col, hl)
  vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_row = row + 1, end_col = 0, hl_group = hl, hl_eol = true,
    priority = 100 })
end

-- Draws the tables in the streaming message whose lines have all come. Runs inside edit.
local function draw_tables(chat, whole)
  local buf = chat.buf
  local last = compose.start(buf) - (whole and 1 or 2)
  local row = math.max(chat.table_scan or chat.block_row, chat.block_row)
  chat.table_scan = tables.scan(chat, buf, row, last, whole, function(line)
    return vim.startswith(line, GLYPH.message .. " ") and GLYPH.message .. " " or "  "
  end, "  ", function(from, count)
    vim.api.nvim_buf_clear_namespace(buf, NS, from, from + count)
    vim.api.nvim_buf_clear_namespace(buf, MD, from, from + count)
  end)
end

-- Adds whole lines at the end; returns the first one's row.
local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
    if chat.block == "agent" then
      draw_tables(chat, true)
    end
    row = chat.fresh and 0 or compose.start(buf)
    vim.api.nvim_buf_set_lines(buf, row, chat.fresh and 1 or row, false, lines)
    if hl then
      line_hl(buf, row, #lines, hl)
    end
  end)
  chat.fresh, chat.block = false, "other"
  return row
end

-- A new block, a blank line before it; returns its first line's row.
local function add_block(chat, lines, hl)
  local first = chat.fresh
  local row = add_lines(chat, first and lines or { "", unpack(lines) })
  row = first and row or row + 1
  if hl then
    line_hl(chat.buf, row, #lines, hl)
  end
  return row
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

-- Streams the agent's text onto the end, a new message after anything else; its lines after the
-- first indented under the glyph.
local function add_text(chat, text)
  if chat.block ~= "agent" then
    local row = add_block(chat, { GLYPH.message .. " " })
    span(chat.buf, row, 0, #GLYPH.message, "IcarusAcpMessage")
    chat.block, chat.block_row, chat.at_start, chat.table_scan = "agent", row, true, row
  end
  if chat.at_start then
    text = text:gsub("^\n+", "")
    if text == "" then
      return
    end
    chat.at_start = false
  end
  chat.turn_chars = chat.turn_chars + #text
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  edit(chat, function(buf)
    local row = compose.start(buf) - 1
    local col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
    markup(chat, row, compose.start(buf) - 1)
    if #parts > 1 then
      draw_tables(chat, false)
    end
  end)
end

-- Tool calls and thoughts: blocks drawn in place, whose output collapses (za)

local function is_open(call, kind, count)
  if call.open ~= nil then
    return call.open
  end
  return look.open_by_default(kind, count)
end

local function thought_rows(call)
  local rows = {}
  local text = vim.trim(call.text or "")
  if text ~= "" then
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      rows[#rows + 1] = { line, hl = "IcarusAcpThought" }
    end
  end
  return rows
end

-- Draws a tool call's (or a thought's) line and what's under it in place: all of it when it's
-- open, else what shows collapsed and a line saying how much more there is.
---@param call icarus.ToolCall
local function draw_tool(chat, call)
  local row = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if not row then
    return
  end
  local header, spans, rows, kind
  if call.thought then
    header = GLYPH.thought .. " " .. (call.secs and ("Thought for " .. look.duration(call.secs)) or "Thinking…")
    spans = { { 0, #header, "IcarusAcpThought" } }
    rows, kind = thought_rows(call), "thought"
  else
    local name, args = look.header(call, dirs(chat))
    header = GLYPH.message .. " " .. name .. (args and ("(" .. args .. ")") or "")
    spans = { { 0, #GLYPH.message, STATUS_HL[call.status] or "IcarusAcpToolPending" },
      { #GLYPH.message + 1, #GLYPH.message + 1 + #name, "IcarusAcpToolTitle" } }
    rows, kind = look.body(call, dirs(chat))
  end
  local shown, more = rows, 0
  if not is_open(call, kind, #rows) then
    local count = kind == "thought" and 0 or look.collapsed_count(kind, #rows)
    if #rows > count then
      shown, more = vim.list_slice(rows, 1, count), #rows - count
      -- A read says its count already; the rest say how many lines are left out.
      if kind ~= "read" and kind ~= "thought" then
        shown[#shown + 1] = { ("… +%s (za to expand)"):format(look.plural(more, "line")), hl = "IcarusAcpResultNote" }
      end
    end
  end
  local indent = call.thought and "  " or nil
  local lines = { header }
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
    if more > 0 and (kind == "read" or kind == "thought") then
      vim.api.nvim_buf_set_extmark(buf, NS, kind == "thought" and row or row + 1, 0,
        { virt_text = { { "  (za to expand)", "IcarusAcpNotice" } } })
    end
    for i, r in ipairs(shown) do
      local at, line = row + i, lines[i + 1]
      local pre = indent and #indent or #(i == 1 and FIRST or REST)
      if not indent and i == 1 then
        span(buf, at, 0, pre, "IcarusAcpResultGlyph")
      end
      if r.hl == "IcarusAcpDiffAdd" or r.hl == "IcarusAcpDiffDelete" then
        eol_hl(buf, at, pre, r.hl)
      else
        span(buf, at, pre, #line, r.hl or "IcarusAcpResult", not r.hl and 90 or nil)
      end
      for _, s in ipairs(r.spans or {}) do
        span(buf, at, pre + s[1], math.min(pre + s[2], #line), s[3], s.syntax and 4200 or 150)
      end
    end
    call.body = #shown
    vim.api.nvim_buf_set_extmark(buf, TOOLS, row, 0, { id = call.mark, end_row = row + call.body, end_col = 0 })
  end)
end

local function tool(chat, update)
  local id = update.toolCallId or "?"
  local call = chat.tools[id]
  local meta = type(update._meta) == "table" and update._meta or {}
  local claude = type(meta.claudeCode) == "table" and meta.claudeCode or {}
  if not call then
    call = { title = update.title or "tool", status = update.status or "pending", items = {}, terminal = {}, body = 0,
      kind = update.kind, tool = claude.toolName }
    local name = look.tool_name(call)
    call.hidden = name ~= nil and look.HIDDEN[name] or false
    if not call.hidden then
      call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, add_block(chat, { "" }), 0, {})
    end
    chat.tools[id] = call
  end
  call.title = update.title or call.title
  call.status = update.status or call.status
  -- What it's doing now, for the agent sidebar (icarus.org).
  chat.last_tool = call
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
  if type(exit) == "table" and exit.exit_code ~= nil then
    call.exit = tonumber(exit.exit_code)
  end
  if not call.hidden then
    draw_tool(chat, call)
  end
  return call
end

local function thought(chat, text)
  local call = chat.block == "thought" and chat.thought or nil
  if not call then
    call = { thought = true, text = "", body = 0, items = {}, terminal = {}, started = now() }
    call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, add_block(chat, { "" }), 0, {})
    chat.tools["thought:" .. call.mark] = call
  end
  call.text = call.text .. text
  chat.turn_chars = chat.turn_chars + #text
  draw_tool(chat, call)
  chat.block, chat.thought = "thought", call
end

-- A thought ends when anything else comes: its header says how long it took.
local function end_thought(chat)
  local call = chat.thought
  if chat.block == "thought" and call then
    call.secs = math.max(1, now() - call.started)
    draw_tool(chat, call)
    chat.block = "other"
  end
  chat.thought = nil
end

local PLAN_MARK = { completed = "☒", in_progress = "☐", pending = "☐" }
local PLAN_HL = { completed = "IcarusAcpPlanDone", in_progress = "IcarusAcpPlanActive", pending = "IcarusAcpPlanPending" }

local function plan(chat, update)
  local lines = { GLYPH.message .. " Update Todos" }
  local entries = update.entries or {}
  for i, entry in ipairs(entries) do
    lines[#lines + 1] = (i == 1 and FIRST or REST) .. (PLAN_MARK[entry.status] or "☐") .. " " .. (entry.content or "")
  end
  local row = add_block(chat, lines)
  span(chat.buf, row, 0, #GLYPH.message, "IcarusAcpToolDone")
  span(chat.buf, row, #GLYPH.message + 1, #lines[1], "IcarusAcpToolTitle")
  for i, entry in ipairs(entries) do
    local pre = #(i == 1 and FIRST or REST)
    if i == 1 then
      span(chat.buf, row + i, 0, pre, "IcarusAcpResultGlyph")
    end
    local mark = #(PLAN_MARK[entry.status] or "☐") + 1
    span(chat.buf, row + i, pre, pre + mark, entry.status == "completed" and "IcarusAcpNotice" or "IcarusAcpResult")
    span(chat.buf, row + i, pre + mark, #lines[i + 1], PLAN_HL[entry.status] or "IcarusAcpResult")
  end
end

local function draw_prompt(chat, text)
  thread.prompt(chat, text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and GLYPH.prompt .. " " or "  ") .. line
  end
  local row = add_block(chat, lines)
  span(chat.buf, row, 0, #GLYPH.prompt + 1, "IcarusAcpPromptGlyph")
  span(chat.buf, row, #GLYPH.prompt + 1, #lines[1], "IcarusAcpPrompt")
  for i = 2, #lines do
    span(chat.buf, row + i - 1, 0, #lines[i], "IcarusAcpPrompt")
  end
end

local function notice(chat, text, hl)
  add_block(chat, { "[" .. text .. "]" }, hl or "IcarusAcpNotice")
end

-- Status and the bar

local function update_status(chat)
  chats.set_status(chat.record.id, #chat.boxes > 0 and "needs you" or chat.busy and "working" or "idle")
end

local FRAMES = { "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" }
local frame = 1

-- What the chat's winbar says, as {text, hl} parts: while the agent works, Claude's spinner line.
local function bar_parts(chat)
  local parts = {}
  local function add(text, hl)
    parts[#parts + 1] = { text, hl }
  end
  if #chat.boxes > 0 then
    add("? waiting for your permission", "IcarusAcpAsk")
    add(" (type its number and <CR>)", "IcarusAcpSpinnerNote")
  elseif chat.busy then
    add(FRAMES[frame] .. " ", "IcarusAcpSpinner")
    add((chat.verb or "Working") .. "…", "IcarusAcpSpinnerVerb")
    local notes = { look.duration(now() - (chat.since or now())) }
    local tokens = math.floor((chat.turn_chars + 3) / 4)
    if chat.block == "thought" then
      notes[#notes + 1] = "thinking"
    elseif tokens > 0 then
      notes[#notes + 1] = "↓ " .. look.count(tokens) .. " tokens"
    end
    notes[#notes + 1] = "<C-c> to interrupt"
    add(" (" .. table.concat(notes, " · ") .. ")", "IcarusAcpSpinnerNote")
  else
    add(GLYPH.prompt .. " " .. (chat.record.title or "new chat"), "IcarusAcpIdle")
  end
  if #chat.session.queue > 0 then
    add((" · %d queued"):format(#chat.session.queue), "IcarusAcpSpinnerNote")
  end
  return parts
end

local update_bar

-- In _G, ticking through require: one timer however many reloads, running the code of the last.
local function spin()
  if _G.icarus_chat_spinner then
    return
  end
  _G.icarus_chat_spinner = vim.uv.new_timer()
  _G.icarus_chat_spinner:start(100, 100, vim.schedule_wrap(function()
    require("icarus.acp.chat").tick()
  end))
end

function M.tick()
  frame = frame % #FRAMES + 1
  local busy = false
  for _, chat in pairs(open_chats) do
    if chat.busy then
      busy = true
      update_bar(chat)
    end
  end
  local spinner = _G.icarus_chat_spinner
  if not busy and spinner then
    spinner:close()
    _G.icarus_chat_spinner = nil
  end
end

update_bar = function(chat)
  local bar = " "
  for _, part in ipairs(bar_parts(chat)) do
    bar = bar .. "%#" .. part[2] .. "#" .. part[1]:gsub("%%", "%%%%")
  end
  for _, win in ipairs(thread.windows(chat)) do
    vim.wo[win].winbar = bar
  end
  thread.sync(chat)
  require("icarus.acp.queue").refresh(chat)
  if chat.busy then
    spin()
  end
end

-- Permissions: a box waiting on you, then what you decided

-- What Claude calls the prompt for a tool: its box's title, what it shows, and its question.
local function permission_rows(chat, call)
  local name = look.tool_name(call)
  local input = call.input or {}
  local path = input.file_path and look.short(input.file_path, dirs(chat))
  local title, question, body
  if name == "Bash" then
    title, question, body = "Bash command", "Do you want to proceed?", {}
    for _, line in ipairs(vim.split(input.command or call.title or "", "\n", { plain = true })) do
      body[#body + 1] = { "   " .. line }
    end
    if input.description then
      body[#body + 1] = { "   " .. input.description, "IcarusAcpNotice" }
    end
  elseif name == "Edit" or name == "MultiEdit" or name == "Write" then
    local new = name == "Write" and path and not vim.uv.fs_stat(input.file_path)
    path = path or "the file"
    title = new and "Create file" or "Edit file"
    question = new and ("Do you want to create %s?"):format(path) or ("Do you want to make this edit to %s?"):format(path)
    body = { { " " .. path, "IcarusAcpNotice" } }
  else
    local tool_name, args = look.header(call, dirs(chat))
    title, question = "Tool use", "Do you want to proceed?"
    body = { { "   " .. tool_name .. (args and ("(" .. args .. ")") or "") } }
  end
  local rows = { { " " .. title, "IcarusAcpAskTitle" } }
  vim.list_extend(rows, body)
  rows[#rows + 1] = { "" }
  rows[#rows + 1] = { " " .. question }
  return rows
end

local function ask_permission(chat, params, answer)
  local call = tool(chat, params.toolCall or {})
  local box = { options = params.options or {}, answer = answer, tool = look.header(call, dirs(chat)) }
  local rows = permission_rows(chat, call)
  for n, option in ipairs(box.options) do
    rows[#rows + 1] = { ("   %d. %s"):format(n, option.name or option.optionId), option = n,
      spans = { { 3, 3 + #tostring(n) + 1, "IcarusAcpOptionNr" } } }
  end
  rows[#rows + 1] = { "" }
  rows[#rows + 1] = { " its number and <CR> in the composer, or <CR> on an option", "IcarusAcpHint" }
  local row = add_block(chat, vim.tbl_map(function(r)
    return r[1]
  end, rows))
  local buf = chat.buf
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { virt_lines = { { { RULE, "IcarusAcpAskRule" } } }, virt_lines_above = true })
  for i, r in ipairs(rows) do
    if r[2] then
      span(buf, row + i - 1, 0, #r[1], r[2])
    end
    for _, s in ipairs(r.spans or {}) do
      span(buf, row + i - 1, s[1], s[2], s[3], 150)
    end
    if r.option then
      chat.options[vim.api.nvim_buf_set_extmark(buf, OPTIONS, row + i - 1, 0, {})] = { box = box, n = r.option }
    end
  end
  box.mark = vim.api.nvim_buf_set_extmark(buf, BOXES, row, 0, { end_row = row + #rows - 1, end_col = 0 })
  chat.boxes[#chat.boxes + 1] = box
  update_status(chat)
  update_bar(chat)
end

-- Takes a box out (and the blank line before it), putting lines in its place.
local function replace_box(chat, box, lines, hl)
  local pos = vim.api.nvim_buf_get_extmark_by_id(chat.buf, BOXES, box.mark, { details = true })
  if pos[1] then
    local first, last = pos[1], pos[3].end_row or pos[1]
    local from = first > 0 and first - 1 or first
    edit(chat, function(buf)
      vim.api.nvim_buf_clear_namespace(buf, NS, from, last + 1)
      vim.api.nvim_buf_clear_namespace(buf, OPTIONS, from, last + 1)
      vim.api.nvim_buf_del_extmark(buf, BOXES, box.mark)
      vim.api.nvim_buf_set_lines(buf, from, last + 1, false, lines)
      if hl then
        line_hl(buf, from, #lines, hl)
      end
    end)
  end
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
  update_status(chat)
  update_bar(chat)
end

local function answer_box(chat, box, n)
  local option = box.options[n]
  if not option then
    return vim.notify(("icarus: no option %d"):format(n), vim.log.levels.WARN)
  end
  box.answer(option.optionId)
  if (option.kind or ""):match("^allow") then
    -- As on Claude's screen: once allowed, the tool just runs.
    replace_box(chat, box, {})
  else
    replace_box(chat, box, { ("  ⎿  Denied · %s won't run"):format(box.tool) }, "IcarusAcpDenied")
  end
end

-- Boxes nothing will answer now (the turn ended, the agent went away).
local function drop_boxes(chat)
  for _, box in ipairs(vim.list_slice(chat.boxes, 1)) do
    box.answer()
    replace_box(chat, box, { "  ⎿  No longer waiting on an answer" }, "IcarusAcpNotice")
  end
end

-- What the session says

local function on_update(chat, update, loading)
  local kind = update.sessionUpdate
  local content = type(update.content) == "table" and update.content or {}
  if kind == "user_message_chunk" then
    -- Only a load replays your prompts; live, the chat drew them as they went.
    if loading and content.type == "text" and vim.trim(content.text or "") ~= "" then
      draw_prompt(chat, content.text)
    end
    return
  end
  if kind == "agent_thought_chunk" and content.type == "text" then
    return thought(chat, content.text or "")
  end
  if kind == "subagent_update" then
    return require("icarus.subagents").announced(chat, update, function(text)
      add_lines(chat, { "  " .. text }, "IcarusAcpNotice")
    end)
  end
  if kind == "agent_message_chunk" or kind == "tool_call" or kind == "tool_call_update" or kind == "plan" then
    end_thought(chat)
  end
  if kind ~= "agent_message_chunk" then
    thread.pause(chat)
  end
  if kind == "agent_message_chunk" and content.type == "text" then
    thread.text(chat, content.text or "")
    add_text(chat, content.text or "")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    tool(chat, update)
  elseif kind == "plan" then
    plan(chat, update)
  end
end

local function on_turn(chat, state, result)
  thread.pause(chat)
  if state == "start" then
    chat.busy, chat.since, chat.turn_chars = true, now(), 0
    chat.verb = look.verb(chat.since)
  else
    end_thought(chat)
    chat.busy = false
    chat.turns = (chat.turns or 0) + 1
    -- Once the transcript has this turn.
    vim.defer_fn(function()
      pcall(require("icarus.orchestration").turn_ended, chat)
    end, 1000)
    drop_boxes(chat)
    local reason = result.error or result.stopReason
    if reason == "cancelled" then
      add_lines(chat, { "  ⎿  Interrupted · What should Claude do instead?" }, "IcarusAcpNotice")
    elseif reason and reason ~= "end_turn" then
      add_lines(chat, { ("  ⎿  Error: the turn ended: %s"):format(reason) }, "IcarusAcpError")
    end
    if reason ~= "cancelled" and chat.since then
      local _, past = look.verb(chat.since)
      local row = add_block(chat, { ("%s %s for %s"):format(GLYPH.thought, past, look.duration(now() - chat.since)) })
      span(chat.buf, row, 0, #vim.api.nvim_buf_get_lines(chat.buf, row, row + 1, false)[1], "IcarusAcpTurnDone")
    end
    chat.since = nil
    if #chat.session.queue == 0 then
      require("icarus.watch").turn_ended(chat.record.id)
    end
  end
  update_status(chat)
  update_bar(chat)
end

-- Keys

local function call_at_cursor(chat)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, TOOLS, 0, -1, { details = true })) do
    if mark[2] <= row and row <= (mark[4].end_row or mark[2]) then
      for _, call in pairs(chat.tools) do
        if call.mark == mark[1] then
          return call
        end
      end
    end
  end
end

local function toggle(chat)
  local call = call_at_cursor(chat)
  if not call then
    return
  end
  local rows, kind
  if call.thought then
    rows, kind = thought_rows(call), "thought"
  else
    rows, kind = look.body(call, dirs(chat))
  end
  call.open = not is_open(call, kind, #rows)
  draw_tool(chat, call)
end

-- The cursor to the end of the draft, typing.
local function focus_composer(chat)
  local here = vim.api.nvim_get_current_win()
  local win = vim.tbl_contains(thread.windows(chat), here) and here or thread.windows(chat)[1]
  if win then
    vim.api.nvim_set_current_win(win)
    compose.place(win)
    vim.cmd.startinsert({ bang = true })
  end
end

-- i, a, o and the like in the conversation, by chat id.
function M.focus(id)
  local chat = open_chats[id]
  if chat then
    focus_composer(chat)
  end
end

local function send(chat)
  local buf = compose.holder(chat)
  local text = vim.trim(table.concat(compose.lines(buf), "\n"))
  if text == "" then
    return
  end
  local attached
  text, attached = images.collect(buf, text)
  compose.clear(chat)
  local n = tonumber(text:match("^(%d+)$"))
  if chat.boxes[1] and n then
    return answer_box(chat, chat.boxes[1], n)
  end
  if not chat.record.title then
    local title = text:match("^[^\n]*")
    chat.record.title = vim.fn.strchars(title) > 60 and vim.fn.strcharpart(title, 0, 59) .. "…" or title
    chats.save(chat.record)
  end
  if chat.fork_next then
    chat.fork_next = false
    update_bar(chat)
    vim.cmd.redrawstatus()
    return M.fork(chat, text, attached, function(record)
      local tasks = require("icarus.tasks")
      local task = tasks.read(record.task or tasks.SENTINEL)
      if task then
        require("icarus.task_page").open(task, record)
      end
    end)
  end
  chat.session:prompt(text, attached)
  update_bar(chat)
end

-- A fork of chat: a new chat on its task, in its dir, whose session is a copy of chat's conversation
-- as it is now (session/fork), sent text as its first prompt; chat goes on as it was. Its record is
-- made at once, so it has an id to link to; it opens once the fork comes back, and done(record) then.
---@param done? fun(record: icarus.ChatRecord)
---@return icarus.ChatRecord? record
-- pin: what the fork runs at, for a task's workers (the task header's workers_model and workers_effort).
function M.fork(chat, text, attached, done, pin)
  local source = chat.session
  if not (source.ready and source.id and source.client) then
    vim.notify("This agent's session isn't open yet: fork it once it is", vim.log.levels.WARN)
    return nil
  end
  local first = text:match("^[^\n]*")
  local record = chats.create(chat.record.cwd, chat.record.task)
  record.forked_from = chat.record.id
  record.title = "⑂ " .. (vim.fn.strchars(first) > 58 and vim.fn.strcharpart(first, 0, 57) .. "…" or first)
  if pin then
    record.model, record.effort = pin.model, pin.effort
  end
  chats.save(record)
  source.client:request("session/fork", { sessionId = source.id, cwd = chat.record.cwd, mcpServers = {} }, function(result, err)
    if err or not (result and result.sessionId) then
      record.title = record.title .. " (the fork failed)"
      chats.save(record)
      return vim.notify("Could not fork: " .. tostring(err and err.message or "no session id"), vim.log.levels.ERROR)
    end
    record.session = result.sessionId
    chats.save(record)
    local tasks = require("icarus.tasks")
    local task = tasks.read(record.task or tasks.SENTINEL)
    if task and not task.sentinel then
      require("icarus.org").ensure(task)
    end
    -- The fork knows whose it is, and to report back.
    local note = ("(You are a fork of %s, icarus://agent/%s: you have its conversation so far. When you finish a step, or ask the user something, tell it: `ica msg %s <what>`.)"):format(
      chat.record.title or chat.record.id, chat.record.id, chat.record.id)
    M.get(record).session:prompt(note .. "\n\n" .. text, attached, text)
    if done then
      done(record)
    end
  end)
  return record
end

-- <leader>R: the agent started again, so it has what icarus has now that a hot reload can't give a
-- running one (its instructions, what icarus tells the adapter it takes): its adapter stopped, a new
-- one started and the same session loaded, history and all, into the windows that showed it. Only
-- while it's idle, so no turn is cut.
function M.restart(record)
  local old = open_chats[record.id]
  if old and (old.busy or #old.session.queue > 0 or #old.boxes > 0) then
    return vim.notify("It's working: restart it once it's idle", vim.log.levels.WARN)
  end
  local shown, at, typed = {}, {}, nil
  if old then
    shown = thread.windows(old)
    for _, win in ipairs(shown) do
      at[win] = compose.cursor(win)
    end
    typed = compose.lines(compose.holder(old))
    open_chats[record.id] = nil
    old.session:stop()
    for _, buf in ipairs({ old.buf, old.thread }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_set_name, buf, "")
      end
    end
  end
  local fresh = M.get(record)
  local want = thread.wanted(fresh)
  compose.carry(fresh, want)
  if typed then
    compose.set(fresh, typed)
  end
  for _, win in ipairs(shown) do
    vim.api.nvim_win_set_buf(win, want)
    compose.place(win, at[win])
  end
  if old then
    for _, buf in ipairs({ old.buf, old.thread }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  update_bar(fresh)
  vim.notify(("Restarted %s"):format(record.title or "the agent"))
end

-- <leader>s: the next message sent from this chat goes to a fork of it, or doesn't.
function M.toggle_fork(record)
  local chat = M.get(record)
  chat.fork_next = not chat.fork_next
  update_bar(chat)
  vim.cmd.redrawstatus()
  return chat.fork_next
end

-- <CR> in normal mode: in the composer it sends; on a permission's option it answers.
local function enter(chat)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if compose.inside(buf, row) then
    return send(chat)
  end
  local mark = buf == chat.buf and vim.api.nvim_buf_get_extmarks(buf, OPTIONS, { row, 0 }, { row, -1 }, { limit = 1 })[1]
  local option = mark and chat.options[mark[1]]
  if option then
    answer_box(chat, option.box, option.n)
  else
    focus_composer(chat)
  end
end

local function map(buf, modes, lhs, fn, desc)
  vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = desc })
end

-- [[ and ]]: the cursor to your message before or after it, by the prompt glyph at a line's start,
-- in the conversation only: a draft isn't a message yet. ]] after your last one goes to the composer.
local function jump_prompt(chat, step)
  local buf = vim.api.nvim_get_current_buf()
  local stop = compose.start(buf)
  local row = math.min(vim.api.nvim_win_get_cursor(0)[1], stop + 1)
  local mark = GLYPH.prompt .. " "
  row = row + step
  while row >= 1 and row <= stop do
    if vim.startswith(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "", mark) then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.cmd("normal! zz")
      return
    end
    row = row + step
  end
  -- Past your last message, ]] goes to the end, as G does.
  if step > 0 then
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

-- Asks for one of the chat's options (model or effort) from the adapter's list, the current one marked.
local function choose(chat, configId, done)
  local option = chat.session:option(configId)
  if not (option and option.options) then
    return vim.notify(("this chat has no %s to choose"):format(configId), vim.log.levels.WARN)
  end
  vim.ui.select(option.options, {
    prompt = configId,
    format_item = function(item)
      return (item.value == option.currentValue and "● " or "  ") .. (item.name or item.value)
    end,
  }, function(item)
    if item then
      done(item.value)
    end
  end)
end

-- <leader>M: the model, then the effort, this chat runs at. Each choice is saved on the chat and
-- applied again when it's opened.
local function pick_model(chat)
  choose(chat, "model", function(model)
    chat.session:configure("model", model, function(ok)
      if not ok then
        return
      end
      chat.record.model = model
      require("icarus.chats").save(chat.record)
      choose(chat, "effort", function(effort)
        chat.session:configure("effort", effort, function(effort_ok)
          if effort_ok then
            chat.record.effort = effort
            require("icarus.chats").save(chat.record)
          end
        end)
      end)
    end)
  end)
end

local function map_keys(chat)
  local function cancel()
    chat.session:cancel()
  end
  map(chat.buf, "n", "za", function()
    toggle(chat)
  end, "Open or close the tool call or thought")
  for _, buf in ipairs({ chat.buf, thread.buf(chat) }) do
    compose.keys(buf, chat)
    images.setup(buf, chat, chat.buf)
    map(buf, "n", "<leader>M", function()
      pick_model(chat)
    end, "The model and effort this chat runs at")
    map(buf, "n", "<CR>", function()
      enter(chat)
    end, "Send, answer the option here, or type in the composer")
    map(buf, "n", "[[", function()
      jump_prompt(chat, -1)
    end, "Your previous message")
    map(buf, "n", "]]", function()
      jump_prompt(chat, 1)
    end, "Your next message")
    -- In the composer they're vim's own; in the conversation they go to the composer.
    for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
      vim.keymap.set("n", key, function()
        if compose.inside(buf) then
          return key
        end
        return ("<Cmd>lua require('icarus.acp.chat').focus(%q)<CR>"):format(chat.record.id)
      end, { buffer = buf, nowait = true, expr = true, desc = "Type in the composer" })
    end
    map(buf, "i", "<CR>", function()
      send(chat)
    end, "Send")
    for _, key in ipairs({ "<S-CR>", "<M-CR>" }) do
      map(buf, "i", key, "<CR>", "New line")
    end
    map(buf, { "n", "i" }, "<C-c>", cancel, "Interrupt Claude")
  end
end

local function scratch(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

-- What a chat's session says, drawn.
M.hear = {
  session = function(chat, id)
    if chat.record.session ~= id then
      chat.record.session = id
      chats.save(chat.record)
    end
  end,
  update = on_update,
  subagent = function(chat, id, update)
    require("icarus.subagents").update(chat, id, update)
  end,
  prompt = draw_prompt,
  turn = on_turn,
  permission = ask_permission,
  notice = function(chat, text)
    chat.busy = false
    drop_boxes(chat)
    notice(chat, text)
    update_status(chat)
    update_bar(chat)
  end,
}

---@param record icarus.ChatRecord
---@return icarus.Chat
function M.get(record)
  local chat = open_chats[record.id]
  if chat then
    return chat
  end
  chat = { record = record, fresh = true, tools = {}, boxes = {}, options = {}, busy = false, turn_chars = 0 }
  chat.buf = scratch("icarus://chat/" .. record.id, "icarus_chat")
  vim.bo[chat.buf].modifiable = false
  compose.init(chat, chat.buf)
  open_chats[record.id] = chat
  map_keys(chat)
  local function hear(name)
    return function(...)
      require("icarus.acp.chat").hear[name](chat, ...)
    end
  end
  chat.session = session.start(record.cwd, record.session, {
    on_session = hear("session"),
    on_update = hear("update"),
    on_prompt = hear("prompt"),
    on_turn = hear("turn"),
    on_permission = hear("permission"),
    on_notice = hear("notice"),
    on_subagent = hear("subagent"),
  }, record.id)
  return chat
end

-- smoothscroll: a long reply is one wrapped line, and the screen scrolls through it a row at a time.
local CHAT_WINDOW = { wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = "nc",
  smoothscroll = true, number = false, relativenumber = false, signcolumn = "no", list = false, cursorline = false }

-- Shows the chat in win; the cursor goes to the composer.
function M.show(chat, win)
  local buf = thread.wanted(chat)
  compose.carry(chat, buf)
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs(CHAT_WINDOW) do
    vim.wo[win][0][name] = value
  end
  update_bar(chat)
  tables.fit(chat)
  vim.api.nvim_set_current_win(win)
  focus_composer(chat)
end

-- What a chat left on win, gone: win is about to show something that isn't a chat.
function M.leave(win)
  require("icarus.acp.queue").hide(win)
  vim.wo[win].winbar = ""
end

-- A chat from before its composer was in its buffer (a hot reload of code that had the composer in a
-- window of its own): its buffers get a composer, what was typed goes into it, and the window goes.
local function migrate(chat)
  local input = chat.input
  if not input then
    return
  end
  local alive = vim.api.nvim_buf_is_valid(input)
  local typed = alive and vim.api.nvim_buf_get_lines(input, 0, -1, false) or { "" }
  local boxes = alive and vim.fn.win_findbuf(input) or {}
  local current = vim.api.nvim_get_current_win()
  local typing = vim.tbl_contains(boxes, current)
  local at
  if typing then
    local row, col = unpack(vim.api.nvim_win_get_cursor(current))
    at = { row - 1, col }
  end
  local wins = thread.windows(chat)
  local following = {}
  for _, win in ipairs(wins) do
    following[win] = vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.w[win].icarus_composer = nil
  end
  compose.init(chat, chat.buf)
  compose.init(chat, thread.buf(chat))
  images.adopt(input, chat.buf)
  compose.carry(chat, thread.wanted(chat))
  compose.set(chat, typed)
  for _, win in ipairs(boxes) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and (following[win] or typing) then
      compose.place(win, typing and at or nil)
    end
  end
  if typing and wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
    vim.api.nvim_set_current_win(wins[1])
  end
  if alive then
    pcall(vim.api.nvim_buf_delete, input, { force = true })
  end
  chat.input = nil
end

-- After a hot reload: the open chats' keys and sessions run the new code.
function M.rebind()
  for _, chat in pairs(open_chats) do
    migrate(chat)
    map_keys(chat)
    session.adopt(chat.session)
    update_bar(chat)
  end
end

-- Stops a chat's session and drops its buffers, if it's open; it isn't shown anywhere.
function M.stop(id)
  local chat = open_chats[id]
  if chat then
    open_chats[id] = nil
    chat.session:stop()
    pcall(vim.api.nvim_buf_delete, chat.buf, { force = true })
    pcall(vim.api.nvim_buf_delete, chat.thread, { force = true })
  end
end

function M.stop_all()
  for _, chat in pairs(open_chats) do
    chat.session:stop()
  end
end

look.highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("icarus_chat_hl", { clear = true }),
  callback = look.highlights,
})
-- A window split from a chat's would start with its spinner line.
vim.api.nvim_create_autocmd("WinNew", {
  group = vim.api.nvim_create_augroup("icarus_chat_win", { clear = true }),
  callback = function()
    if vim.wo.winbar:find("IcarusAcp", 1, true) then
      vim.wo.winbar = ""
    end
  end,
})

return M
