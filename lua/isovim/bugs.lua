-- The bug queue: what an agent or the user files about isovim itself with iso bug <text>
-- (isovim.cli.bugs), each picked up by a worker of its own that enriches it and opens a GitHub
-- issue in isovim's repo. ~/.isovim/bugs/ holds the reports, which never leave this host:
--   queue/<id>.json   filed, not yet taken
--   <id>.json         taken: moved out of queue/ by whoever claimed it, then its worker's
--   <id>/             the images filed with it
-- A report: {id, text, reporter (<ws>/<agent>, or "user" from a shell), scope (the reporter's repo
-- key), cwd, time, sha (isovim's), host, images?, taken?: {at, worker}, issue?: {url, at}}.
--
-- Every ACP supervisor subscribes (M.watch): it watches queue/, and a second after it changes, or on
-- start for what was filed while none ran, claims each report there by moving it out (a rename,
-- which only one claimant wins) and runs iso __bug-take <id> on the tmux server, which spawns the
-- report's worker. So a report is taken once, whether or not the TUI is open.
local store = require("isovim.store")

local M = {}

M.dir = store.root .. "/bugs"
M.queue = M.dir .. "/queue"
M.repo = "isaacchacko/isovim"

function M.file(id)
  return M.dir .. "/" .. id .. ".json"
end

---@return table? report
function M.read(id)
  local ok, lines = pcall(vim.fn.readfile, M.file(id))
  local decoded, report = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(report) == "table" and report or nil
end

-- Written to a temp file and renamed over, so no reader (or the queue's watchers) sees half of it.
function M.write(path, report)
  local tmp = ("%s/.%s.%d.tmp"):format(M.dir, vim.fs.basename(path), vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode(report) }, tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

-- Changes a taken report's fields.
function M.update(id, fields)
  local report = M.read(id)
  if report then
    M.write(M.file(id), vim.tbl_extend("force", report, fields))
  end
  return report
end

-- Claims every report in the queue that nobody else has: each one this process moved out is
-- handed to iso __bug-take.
local function claim()
  for name, type in vim.fs.dir(M.queue) do
    local id = type == "file" and name:match("^([%w-]+)%.json$")
    if id and vim.uv.fs_rename(M.queue .. "/" .. name, M.file(id)) then
      local ok, err = require("isovim.panes").later({ "__bug-take", id }, M.dir .. "/take.log")
      if not ok then
        M.update(id, { error = "could not start iso __bug-take: " .. tostring(err) })
      end
    end
  end
end

-- Subscribes this process (an ACP supervisor) to the queue, once.
function M.watch()
  if M.watcher then
    return
  end
  vim.fn.mkdir(M.queue, "p")
  local timer = assert(vim.uv.new_timer())
  local run = vim.schedule_wrap(require("isovim.safe").wrap("bugs.claim", claim))
  M.watcher = assert(vim.uv.new_fs_event())
  M.watcher:start(M.queue, {}, function()
    timer:start(1000, 0, run)
  end)
  -- What was filed while no supervisor ran; spread out, as supervisors often start together.
  timer:start(math.random(2000, 6000), 0, run)
end

return M
