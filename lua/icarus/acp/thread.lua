-- A chat's thread: the same conversation with only what you said and what the agent said back, no
-- tool calls, thoughts, plans or notices; each reply a paragraph, the agent's turns split where it
-- went off to use tools. It's what a chat shows by default; <leader>d turns every chat to the full
-- conversation (details) and back. While a permission waits on you a chat shows its details, where
-- the options are, and goes back to its thread once you've answered.
--
-- The thread is a buffer of its own (icarus://thread/<chat id>) fed alongside the conversation's
-- (icarus.acp.chat calls M.prompt, M.text and M.pause). A chat that was already going when its
-- thread was made (open from before threads, across a hot reload) has its thread read back from
-- Claude's transcript of its session, ~/.claude/projects/<its dir>/<session>.jsonl.
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_thread")
local PROMPT = "❯"
-- What an agent watching a file answers a diff that needs nothing (icarus.watch).
local QUIET = "·"

-- In _G, so a hot reload keeps it: whether chats show their details.
_G.icarus_thread = _G.icarus_thread or { details = false }
local state = _G.icarus_thread

function M.details()
  return state.details
end

-- What icarus itself sends an agent, as the chat shows it: a line, not the whole of it.
local LABELS = {
  { "^The user turned on watch for (%S+):", function(path) return "◉ watching " .. vim.fs.basename(path) end },
  { "^(%S+) changed %(line numbers", function(path) return "◉ " .. vim.fs.basename(path) .. " changed" end },
  { "^Request %d+ on (%S+), line (%d+)", function(path, line) return ("◉ ask on %s:%s"):format(vim.fs.basename((path:gsub(",$", ""))), line) end },
  { "^They commented on line (%d+) of (%S+)", function(line, path) return ("◉ comment on %s:%s"):format(vim.fs.basename(path), line) end },
  { "^They replied in the thread of comment %S+ on line (%d+) of (%S+)", function(line, path) return ("◉ reply on %s:%s"):format(vim.fs.basename(path), line) end },
  { "^Your comment %S+ on (%S+), line (%d+)", function(path, line) return ("◉ rewrite on %s:%s"):format(vim.fs.basename((path:gsub(",$", ""))), line) end },
  { "^Bug (%w+), filed with ica bug", function(id) return "◉ bug " .. id end },
  { "^Message from the agent (.-) %(icarus://agent/[^)]+%).-:\n\n(.*)$", function(from, body)
    return ("◉ from %s:\n%s"):format(from, vim.trim((body:gsub("\n\nIf it needs an answer: `ica msg [^`]*`%.%s*$", ""))))
  end },
}

function M.label(text)
  local parts = {}
  for _, part in ipairs(vim.split(text, "\n\n---\n\n", { plain = true })) do
    local shown = part
    for _, each in ipairs(LABELS) do
      local caught = { part:match(each[1]) }
      if caught[1] then
        shown = each[2](unpack(caught))
        break
      end
    end
    parts[#parts + 1] = shown
  end
  return table.concat(parts, "\n")
end

-- What was said in the chat's session, from Claude's transcript of it: {who, text} in order, or nil.
local function transcript(chat)
  local session = chat.record.session
  if not session then
    return nil
  end
  local base = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
  local path = ("%s/projects/%s/%s.jsonl"):format(base, (chat.record.cwd:gsub("[^%w]", "-")), session)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local said = {}
  for line in io.lines(path) do
    local ok, entry = pcall(vim.json.decode, line)
    local message = ok and type(entry) == "table" and not entry.isSidechain and not entry.isMeta and entry.message
    if type(message) == "table" and (entry.type == "user" or entry.type == "assistant") then
      local texts, tools = {}, false
      if type(message.content) == "string" then
        texts[1] = message.content
      elseif type(message.content) == "table" then
        for _, block in ipairs(message.content) do
          if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            texts[#texts + 1] = block.text
          elseif type(block) == "table" and (block.type == "tool_use" or block.type == "tool_result") then
            tools = true
          end
        end
      end
      local text = vim.trim(table.concat(texts, "\n"))
      -- Claude Code's own wrappers (reminders, commands, its nudge after an empty reply) and an agent's
      -- quiet "·" aren't what anyone said.
      if text ~= "" and text ~= QUIET and not text:match("^<[%w%-]+>") and not text:match("^%[Your previous response had no visible output") then
        said[#said + 1] = { who = entry.type == "user" and "you" or "agent", text = text }
      elseif tools and #said > 0 then
        said[#said + 1] = { who = "tools" }
      end
    end
  end
  return said
end

-- What was said in the session of the chat with record, open or not: {who, text} in order, or nil.
function M.said(record)
  return transcript({ record = record })
end

---@return integer buf
function M.buf(chat)
  if chat.thread and vim.api.nvim_buf_is_valid(chat.thread) then
    return chat.thread
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "icarus_thread"
  pcall(vim.api.nvim_buf_set_name, buf, "icarus://thread/" .. chat.record.id)
  pcall(vim.treesitter.start, buf, "markdown")
  chat.thread, chat.thread_block = buf, nil
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  chat.thread_fresh = true
  vim.bo[buf].modifiable = false
  -- Made over a conversation that's already going: what came before, from the transcript.
  local before = vim.api.nvim_buf_line_count(chat.buf) > 1 or (vim.api.nvim_buf_get_lines(chat.buf, 0, 1, false)[1] or "") ~= ""
  if before then
    local said = transcript(chat)
    if said and #said > 0 then
      for _, each in ipairs(said) do
        if each.who == "you" then
          M.prompt(chat, each.text)
        elseif each.who == "agent" then
          M.text(chat, each.text)
        else
          M.pause(chat)
        end
      end
      M.pause(chat)
    else
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(earlier messages are in this chat's details: <leader>d)" })
      vim.bo[buf].modifiable = false
      vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, { end_col = #vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], hl_group = "IcarusAcpNotice" })
      chat.thread_fresh = false
    end
  end
  return buf
end

-- Reads the thread of every open chat again, from what's been said so far.
function M.rebuild()
  for _, chat in pairs(_G.icarus_open_chats or {}) do
    if chat.thread and vim.api.nvim_buf_is_valid(chat.thread) then
      local old = chat.thread
      chat.thread = nil
      pcall(vim.api.nvim_buf_set_name, old, "")
      local fresh = M.buf(chat)
      for _, win in ipairs(vim.fn.win_findbuf(old)) do
        vim.api.nvim_win_set_buf(win, fresh)
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(fresh), 0 })
      end
      pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
  end
  -- The new buffers' keys.
  require("icarus.acp.chat").rebind()
end

-- Changes the thread with fn; windows whose cursor was on its last line stay on it.
local function edit(chat, fn)
  local buf = M.buf(chat)
  local last = vim.api.nvim_buf_line_count(buf)
  local follow = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_cursor(win)[1] == last
  end, vim.fn.win_findbuf(buf))
  vim.bo[buf].modifiable = true
  pcall(fn, buf)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(follow) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

-- New lines at the end, after a blank one unless the thread is empty; returns their first row.
local function block(chat, lines)
  local row
  edit(chat, function(buf)
    if chat.thread_fresh then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      row = 0
    else
      row = vim.api.nvim_buf_line_count(buf) + 1
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.list_extend({ "" }, lines))
    end
  end)
  chat.thread_fresh = false
  return row
end

-- Your message, or what icarus sent the agent as a line (M.label).
function M.prompt(chat, text)
  local lines = vim.split(M.label(text), "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and PROMPT .. " " or "  ") .. line
  end
  local row = block(chat, lines)
  local buf = M.buf(chat)
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_set_extmark(buf, NS, row + i, 0, { line_hl_group = "IcarusAcpPrompt" })
  end
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { end_col = #PROMPT, hl_group = "IcarusAcpPromptGlyph" })
  chat.thread_block = nil
end

-- What the agent says, as it streams.
function M.text(chat, text)
  if chat.thread_block ~= "agent" then
    text = text:gsub("^\n+", "")
    if text == "" or vim.trim(text) == QUIET then
      return
    end
    block(chat, { "" })
    chat.thread_block = "agent"
  end
  local parts = vim.split(text, "\n", { plain = true })
  edit(chat, function(buf)
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
  end)
end

-- The agent went off to do something else (a tool, a thought): what it says next is a new paragraph.
function M.pause(chat)
  if chat.thread_block == "agent" then
    chat.thread_block = "paused"
  end
end

-- The buffer a chat's windows should show now.
function M.wanted(chat)
  if state.details or #chat.boxes > 0 then
    return chat.buf
  end
  return M.buf(chat)
end

-- The windows showing chat, its thread or its details.
function M.windows(chat)
  return vim.tbl_filter(function(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return buf == chat.buf or buf == chat.thread
  end, vim.api.nvim_tabpage_list_wins(0))
end

-- Each window showing chat shows what it should, its cursor at the end.
function M.sync(chat)
  local want = M.wanted(chat)
  for _, win in ipairs(M.windows(chat)) do
    if vim.api.nvim_win_get_buf(win) ~= want then
      vim.api.nvim_win_set_buf(win, want)
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(want), 0 })
    end
  end
end

-- <leader>d: every chat to its details, or back to its thread.
function M.toggle()
  state.details = not state.details
  for _, chat in pairs(_G.icarus_open_chats or {}) do
    M.sync(chat)
  end
  vim.cmd.redrawstatus()
  return state.details
end

return M
