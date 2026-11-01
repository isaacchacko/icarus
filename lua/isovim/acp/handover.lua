-- What iso handover needs beyond the supervisor (isovim.acp.host): Claude's own transcript of the
-- session ($CLAUDE_CONFIG_DIR/projects/<dir key>/<session>.jsonl), read from where it was when the
-- session was handed over, so what you and Claude did on Claude's own screen goes into the chat's
-- journal as prompts, text and tool calls, and the chat carries on with no gap.
local M = {}

-- The one Claude writes to now, under the project of dir, the cwd it runs in (a migration leaves
-- an old copy elsewhere).
function M.transcript(id, dir)
  return require("isovim.panes").claude_transcript(id, dir)
end

function M.size(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.size or 0
end

-- A tool call's title, as the adapter would give it: the tool and what it was run on.
local function title(name, input)
  input = type(input) == "table" and input or {}
  local on = input.command or input.file_path or input.path or input.pattern or input.url or input.description
  return on and (name .. " " .. tostring(on)) or name
end

local function text_of(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "text" then
      parts[#parts + 1] = block.text or ""
    end
  end
  return table.concat(parts, "\n")
end

-- Journal entries ({kind, fields}) for what the transcript gained after offset bytes. Claude's
-- own bookkeeping (meta lines, sidechains, command echoes like <command-name>) is left out.
---@return {[1]: string, [2]: table}[]
function M.entries(path, offset)
  local entries = {}
  local file = path and io.open(path, "r")
  if not file then
    return entries
  end
  file:seek("set", offset or 0)
  for line in file:lines() do
    local ok, row = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    local message = ok and type(row) == "table" and not row.isMeta and not row.isSidechain and row.message or nil
    if type(message) == "table" and row.type == "user" then
      local text = vim.trim(text_of(message.content))
      if text ~= "" and not vim.startswith(text, "<") then
        entries[#entries + 1] = { "prompt", { text = text, via = "claude" } }
      end
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(block) == "table" and block.type == "tool_result" then
          entries[#entries + 1] = { "update", { update = {
            sessionUpdate = "tool_call_update",
            toolCallId = block.tool_use_id,
            status = block.is_error and "failed" or "completed",
            content = { { type = "content", content = { type = "text", text = text_of(block.content) } } },
          } } }
        end
      end
    elseif type(message) == "table" and row.type == "assistant" then
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(block) == "table" and block.type == "text" and block.text ~= "" then
          entries[#entries + 1] = { "update", { update = { sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = block.text } } } }
        elseif type(block) == "table" and block.type == "tool_use" then
          entries[#entries + 1] = { "update", { update = { sessionUpdate = "tool_call", toolCallId = block.id,
            title = title(block.name, block.input), status = "pending" } } }
        end
      end
    end
  end
  file:close()
  return entries
end

return M
