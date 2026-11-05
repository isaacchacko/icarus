-- A chat: the conversation in one read-only buffer, drawn as Claude Code draws its screen (the words,
-- colors and tool rows are icarus.acp.look's), and under it, in a window of its own, the composer,
-- where you type. Its session (icarus.acp.session) runs while icarus does.
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
-- The composer's winbar is Claude's spinner line while the agent works. <CR> sends (in insert mode
-- too, where <S-CR> is a new line), <C-c> interrupts the turn. A prompt sent while the agent works
-- waits its turn. A window whose cursor is on the conversation's last line follows it as it grows.
--
-- A hot reload (icarus.reload) keeps the open chats: they live in _G, what the session hears comes
-- in through require (M.hear), so the new code draws it, and M.rebind maps their keys to it. What's
-- drawn already stays as the old code drew it.
local images = require("icarus.acp.images")
local look = require("icarus.acp.look")
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
---@field input integer the composer
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

-- Changes the conversation with fn; windows whose cursor was on its last line stay on it.
local function edit(chat, fn)
  local buf = chat.buf
  local last = vim.api.nvim_buf_line_count(buf)
  local follow = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_cursor(win)[1] == last
  end, vim.fn.win_findbuf(buf))
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(follow) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
  if not ok then
    error(err, 0)
  end
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

-- How wide a table may be drawn: the widest window showing the chat, less the message's indent.
local function table_width(chat)
  local width = 0
  for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
    width = math.max(width, vim.api.nvim_win_get_width(win))
  end
  return (width > 0 and width or 102) - 2
end

-- Draws the tables in the streaming message whose lines have all come: a table is whole once a line
-- that isn't one of its rows follows it, or the message ends (whole). Runs inside edit.
local function draw_tables(chat, whole)
  local buf = chat.buf
  local last = vim.api.nvim_buf_line_count(buf) - (whole and 1 or 2)
  local row = math.max(chat.table_scan or chat.block_row, chat.block_row)
  local function prefix(line)
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
        span(buf, row, 0, #GLYPH.message, "IcarusAcpMessage")
      end
      for _, s in ipairs(spans) do
        local lead = #(s[1] == 0 and first or "  ")
        span(buf, row + s[1], lead + s[2], lead + s[3], s[4], 120)
      end
      last = last + #drawn - (n - 1)
      row = row + #drawn
    end
  end
  chat.table_scan = row
end

-- Adds whole lines at the end; returns the first one's row.
local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
    if chat.block == "agent" then
      draw_tables(chat, true)
    end
    row = chat.fresh and 0 or vim.api.nvim_buf_line_count(buf)
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
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
    markup(chat, row, vim.api.nvim_buf_line_count(buf) - 1)
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

-- What the composer's winbar says, as {text, hl} parts: while the agent works, Claude's spinner line.
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
  for _, win in ipairs(vim.fn.win_findbuf(chat.input)) do
    vim.wo[win].winbar = bar
  end
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
  if kind == "agent_message_chunk" or kind == "tool_call" or kind == "tool_call_update" or kind == "plan" then
    end_thought(chat)
  end
  if kind == "agent_message_chunk" and content.type == "text" then
    add_text(chat, content.text or "")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    tool(chat, update)
  elseif kind == "plan" then
    plan(chat, update)
  end
end

local function on_turn(chat, state, result)
  if state == "start" then
    chat.busy, chat.since, chat.turn_chars = true, now(), 0
    chat.verb = look.verb(chat.since)
  else
    end_thought(chat)
    chat.busy = false
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

local function focus_composer(chat)
  local win = vim.fn.win_findbuf(chat.input)[1]
  if win then
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert({ bang = true })
  end
end

local function send(chat)
  local lines = vim.api.nvim_buf_get_lines(chat.input, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  local attached
  text, attached = images.collect(chat.input, text)
  vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { "" })
  local n = tonumber(text:match("^(%d+)$"))
  if chat.boxes[1] and n then
    return answer_box(chat, chat.boxes[1], n)
  end
  if not chat.record.title then
    local title = text:match("^[^\n]*")
    chat.record.title = vim.fn.strchars(title) > 60 and vim.fn.strcharpart(title, 0, 59) .. "…" or title
    chats.save(chat.record)
  end
  chat.session:prompt(text, attached)
  update_bar(chat)
end

local function enter_on_conversation(chat)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local mark = vim.api.nvim_buf_get_extmarks(chat.buf, OPTIONS, { row, 0 }, { row, -1 }, { limit = 1 })[1]
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

local function map_keys(chat)
  local function cancel()
    chat.session:cancel()
  end
  map(chat.buf, "n", "<CR>", function()
    enter_on_conversation(chat)
  end, "Answer the option here, else type in the composer")
  map(chat.buf, "n", "za", function()
    toggle(chat)
  end, "Open or close the tool call or thought")
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    map(chat.buf, "n", key, function()
      focus_composer(chat)
    end, "Type in the composer")
  end
  map(chat.buf, "n", "<C-c>", cancel, "Interrupt Claude")
  map(chat.input, { "n", "i" }, "<CR>", function()
    send(chat)
  end, "Send")
  for _, key in ipairs({ "<S-CR>", "<M-CR>" }) do
    map(chat.input, "i", key, "<CR>", "New line")
  end
  map(chat.input, { "n", "i" }, "<C-c>", cancel, "Interrupt Claude")
  images.setup(chat.input)
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
  chat.input = scratch("icarus://composer/" .. record.id, "icarus_composer")
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
  })
  return chat
end

local CHAT_WINDOW = { wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = "nc",
  number = false, relativenumber = false, signcolumn = "no", list = false, cursorline = false }

-- Shows the chat in win, its composer in a window under it; the cursor goes to the composer.
function M.show(chat, win)
  vim.api.nvim_win_set_buf(win, chat.buf)
  for name, value in pairs(CHAT_WINDOW) do
    vim.wo[win][0][name] = value
  end
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(chat.buf), 0 })
  local input = vim.w[win].icarus_composer
  if not (input and vim.api.nvim_win_is_valid(input)) then
    input = vim.api.nvim_open_win(chat.input, false, { split = "below", win = win, height = 4 })
    vim.w[win].icarus_composer = input
    vim.w[input].icarus_composer_of = win
  end
  vim.api.nvim_win_set_buf(input, chat.input)
  vim.wo[input][0].winfixheight = true
  vim.wo[input][0].number = false
  vim.wo[input][0].relativenumber = false
  vim.wo[input][0].signcolumn = "no"
  update_bar(chat)
  focus_composer(chat)
end

-- The composer under win, closed: win is about to show something that isn't a chat.
function M.hide_composer(win)
  local input = vim.w[win].icarus_composer
  if input and vim.api.nvim_win_is_valid(input) then
    vim.api.nvim_win_close(input, true)
  end
  vim.w[win].icarus_composer = nil
end

-- After a hot reload: the open chats' keys and sessions run the new code.
function M.rebind()
  for _, chat in pairs(open_chats) do
    map_keys(chat)
    session.adopt(chat.session)
    update_bar(chat)
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

return M
