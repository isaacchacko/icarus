-- Which ACP agent an ACP agent runs, and how: claude-agent-acp at a pinned version, installed once
-- per host with npm into isovim's data dir (~/.local/share/isovim/acp/claude-agent-acp@<version>),
-- run with node. A pinned install, not npx: npx asks the registry on every start and fails
-- offline, and a version that never changes under an agent is what keeps a restart resuming the
-- same way. The adapter runs the user's own claude (CLAUDE_CODE_EXECUTABLE), not the one bundled
-- with its SDK, which drops the user's settings, hooks and plugins and can lose history on
-- resume; CLAUDE_CODE_ENTRYPOINT keeps its sessions in claude --resume's picker, which hides the
-- SDK's default (sdk-ts). $ISOVIM_ACP_CMD replaces the adapter (pilots run pilot/fake-acp-agent).
local M = {}

M.package = "@agentclientprotocol/claude-agent-acp"
M.version = "0.99.1"
M.entrypoint = "isovim"

function M.dir()
  return vim.fn.stdpath("data") .. "/acp/claude-agent-acp@" .. M.version
end

function M.entry()
  return M.dir() .. "/node_modules/" .. M.package .. "/dist/index.js"
end

function M.installed()
  return vim.uv.fs_stat(M.entry()) ~= nil
end

function M.install_cmd()
  return { "npm", "install", "--no-audit", "--no-fund", "--loglevel=error", "--prefix", M.dir(), M.package .. "@" .. M.version }
end

-- Installs it if it isn't, into a temp dir renamed into place, under a lock (a dir only one
-- process can make), so two agents starting at once don't both install or see half of it.
---@return boolean ok, string? err
function M.ensure()
  if vim.env.ISOVIM_ACP_CMD or M.installed() then
    return true
  end
  local parent = vim.fs.dirname(M.dir())
  vim.fn.mkdir(parent, "p")
  local lock = M.dir() .. ".lock"
  local deadline = vim.uv.hrtime() + 300e9
  while not vim.uv.fs_mkdir(lock, 448) do
    local stat = vim.uv.fs_stat(lock)
    if M.installed() then
      return true
    elseif stat and os.time() - stat.mtime.sec > 300 then
      vim.uv.fs_rmdir(lock)
    elseif vim.uv.hrtime() > deadline then
      return false, lock .. " is held"
    else
      vim.uv.sleep(200)
    end
  end
  local tmp = ("%s.tmp-%d"):format(M.dir(), vim.uv.os_getpid())
  local cmd = M.install_cmd()
  cmd[#cmd - 1] = tmp
  local result = vim.system(cmd, { text = true }):wait()
  local ok = result.code == 0 and vim.uv.fs_stat(tmp .. "/node_modules/" .. M.package .. "/dist/index.js") ~= nil
  if ok then
    vim.fn.delete(M.dir(), "rf")
    ok = vim.uv.fs_rename(tmp, M.dir()) ~= nil
  end
  vim.fn.delete(tmp, "rf")
  vim.uv.fs_rmdir(lock)
  if not ok then
    return false, "npm install failed: " .. vim.trim((result.stderr or "") .. (result.stdout or ""))
  end
  return true
end

-- How the supervisor starts it, in dir.
---@return isovim.acp.TransportConfig
function M.command(dir)
  local env = {
    CLAUDE_CODE_EXECUTABLE = require("isovim.panes").exe("claude"),
    CLAUDE_CODE_ENTRYPOINT = M.entrypoint,
  }
  if vim.env.ISOVIM_ACP_CMD then
    local words = vim.split(vim.env.ISOVIM_ACP_CMD, " ", { trimempty = true })
    return { command = table.remove(words, 1), args = words, env = env, cwd = dir }
  end
  return { command = "node", args = { M.entry() }, env = env, cwd = dir }
end

return M
