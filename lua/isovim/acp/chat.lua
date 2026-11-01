-- An ACP agent's chat in the TUI: a buffer drawn from its journal (isovim.acp.journal), replayed
-- from the start and then followed, so closing and reopening the TUI rebuilds it as it was, and a
-- composer below it whose text goes to the agent's supervisor over its socket when sent, so
-- nothing an agent sends ever lands in what you're typing. Minimal, after agentic.nvim's renderer
-- and in the direction of Claude's screen: prompts (❯), the agent's text streamed in place (⏺),
-- each tool call a line updated in place with its output folded under it, denials and the
-- supervisor's notices. Extmarks keep every tool call's and message's place. Folds come from a
-- foldexpr over its text, so they hold in every window and survive one being hidden. The
-- view follows new output only while the cursor is on the last line.
--
-- Chat keys: ]] [[ your own prompts, ]m [m any message, za zo zc the output of the tool call under
-- the cursor, i a o <CR> the composer, <C-c> cancels the turn, gf the file on the line. Composer
-- keys: <CR> sends (queued while the agent works), <S-CR> or <C-j> a new line, <C-c> cancels the turn, <Up> <Down> your
-- earlier prompts while it's empty, <Esc> normal mode, <C-k> the chat.
local acp = require("isovim.acp")
local journal = require("isovim.acp.journal")
local store = require("isovim.store")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_acp_chat")
-- Places: tool calls (with their output's extent) and messages, apart from highlights.
local TOOLS = vim.api.nvim_create_namespace("isovim_acp_tools")
local MESSAGES = vim.api.nvim_create_namespace("isovim_acp_messages")
local MINE = vim.api.nvim_create_namespace("isovim_acp_mine")

---@class isovim.acp.Chat
---@field ws string
---@field agent string
---@field buf integer
---@field composer integer
---@field stop fun()
---@field block? "agent"|"other" what the last line is: streaming agent text, or anything else
---@field tools table<string, {mark: integer, title: string, status: string, body: integer}>
---@field queued table<string, integer> prompt id -> extmark of its queued line
---@field history string[] your prompts, oldest first, for <Up>/<Down> in the composer
---@field recall? integer which of them the composer shows

-- Live in _G so a hot reload keeps the chats the old code opened.
_G.isovim_acp_chats = _G.isovim_acp_chats or {} ---@type table<string, isovim.acp.Chat>
local chats = _G.isovim_acp_chats

local HL = {
  prompt = "Title",
  agent = "Normal",
  notice = "Comment",
  denied = "WarningMsg",
  queued = "Comment",
  body = "Comment",
  status = { pending = "Comment", in_progress = "DiagnosticInfo", completed = "DiagnosticOk", failed = "DiagnosticError" },
}

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

-- Windows showing the chat with their cursor on its last line, which keep following it.
local function followers(buf)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
  end, vim.fn.win_findbuf(buf))
end

local function edit(chat, fn)
  local buf = chat.buf
  local follow = followers(buf)
  vim.bo[buf].modifiable = true
  fn(buf)
  vim.bo[buf].modifiable = false
  local last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(follow) do
    pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
  end
end

local function highlight(buf, row, count, hl)
  for i = 0, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = hl })
  end
end

