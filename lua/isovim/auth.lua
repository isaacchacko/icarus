-- Whether claude (and codex) are logged in on this host: `claude auth status` (its loggedIn) and
-- `codex login status` (its exit code). A claude that isn't logged in still starts and opens
-- sessions, and then fails every prompt, so isovim asks first: checkhealth reports it, an ACP
-- agent's supervisor holds its queue while it's false (isovim.acp.host), and nothing that restarts a
-- running agent (iso restart, iso <role> restart, a supervisor's restart onto new code, a promotion's
-- reload, the migration of _/, iso move, iso rootmode on) does so while it's false: a restart must never turn a running agent into one that can't work.
--
-- An answer is kept for ISOVIM_AUTH_TTL seconds (default 20) in run/auth.<kind>.json, since each
-- iso command is a process of its own. One that can't be had (no claude, no JSON) is unknown (nil),
-- which blocks nothing. Pilots point ISOVIM_AUTH_CLAUDE and ISOVIM_AUTH_CODEX at a stand-in.
local store = require("isovim.store")

local M = {}

local function ttl()
  return tonumber(vim.env.ISOVIM_AUTH_TTL or "") or 20
end

local function exe(kind)
  local env = kind == "codex" and vim.env.ISOVIM_AUTH_CODEX or vim.env.ISOVIM_AUTH_CLAUDE
  return env and env ~= "" and env or require("isovim.panes").exe(kind)
end

local function cache_file(kind)
  return store.run .. "/auth." .. kind .. ".json"
end

---@return boolean? logged_in, string detail
local function probe(kind)
  local bin = exe(kind)
  if vim.fn.executable(bin) ~= 1 then
    return nil, kind .. " not found"
  end
  local cmd = kind == "codex" and { bin, "login", "status" } or { bin, "auth", "status" }
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, timeout = 15000 }):wait()
  end)
  if not ok or result.signal ~= 0 then
    return nil, table.concat(cmd, " ", 2) .. " didn't answer"
  end
  if kind == "codex" then
    local text = vim.trim((result.stdout or "") .. " " .. (result.stderr or ""))
    return result.code == 0, "codex login status: " .. (text ~= "" and text or ("exit " .. result.code))
  end
  local decoded, data = pcall(vim.json.decode, result.stdout or "", { luanil = { object = true } })
  if decoded and type(data) == "table" and type(data.loggedIn) == "boolean" then
    return data.loggedIn, ("claude auth status: loggedIn %s, authMethod %s"):format(tostring(data.loggedIn),
      tostring(data.authMethod or "none"))
  end
  return nil, "claude auth status gave no loggedIn"
end

-- Whether kind ("claude" or "codex") is logged in here: true, false, or nil when it can't be told.
-- fresh skips the kept answer.
---@return boolean? logged_in, string detail
function M.check(kind, fresh)
  kind = kind == "codex" and "codex" or "claude"
  local path = cache_file(kind)
  if not fresh and ttl() > 0 then
    local ok, lines = pcall(vim.fn.readfile, path)
    local decoded, kept = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "", { luanil = { object = true } })
    if decoded and type(kept) == "table" and type(kept.at) == "number" and os.time() - kept.at < ttl() then
      return kept.logged_in, kept.detail or ""
    end
  end
  local logged_in, detail = probe(kind)
  pcall(function()
    vim.fn.mkdir(store.run, "p")
    local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
    vim.fn.writefile({ vim.json.encode({ at = os.time(), logged_in = logged_in, detail = detail }) }, tmp)
    vim.uv.fs_rename(tmp, path)
  end)
  return logged_in, detail
end

-- What an agent of this kind needs logged in: "claude" (ACP agents too), "codex", or nil.
---@param agent isovim.Agent
function M.kind_of(agent)
  if agent and (agent.kind == "claude" or agent.kind == "codex") then
    return agent.kind
  end
end

-- nil when kind is logged in here (or it can't be told), else why not, as one line.
---@return string?
function M.why(kind, fresh)
  local logged_in, detail = M.check(kind, fresh)
  if logged_in == false then
    local fix = kind == "codex" and "run codex login" or "run claude, then /login"
    return ("%s needs login (%s); %s"):format(kind, detail, fix)
  end
end

-- nil when agent may be restarted here, else why not.
---@param agent isovim.Agent
---@return string?
function M.restart_blocked(agent)
  local kind = M.kind_of(agent)
  return kind and M.why(kind) or nil
end

return M
