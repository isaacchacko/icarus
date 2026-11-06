-- Daedalus: wakes on its own, finds where the agents lost something, and changes how they work. Each wake is a fresh agent on the task "daedalus", told to
-- follow ~/.icarus/daedalus/prompt.md, which says what loss is. It coaches by editing coaching.md
-- there, which every agent reads (icarus.acp.session), and keeps its bets beside it; what needs code
-- it files with ica bug.
--
-- It wakes once a day when agents have worked since, or when a bet's check date comes; <leader>D wakes
-- it now. A file named off in that folder stops the waking.
local tasks = require("icarus.tasks")

local M = {}

local ROOT = vim.fn.expand("~/.icarus/daedalus")
local EVERY, CHECK_MS = 24 * 3600, 10 * 60 * 1000

-- In _G, so a hot reload keeps the one timer; it calls whatever module is loaded by then.
_G.icarus_daedalus = _G.icarus_daedalus or {}
local state = _G.icarus_daedalus

local function last_wake()
  local stat = vim.uv.fs_stat(ROOT .. "/last")
  return stat and stat.mtime.sec or 0
end

-- Whether agents have worked since.
local function worked_since(since)
  local base = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude") .. "/projects"
  for name, kind in vim.fs.dir(base) do
    if kind == "directory" and name:find("-icarus-tasks-", 1, true) and not name:find("-tasks-daedalus-", 1, true) then
      local stat = vim.uv.fs_stat(base .. "/" .. name)
      if stat and stat.mtime.sec > since then
        return true
      end
    end
  end
  return false
end

local function bet_due()
  local file = ROOT .. "/bets.md"
  local today = os.date("%Y-%m-%d")
  for _, line in ipairs(vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}) do
    local date = line:match("^%- .-Check (%d%d%d%d%-%d%d%-%d%d)")
    if date and date <= today then
      return true
    end
  end
  return false
end

function M.due()
  local last = last_wake()
  if vim.fn.filereadable(ROOT .. "/off") == 1 or vim.fn.filereadable(ROOT .. "/prompt.md") == 0 then
    return false
  end
  return (os.time() - last >= EVERY and worked_since(last)) or (bet_due() and os.date("%Y-%m-%d", last) ~= os.date("%Y-%m-%d"))
end

-- A fresh agent, the last one's session stopped.
function M.wake()
  local last = last_wake()
  vim.fn.writefile({}, ROOT .. "/last")
  local task = tasks.read("daedalus") or tasks.create("daedalus")
  local chats = require("icarus.chats")
  local chat = require("icarus.acp.chat")
  for _, record in ipairs(chats.on_task(task.slug)) do
    local open = (_G.icarus_open_chats or {})[record.id]
    if open and not open.busy then
      chat.stop(record.id)
    end
  end
  local record = require("icarus.task_page").new_agent(task)
  record.title = "daedalus " .. os.date("%m-%d %H:%M")
  chats.save(record)
  local days = last > 0 and math.max(1, math.ceil((os.time() - last) / 86400)) or 7
  chat.get(record).session:prompt(("Find loss. Follow %s/prompt.md. Since: %s Days: %d"):format(ROOT,
    last > 0 and os.date("%Y-%m-%d %H:%M", last) or "the start", days), nil, "◉ daedalus wakes")
  return record
end

function M.tick()
  if M.due() then
    pcall(M.wake)
  end
end

function M.start()
  if not state.timer then
    state.timer = assert(vim.uv.new_timer())
    state.timer:start(CHECK_MS, CHECK_MS, vim.schedule_wrap(function()
      require("icarus.daedalus").tick()
    end))
  end
end

-- What every agent reads, for its system prompt; nothing while it's only the heading.
function M.coaching()
  local file = ROOT .. "/coaching.md"
  return vim.fn.filereadable(file) == 1 and table.concat(vim.fn.readfile(file), "\n") or ""
end

return M
