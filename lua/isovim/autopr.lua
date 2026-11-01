-- The backstop for `iso pr`: after each answer, a PR the agent opened itself (the URL in the
-- output of its own `gh pr create`) is registered under its workspace, so its CI and review state
-- show in the sidebar even when the agent forgets to. Read from the Claude conversation log, from
-- where the last run stopped.
local store = require("isovim.store")
local transcript = require("isovim.transcript")

local M = {}

local URL = "https://github%.com/[%w_.-]+/[%w_.-]+/pull/%d+"

local function offset_file(ws, agent)
  return store.run_dir(ws) .. "/" .. agent .. ".autopr"
end

---@return string[] urls registered
-- Not for a new-layout agent: in a repo only the router registers PRs, with iso pr.
function M.run(ws, agent)
  if store.v2(ws) then
    return {}
  end
  local spec = store.agent(ws, agent)
  local log = spec and spec.kind == "claude" and transcript.source(ws, agent)
  local file = log and io.open(log)
  if not file then
    return {}
  end
  local state = vim.fn.filereadable(offset_file(ws, agent)) == 1 and vim.fn.readfile(offset_file(ws, agent)) or {}
  local saved = state[1] == log and tonumber(state[2]) or 0
  local size = file:seek("end")
  file:seek("set", saved <= size and saved or 0)
  -- Tool calls still waiting on their result are carried over, in case a turn was cut between them.
  local pending = {}
  for _, id in ipairs(vim.split(state[3] or "", ",", { trimempty = true })) do
    pending[id] = true
  end
  local added = {}
  for line in file:lines() do
    local creates = line:find("gh pr create", 1, true)
    local results = next(pending) and line:find('"tool_result"', 1, true)
    if creates or results then
      local ok, entry = pcall(vim.json.decode, line)
      local content = ok and type(entry) == "table" and type(entry.message) == "table" and entry.message.content
      for _, part in ipairs(type(content) == "table" and content or {}) do
        if part.type == "tool_use" and type(part.input) == "table" and tostring(part.input.command or ""):find("gh pr create", 1, true) then
          pending[part.id] = true
        elseif part.type == "tool_result" and pending[part.tool_use_id] then
          pending[part.tool_use_id] = nil
          local text = type(part.content) == "string" and part.content or vim.json.encode(part.content)
          for url in text:gmatch(URL) do
            if store.add_pr(ws, url) then
              added[#added + 1] = url
            end
          end
        end
      end
    end
  end
  file:close()
  vim.fn.writefile({ log, tostring(size), table.concat(vim.tbl_keys(pending), ",") }, offset_file(ws, agent))
  return added
end

return M
