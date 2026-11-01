-- The backstop for pinning: after each answer, files and folders the answer names that really
-- exist are pinned under the workspace, so they're in the sidebar even when the agent forgets
-- (or started before it was told to). These are marked auto; the oldest go first past a cap, and
-- ones an agent pinned itself are never dropped.
local store = require("isovim.store")
local transcript = require("isovim.transcript")

local M = {}

local PER_ANSWER, PER_WORKSPACE = 5, 8

-- Path-looking tokens: ~/x, /x, or relative ones with a slash or a file extension.
local function candidates(text)
  local seen, out = {}, {}
  for token in text:gmatch("[^%s`'\"()%[%]<>,]+") do
    token = token:gsub("[.:;!?]+$", ""):gsub(":%d+[:%d%-]*$", "")
    local pathish = token:match("^[~/]") or token:match("/") or token:match("^[%w_.-]+%.%a%w*$")
    if pathish and not token:match("^%a+://") and not seen[token] then
      seen[token] = true
      out[#out + 1] = token
    end
  end
  return out
end

local function resolve(token, dir)
  local path = vim.fs.normalize(token)
  if not path:match("^/") then
    path = dir and (dir .. "/" .. path) or nil
  end
  path = path and vim.uv.fs_realpath(path)
  return path and vim.uv.fs_stat(path) and path or nil
end

---@return string[] paths pinned
function M.run(ws, agent)
  local spec = store.agent(ws, agent)
  local answer = spec and not spec.hidden and transcript.last_answer(ws, agent)
  if not answer then
    return {}
  end
  local dir = store.agent_dir(ws, agent)
  local skip = { [vim.uv.fs_realpath(vim.fs.normalize("~")) or ""] = true, [dir and vim.uv.fs_realpath(dir) or ""] = true }
  for _, entry in ipairs(store.pinned(ws)) do
    skip[vim.uv.fs_realpath(entry.path) or entry.path] = true
  end
  local added = {}
  for _, token in ipairs(candidates(answer)) do
    local path = resolve(token, dir)
    if path and not skip[path] then
      skip[path] = true
      store.pin(ws, path, vim.fs.basename(path), true)
      added[#added + 1] = path
      if #added == PER_ANSWER then
        break
      end
    end
  end
  store.trim_auto(ws, PER_WORKSPACE)
  return added
end

return M
