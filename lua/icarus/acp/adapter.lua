-- The ACP adapter a chat runs: claude-agent-acp at a pinned version, installed once with npm into
-- icarus's data dir (stdpath("data")/acp/claude-agent-acp@<version>) and run with node. A pinned
-- install, not npx: npx asks the registry on every start and fails offline, and a version that
-- never changes under a chat is what keeps a reopened chat loading the same way.
-- It runs the user's own claude (CLAUDE_CODE_EXECUTABLE), not the one bundled with its SDK, which
-- drops the user's settings, hooks and plugins and can lose history on resume; CLAUDE_CODE_ENTRYPOINT
-- keeps its sessions in claude --resume's picker, which hides the SDK's default (sdk-ts).
local M = {}

M.package = "@agentclientprotocol/claude-agent-acp"
M.version = "0.99.1"
M.mode = "bypassPermissions"

M.dir = vim.fn.stdpath("data") .. "/acp/claude-agent-acp@" .. M.version
M.entry = M.dir .. "/node_modules/" .. M.package .. "/dist/index.js"

-- Installs it if it isn't, in the background; done(err) on the main loop.
function M.ensure(done)
  if vim.uv.fs_stat(M.entry) then
    return done()
  end
  vim.fn.mkdir(M.dir, "p")
  vim.system({ "npm", "install", "--no-audit", "--no-fund", "--loglevel=error", "--prefix", M.dir,
    M.package .. "@" .. M.version }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 or not vim.uv.fs_stat(M.entry) then
      return done("npm install failed: " .. vim.trim((result.stderr or "") .. (result.stdout or "")))
    end
    done()
  end))
end

-- The first claude on PATH, past Superset's wrapper.
local function claude()
  for dir in vim.gsplit(vim.env.PATH or "", ":", { plain = true }) do
    local path = dir .. "/claude"
    if not dir:find("/%.superset") and vim.fn.executable(path) == 1 then
      return path
    end
  end
  return "claude"
end

---@return icarus.acp.TransportConfig
function M.command(cwd)
  return { command = "node", args = { M.entry }, cwd = cwd,
    env = { CLAUDE_CODE_EXECUTABLE = claude(), CLAUDE_CODE_ENTRYPOINT = "icarus" } }
end

return M
