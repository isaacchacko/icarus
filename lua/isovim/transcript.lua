-- Each agent's conversation as plain text, kept with its workspace in transcripts/<agent>.txt so it
-- moves with it: what was said and by whom, without tool calls, tool output or system text. The
-- agent's hooks rewrite it as the chat goes; iso find searches it and previews it at the match.
local store = require("isovim.store")
local panes = require("isovim.panes")

local M = {}

function M.path(ws, agent)
  return store.path(ws) .. "/transcripts/" .. agent .. ".txt"
end

-- The agent's raw log: Claude's <session>.jsonl under any project, or Codex's rollout.
---@return string?
function M.source(ws, agent)
  local spec = store.agent(ws, agent)
  local id = spec and store.session_id(ws, agent)
  if not id then
    return nil
  end
  if spec.kind == "codex" then
    return panes.codex_rollout(id)
  end
  local projects = vim.fs.dirname(panes.claude_project("/"))
  return vim.fn.glob(projects .. "/*/" .. id .. ".jsonl", false, true)[1]
end

-- Wrappers the harness puts around or between messages: system reminders, slash-command echoes,
-- Codex's environment context. What's left is what a person or the agent actually wrote.
local WRAPPERS = { "system%-reminder", "local%-command%-%w+", "command%-%w+", "environment_context", "user_instructions" }

local function said(text)
  for _, tag in ipairs(WRAPPERS) do
    text = text:gsub("<" .. tag .. ">.-</" .. tag .. ">", "")
  end
  return vim.trim(text)
end

local function texts(content, kinds)
  if type(content) == "string" then
    return { content }
  end
  local out = {}
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if kinds[part.type] and part.text then
      out[#out + 1] = part.text
    end
  end
  return out
end

local USER, ASSISTANT = { text = true, input_text = true }, { text = true, output_text = true }

-- What you type while Claude is mid-turn is logged as a queued command it absorbed, not as a user
-- message. Other agents' messages arrive the same way, marked as from a peer.
local function typed_mid_turn(entry)
  local attachment = entry.type == "attachment" and entry.attachment
  return type(attachment) == "table" and attachment.type == "queued_command" and attachment.commandMode == "prompt"
    and type(attachment.prompt) == "string" and type(attachment.origin) == "table" and attachment.origin.kind == "human"
end

-- A queued message can be logged both as typed mid-turn and as a user message; it's said once.
local function said_just_now(out, speaker, text)
  for i = #out, math.max(1, #out - 1), -1 do
    if out[i][1] == speaker and out[i][2] == text then
      return true
    end
  end
  return false
end

-- {speaker, text} turns from a Claude jsonl or a Codex rollout.
local function turns(file, agent_name)
  local out = {}
  for line in io.lines(file) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and not entry.isMeta then
      local role, content
      if entry.type == "user" or entry.type == "assistant" then
        role, content = entry.type, entry.message and entry.message.content
      elseif entry.type == "response_item" and entry.payload and entry.payload.type == "message" then
        role, content = entry.payload.role, entry.payload.content
      elseif typed_mid_turn(entry) then
        role, content = "user", entry.attachment.prompt
      end
      if role == "user" or role == "assistant" then
        local speaker = role == "user" and "You" or agent_name
        for _, text in ipairs(texts(content, role == "user" and USER or ASSISTANT)) do
          text = said(text)
          if text ~= "" and not (role == "user" and said_just_now(out, speaker, text)) then
            out[#out + 1] = { speaker, text }
          end
        end
      end
    end
  end
  return out
end

-- Rewrites the agent's transcript from its log; false when it has no log yet.
function M.write(ws, agent)
  local source = M.source(ws, agent)
  if not source then
    return false
  end
  local spec = store.agent(ws, agent)
  local lines, last = {}, nil
  for _, turn in ipairs(turns(source, spec and spec.name or agent)) do
    if turn[1] ~= last then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "## " .. turn[1]
      lines[#lines + 1] = ""
      last = turn[1]
    else
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, vim.split(turn[2], "\n", { plain = true }))
  end
  local path = M.path(ws, agent)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path .. ".tmp")
  vim.uv.fs_rename(path .. ".tmp", path)
  return path
end

-- The agent's latest answer: the transcript's text after its last "## You" section.
---@return string?
function M.last_answer(ws, agent)
  local ok, lines = pcall(vim.fn.readfile, M.path(ws, agent))
  if not ok then
    return nil
  end
  local start
  for i = #lines, 1, -1 do
    if lines[i] == "## You" then
      break
    elseif lines[i]:match("^## ") then
      start = i + 1
    end
  end
  return start and table.concat(lines, "\n", start) or nil
end

return M