-- Adds whole lines at the end; returns the first one's row. A buffer that's only its first empty
-- line takes them in its place.
local function add_lines(chat, lines, hl)
  local row
  edit(chat, function(buf)
    local empty = vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    row = empty and 0 or vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    if hl then
      highlight(buf, row, #lines, hl)
    end
  end)
  chat.block = "other"
  return row
end

-- Every message's first line is marked, and your own prompts' again in MINE, for ]] [[ and ]m [m.
local function mark_message(chat, row, mine)
  vim.api.nvim_buf_set_extmark(chat.buf, MESSAGES, row, 0, {})
  if mine then
    vim.api.nvim_buf_set_extmark(chat.buf, MINE, row, 0, {})
  end
end

-- Streams the agent's text onto the end of the buffer, a new message after anything else.
local function add_text(chat, text)
  if chat.block ~= "agent" then
    local row = add_lines(chat, { "", "⏺ " }) + 1
    mark_message(chat, row, false)
    chat.block = "agent"
  end
  edit(chat, function(buf)
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
    vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
  end)
end

-- What a tool call's content says, as the lines folded under it.
local function body_lines(content)
  local lines = {}
  for _, item in ipairs(type(content) == "table" and content or {}) do
    if item.type == "content" and type(item.content) == "table" and item.content.type == "text" then
      vim.list_extend(lines, vim.split(item.content.text or "", "\n", { plain = true }))
    elseif item.type == "diff" then
      local old = item.oldText and #vim.split(item.oldText, "\n") or 0
      local new = item.newText and #vim.split(item.newText, "\n") or 0
      lines[#lines + 1] = ("%s: %d lines → %d lines"):format(item.path or "a file", old, new)
    elseif item.type == "terminal" then
      lines[#lines + 1] = "(terminal " .. tostring(item.terminalId) .. ")"
    end
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
  end
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "  ⎿ " or "    ") .. line
  end
  return lines
end

-- A tool call is a line, rewritten in place as its title or status changes, with its output
-- (when it has some) under it, folded.
local function tool(chat, update)
  local id = update.toolCallId or "?"
  local call = chat.tools[id]
  local body = update.content ~= nil and body_lines(update.content) or nil
  if not call then
    if chat.block == "agent" then
      add_lines(chat, { "" })
    end
    call = { title = update.title or "tool", status = update.status or "pending", body = 0 }
    local row = add_lines(chat, { "" })
    call.mark = vim.api.nvim_buf_set_extmark(chat.buf, TOOLS, row, 0, {})
    chat.tools[id] = call
  end
  call.title = update.title or call.title
  call.status = update.status or call.status
  local row = vim.api.nvim_buf_get_extmark_by_id(chat.buf, TOOLS, call.mark, {})[1]
  if not row then
    return
  end
  local bullet = "• "
  local header = bullet .. ("%s · %s"):format(call.title, call.status)
  edit(chat, function(buf)
    local replaced = body and (row + 1 + call.body) or (row + 1)
    vim.api.nvim_buf_clear_namespace(buf, NS, row, replaced)
    vim.api.nvim_buf_set_lines(buf, row, replaced, false, vim.list_extend({ header }, body or {}))
    vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { end_col = #bullet, hl_group = HL.status[call.status] or "Special" })
    vim.api.nvim_buf_set_extmark(buf, NS, row, #bullet, { end_col = #header, hl_group = "Special" })
    if body then
      highlight(buf, row + 1, #body, HL.body)
      call.body = #body
    end
    vim.api.nvim_buf_set_extmark(buf, TOOLS, row, 0, { id = call.mark, end_row = row + call.body, end_col = 0 })
  end)
end

local function prompt_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "❯ " or "  ") .. line
  end
  return lines
end

local RENDER = {}

function RENDER.prompt(chat, entry)
  -- Sent now: the line that said it was queued goes.
  local mark = entry.id and chat.queued[entry.id]
  local pos = mark and vim.api.nvim_buf_get_extmark_by_id(chat.buf, NS, mark, {})
  if pos and pos[1] then
    edit(chat, function(buf)
      vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false, {})
    end)
    chat.queued[entry.id] = nil
  end
  add_lines(chat, { "" })
  -- Yours: typed in a composer, or iso spawn's; not one iso send or msg delivered.
  local mine = entry.via ~= "iso"
  local row = add_lines(chat, prompt_lines(entry.text or ""), HL.prompt)
  mark_message(chat, row, mine)
  if mine and entry.text and chat.history[#chat.history] ~= entry.text then
    chat.history[#chat.history + 1] = entry.text
  end
end

function RENDER.queued(chat, entry)
  local row = add_lines(chat, { ("(queued) %s"):format((entry.text or ""):gsub("\n", " ")) }, HL.queued)
  chat.queued[entry.id or ""] = vim.api.nvim_buf_set_extmark(chat.buf, NS, row, 0, {})
end

function RENDER.update(chat, entry)
  local update = entry.update or {}
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" and type(update.content) == "table" and update.content.type == "text" then
    add_text(chat, update.content.text or "")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    tool(chat, update)
  end
end

function RENDER.turn(chat, entry)
  if entry.state == "end" and (entry.error or (entry.stopReason and entry.stopReason ~= "end_turn")) then
    add_lines(chat, { ("[turn ended: %s]"):format(entry.error or entry.stopReason) }, HL.notice)
  end
end

function RENDER.permission(chat, entry)
  add_lines(chat, { ("%s: %s (%s)"):format(entry.decision or "denied", entry.tool or "a tool", entry.reason or "approvals not built yet") },
    HL.denied)
end

function RENDER.notice(chat, entry)
  add_lines(chat, { "[" .. (entry.text or "") .. "]" }, HL.notice)
end

function RENDER.session(chat, entry)
  if entry.how ~= "new" then
    add_lines(chat, { ("[%s session %s]"):format(entry.how == "resume" and "resumed" or "loaded", entry.sessionId or "") }, HL.notice)
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
end

local function reset(chat)
  chat.block, chat.tools, chat.queued, chat.history = nil, {}, {}, {}
  if vim.api.nvim_buf_is_valid(chat.buf) then
    for _, ns in ipairs({ NS, TOOLS, MESSAGES, MINE }) do
      vim.api.nvim_buf_clear_namespace(chat.buf, ns, 0, -1)
    end
    edit(chat, function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)
  end
end

-- The chat's fold levels, read from its text: a tool call's line ("• ") with output under it
-- ("  ⎿ ", then "    ") starts a fold that holds the output. Read from the text, not the extmarks,
-- so the levels nvim works out as a line changes are always the new ones.
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if vim.startswith(line, "• ") then
    return vim.startswith(vim.fn.getline(lnum + 1), "  ⎿ ") and ">1" or "0"
  elseif vim.startswith(line, "  ⎿ ") then
    return "1"
  elseif vim.startswith(line, "    ") then
    return "="
  end
  return "0"
end

-- A folded tool call shows its line and how much output is under it.
function M.foldtext()
  local more = vim.v.foldend - vim.v.foldstart
  return ("%s  … +%d line%s"):format(vim.fn.getline(vim.v.foldstart), more, more == 1 and "" or "s")
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

-- za zo zc on the tool call under the cursor, from its line or any line of its output; a call
-- with no output has no fold, and the key does nothing (rather than nvim's "no fold found").
local function fold(chat, cmd)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local marks = vim.api.nvim_buf_get_extmarks(chat.buf, TOOLS, { row, 0 }, 0, { details = true, limit = 1 })
  local mark = marks[1]
  local first, last = mark and mark[2], mark and (mark[4].end_row or mark[2])
  if not first or row > last then
    -- Not in a tool call: the key keeps its meaning, for any other fold.
    return pcall(vim.cmd, "normal! " .. cmd)
  end
  if last == first then
    return
  end
  vim.api.nvim_win_set_cursor(0, { first + 1, 0 })
  pcall(vim.cmd, "normal! " .. cmd)
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

local function make(ws, agent)
  local spec = store.agent(ws, agent) or {}
  local name = (spec.name or agent)
  local buf = scratch(("isovim-acp://%s/%s · %s"):format(ws, agent, name))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "isovim_acp"
  vim.b[buf].isovim_id, vim.b[buf].isovim_ws, vim.b[buf].isovim_agent = ws, ws, agent
  vim.b[buf].isovim_agent_name, vim.b[buf].isovim_agent_kind, vim.b[buf].isovim_acp = name, "claude", true
  vim.bo[buf].buflisted = true
  -- No smooth scrolling: its animation moves the cursor after a jump (so a key right after one acts
  -- on a line it passes through), and it lags a chat that follows its end.
  vim.b[buf].snacks_scroll = false

  local composer = scratch(("isovim-acp://%s/%s/composer"):format(ws, agent))
  vim.bo[composer].filetype = "isovim_composer"
  vim.b[composer].isovim_agent = agent
  -- Its workspace's, so it comes and goes with the chat when you switch workspaces.
  vim.b[composer].isovim_ws = ws
  vim.b[composer].isovim_composer = true
  -- No completion menu, whose keys would take <Up>, <Down> and <CR> (blink.cmp reads this).
  vim.b[composer].completion = false

  local chat = { ws = ws, agent = agent, buf = buf, composer = composer, tools = {}, queued = {}, history = {} }
  -- Window options follow the buffer into any window that shows it (a layout rebuilt, :b).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      local wo = vim.wo[vim.api.nvim_get_current_win()][0]
      wo.wrap, wo.number, wo.relativenumber = true, false, false
      wo.foldmethod, wo.foldexpr = "expr", "v:lua.require'isovim.acp.chat'.foldexpr(v:lnum)"
      wo.foldtext, wo.foldlevel, wo.foldenable = "v:lua.require'isovim.acp.chat'.foldtext()", 0, true
      -- A tool call with one line of output folds too.
      wo.foldminlines = 0
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = composer,
    callback = function()
      local wo = vim.wo[vim.api.nvim_get_current_win()][0]
      wo.winfixheight, wo.number, wo.relativenumber, wo.wrap = true, false, false, true
    end,
  })
  map_chat(chat)
  map_composer(chat)
  chat.stop = journal.follow(ws, agent, function(entry)
    render(chat, entry)
  end, function()
    reset(chat)
  end)
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

-- Shows the agent's chat in win, with its composer in a split below unless it's on screen.
---@return isovim.acp.Chat
function M.open(ws, agent, win)
  local chat = M.get(ws, agent)
  if not chat then
    M.close(ws, agent)
    chat = make(ws, agent)
    chats[key(ws, agent)] = chat
  end
  vim.api.nvim_win_set_buf(win, chat.buf)
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(chat.buf), 0 })
  if vim.fn.bufwinid(chat.composer) == -1 then
    vim.api.nvim_open_win(chat.composer, false, { split = "below", win = win, height = 5 })
  end
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
