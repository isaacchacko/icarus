-- Which ACP agent an ACP agent runs, and how: the launch table, one adapter per kind, each at a
-- pinned version installed once per host with npm into isovim's data dir
-- (~/.local/share/isovim/acp/<name>@<version>) and run with node. A pinned install, not npx: npx
-- asks the registry on every start and fails offline, and a version that never changes under an
-- agent is what keeps a restart resuming the same way.
--   claude  claude-agent-acp. It runs the user's own claude (CLAUDE_CODE_EXECUTABLE), not the one
--           bundled with its SDK, which drops the user's settings, hooks and plugins and can lose
--           history on resume; CLAUDE_CODE_ENTRYPOINT keeps its sessions in claude --resume's
--           picker, which hides the SDK's default (sdk-ts). The role prompt and isovim's hooks go
--           in each session request's _meta (claudeCode options).
--   codex   codex-acp, with the Codex it bundles (a version it's tested with; CODEX_HOME and so
--           the user's config, login and sessions are the user's own). The role prompt goes in
--           each session request's systemPrompt (append); isovim's hooks go in CODEX_CONFIG at
--           start, which codex-acp hands its app server, and are trusted once over
--           _codex/hooks/trust (Codex asks before running a hook it hasn't seen). Codex has no
--           PreToolUse for its edits, so a codex agent's first edit doesn't make its worktree (it
--           runs iso <role> wt) and a read-only one is held by Codex's own read-only sandbox mode.
-- $ISOVIM_ACP_CMD replaces the adapter for every kind (pilots run pilot/fake-acp-agent).
local M = {}

---@class isovim.acp.Adapter
---@field package string
---@field version string
---@field main string its entry, under the package
---@field mode string the session mode the supervisor sets: no permission prompts
---@field read_only_mode? string the mode for a read-only agent, where the adapter has one

---@type table<string, isovim.acp.Adapter>
M.adapters = {
  claude = { package = "@agentclientprotocol/claude-agent-acp", version = "0.99.1", main = "dist/index.js",
    mode = "bypassPermissions" },
  codex = { package = "@agentclientprotocol/codex-acp", version = "2.5.0", main = "dist/index.js",
    mode = "agent-full-access", read_only_mode = "read-only" },
}

-- claude's, as callers from before the table name them.
M.package = M.adapters.claude.package
M.version = M.adapters.claude.version
M.entrypoint = "isovim"

---@return isovim.acp.Adapter
function M.get(kind)
  return M.adapters[kind or "claude"] or M.adapters.claude
end

-- Whether kind runs over ACP: the kinds in the launch table.
function M.supports(kind)
  return M.adapters[kind] ~= nil
end

local function name_of(kind)
  return (M.get(kind).package:match("[^/]+$"))
end

function M.name(kind)
  return name_of(kind)
end

function M.dir(kind)
  local adapter = M.get(kind)
  return vim.fn.stdpath("data") .. "/acp/" .. name_of(kind) .. "@" .. adapter.version
end

function M.entry(kind)
  local adapter = M.get(kind)
  return M.dir(kind) .. "/node_modules/" .. adapter.package .. "/" .. adapter.main
end

function M.installed(kind)
  return vim.uv.fs_stat(M.entry(kind)) ~= nil
end

function M.install_cmd(kind)
  local adapter = M.get(kind)
  return { "npm", "install", "--no-audit", "--no-fund", "--loglevel=error", "--prefix", M.dir(kind), adapter.package .. "@" .. adapter.version }
end

-- Installs it if it isn't, into a temp dir renamed into place, under a lock (a dir only one
-- process can make), so two agents starting at once don't both install or see half of it.
---@return boolean ok, string? err
function M.ensure(kind)
  if vim.env.ISOVIM_ACP_CMD or M.installed(kind) then
    return true
  end
  local adapter = M.get(kind)
  local dir = M.dir(kind)
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  local lock = dir .. ".lock"
  local deadline = vim.uv.hrtime() + 300e9
  while not vim.uv.fs_mkdir(lock, 448) do
    local stat = vim.uv.fs_stat(lock)
    if M.installed(kind) then
      return true
    elseif stat and os.time() - stat.mtime.sec > 300 then
      vim.uv.fs_rmdir(lock)
    elseif vim.uv.hrtime() > deadline then
      return false, lock .. " is held"
    else
      vim.uv.sleep(200)
    end
  end
  local tmp = ("%s.tmp-%d"):format(dir, vim.uv.os_getpid())
  local cmd = M.install_cmd(kind)
  cmd[#cmd - 1] = tmp
  local result = vim.system(cmd, { text = true }):wait()
  local ok = result.code == 0 and vim.uv.fs_stat(tmp .. "/node_modules/" .. adapter.package .. "/" .. adapter.main) ~= nil
  if ok then
    vim.fn.delete(dir, "rf")
    ok = vim.uv.fs_rename(tmp, dir) ~= nil
  end
  vim.fn.delete(tmp, "rf")
  vim.uv.fs_rmdir(lock)
  if not ok then
    return false, "npm install failed: " .. vim.trim((result.stderr or "") .. (result.stdout or ""))
  end
  return true
end

-- The mode a session of this agent is set to. ISOVIM_ACP_MODE sets another for every agent (a pilot
-- runs claude in default, to see its permission prompts).
---@param spec isovim.Agent
function M.mode(spec)
  if vim.env.ISOVIM_ACP_MODE and vim.env.ISOVIM_ACP_MODE ~= "" then
    return vim.env.ISOVIM_ACP_MODE
  end
  local adapter = M.get(spec.kind)
  return spec.read_only and adapter.read_only_mode or adapter.mode
end

-- What a session request (new, resume, load, fork) carries for the agent: the instructions
-- appended to the adapter's own system prompt, and for claude isovim's hooks.
---@param params table the request's params, which get the fields
function M.session_params(kind, params, append_text)
  params._meta = params._meta or {}
  if (kind or "claude") == "codex" then
    params.systemPrompt = { mode = "append", content = { { type = "text", text = append_text } } }
  else
    params._meta.systemPrompt = { append = append_text }
    params._meta.claudeCode = { options = { settings = require("isovim.panes").hook_settings() },
      -- So the supervisor sees a turn Claude starts itself, between the prompts it sends.
      emitRawSDKMessages = { { type = "system", subtype = "session_state_changed" } } }
  end
  return params
end

-- What a throwaway session carries (isovim.acp.host's probe): for claude no transcript, tools or
-- settings. The user's settings aren't only slow: a session that loaded them cost $1.97 to say ok,
-- against $0.02, on 2026-11-01. Claude's default model is what most agents run, so a limit on it shows.
function M.probe_params(kind, params)
  if (kind or "claude") ~= "codex" then
    params._meta = { claudeCode = { options = { persistSession = false, settingSources = {}, tools = {}, maxTurns = 1,
      strictMcpConfig = true } } }
  end
  return params
end

-- How the supervisor starts it, in dir.
---@param spec? isovim.Agent the agent (its kind, read_only); claude when nil
---@return isovim.acp.TransportConfig
function M.command(dir, spec)
  spec = spec or { kind = "claude" }
  local env
  if spec.kind == "codex" then
    env = {
      CODEX_CONFIG = vim.json.encode({ hooks = require("isovim.panes").codex_hook_table() }),
      INITIAL_AGENT_MODE = M.mode(spec),
      -- An agent's supervisor has no browser to log in with: Codex is logged in already, or isn't.
      NO_BROWSER = "1",
    }
  else
    env = {
      CLAUDE_CODE_EXECUTABLE = require("isovim.panes").exe("claude"),
      CLAUDE_CODE_ENTRYPOINT = M.entrypoint,
    }
  end
  if vim.env.ISOVIM_ACP_CMD then
    local words = vim.split(vim.env.ISOVIM_ACP_CMD, " ", { trimempty = true })
    return { command = table.remove(words, 1), args = words, env = env, cwd = dir }
  end
  return { command = "node", args = { M.entry(spec.kind) }, env = env, cwd = dir }
end

return M
