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
-- ICARUS_CHAT is the chat's id, which ica bug files its reports under, ICARUS_TASK the slug of the
-- task it's on (its agent tree is that task's org/), and ICARUS_SERVER this icarus's socket,
-- which ica comment and propose reach it by.
---@param chat? string
function M.command(cwd, chat)
  local record = chat and require("icarus.chats").get(chat)
  return { command = "node", args = { M.entry }, cwd = cwd,
    env = { CLAUDE_CODE_EXECUTABLE = claude(), CLAUDE_CODE_ENTRYPOINT = "icarus", ICARUS_CHAT = chat or false,
      ICARUS_TASK = record and record.task or false,
      ICARUS_SERVER = vim.v.servername ~= "" and vim.v.servername or false } }
end

-- The chat's agent in its own claude, in a new Ghostty window: claude --resume on its session, in its
-- folder, with the same ICARUS_* so ica works there too. Both write the one session, so a turn is
-- best sent from one place at a time.
---@param chat string
function M.native(chat)
  local record = require("icarus.chats").get(chat)
  if not (record and record.session) then
    return vim.notify("This chat has no session yet", vim.log.levels.WARN)
  end
  local env = M.command(record.cwd, chat).env
  local exports = {}
  for _, name in ipairs({ "ICARUS_CHAT", "ICARUS_TASK", "ICARUS_SERVER" }) do
    if env[name] then
      exports[#exports + 1] = ("%s=%s"):format(name, vim.fn.shellescape(env[name]))
    end
  end
  local line = ("cd %s && %s %s --resume %s"):format(vim.fn.shellescape(record.cwd), table.concat(exports, " "),
    vim.fn.shellescape(claude()), vim.fn.shellescape(record.session))
  vim.system({ "open", "-na", "Ghostty", "--args", "-e", vim.o.shell, "-lc", line }, {}, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Ghostty didn't open: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
      end)
    end
  end)
end

return M
