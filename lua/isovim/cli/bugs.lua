-- The bug queue on the command line (isovim.bugs keeps it). iso bug <text> files a report about
-- isovim itself, from any agent (bare or iso <role> bug) or a shell, and returns at once: nothing in
-- it may block or fail its caller. iso __bug-take <id> spawns the worker for a report a supervisor
-- claimed, and iso __bug-done <id> <url> is that worker recording the issue.
local store = require("isovim.store")
local bugs = require("isovim.bugs")
local events = require("isovim.events")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail

local M = {}

local function note(text)
  io.stderr:write("iso: " .. text .. "\n")
end

-- isovim's checkout: bin/iso's repo.
local function isovim_dir()
  return vim.fs.dirname(vim.fs.dirname(require("isovim.panes").bin))
end

-- Each --image <file>, copied into the report's folder; one that isn't an image is left out.
local function take_images(args, id)
  local copied = {}
  local path = c.option(args, "--image")
  while path do
    path = vim.fn.fnamemodify(path, ":p")
    local ext = path:match("%.(%w+)$")
    if not require("isovim.acp.images").mime(path) or vim.fn.filereadable(path) == 0 then
      note(path .. " is not a png, jpeg, gif or webp file; left out")
    else
      local dir = bugs.dir .. "/" .. id
      vim.fn.mkdir(dir, "p")
      local to = ("%s/%d.%s"):format(dir, #copied + 1, ext:lower())
      if vim.uv.fs_copyfile(path, to) then
        copied[#copied + 1] = to
      end
    end
    path = c.option(args, "--image")
  end
  return copied
end

local function file(args, id)
  local images = take_images(args, id)
  local text = table.concat(args, " ")
  if text == "-" then
    text = io.stdin:read("*a") or ""
  end
  text = vim.trim(text)
  if text == "" then
    fail("usage: iso bug [--image <file>]... <what happened...|->")
  end
  -- Nothing but flags it doesn't take isn't a report, and a report costs a worker.
  local words = vim.split(text, "%s+")
  if vim.iter(words):all(function(word)
    return word:match("^%-%-?%w") ~= nil
  end) then
    fail(("usage: iso bug [--image <file>]... <what happened...|->: %s isn't a flag it takes, and isn't a report"):format(words[1]))
  end
  local ws, agent = require("isovim.root").caller()
  local cwd = vim.uv.cwd()
  local sha = vim.system({ "git", "-C", isovim_dir(), "rev-parse", "--short", "HEAD" }, { text = true }):wait(2000)
  local report = {
    id = id,
    text = text,
    reporter = ws and (ws .. "/" .. agent) or "user",
    scope = ws and store.canon(ws) or require("isovim.repos").of(cwd),
    cwd = cwd,
    time = os.time(),
    sha = sha.code == 0 and vim.trim(sha.stdout) or "unknown",
    host = require("isovim.remote").self(),
    images = #images > 0 and images or nil,
  }
  vim.fn.mkdir(bugs.queue, "p")
  bugs.write(bugs.queue .. "/" .. id .. ".json", report)
  events.publish(events.topic("bug", id, "filed"), { id = id, reporter = report.reporter, scope = report.scope })
end

-- iso bug [--image <file>]... <text...|->: queues the report and prints its id.
function M.bug(args)
  local id = vim.fn.sha256(table.concat(args, " ") .. vim.uv.hrtime()):sub(1, 6)
  local ok, err = c.try(file, args, id)
  if not ok then
    if tostring(err):match("^usage:") then
      -- An image copied before the text was refused has no report to go with.
      vim.fn.delete(bugs.dir .. "/" .. id, "rf")
      fail(err)
    end
    note("could not file it: " .. tostring(err))
    return
  end
  out(id)
end

-- The worker's first message: prompts/bug.md with the report filled in.
local function brief(report)
  local template = table.concat(vim.fn.readfile(isovim_dir() .. "/prompts/bug.md"), "\n")
  local from_agent = report.reporter ~= "user"
  local images = ""
  if report.images then
    images = "\n\nImages filed with it, to look at but never upload (they may show private work): "
      .. table.concat(report.images, ", ")
  end
  local values = {
    id = report.id,
    repo = bugs.repo,
    file = bugs.file(report.id),
    reporter = from_agent and ("The agent " .. report.reporter) or "The user, from a shell,",
    transcript = from_agent and ("the reporter's last few turns where they're about isovim: `iso worker transcript "
      .. report.reporter .. "`") or "no transcript: the user filed it from a shell",
    text = (report.text:gsub("\n", "\n> ")),
    time = os.date("%Y-%m-%d %H:%M:%S", report.time),
    host = tostring(report.host),
    sha = tostring(report.sha),
    scope = report.scope or "no repo",
    socket = store.socket,
    images = images,
  }
  return (template:gsub("{{([%w_]+)}}", function(key)
    return values[key] or ("{{" .. key .. "}}")
  end))
end

local function spawn(report)
  local dir = isovim_dir()
  local agent, err = store.add_agent(bugs.repo, {
    kind = "claude",
    acp = true,
    name = "bug-" .. report.id,
    parent = require("isovim.cli.roles").holders("router", bugs.repo)[1],
    hidden = true,
    checkout = require("isovim.repos").of(dir) == bugs.repo and dir or nil,
    prompt = brief(report),
  })
  if not agent then
    fail(err or "could not add the agent")
  end
  c.ensure_running(c.resolve(bugs.repo), agent)
  return bugs.repo .. "/" .. agent.id
end

-- iso __bug-take <id>: spawns the worker for a claimed report, hidden, under isovim's router.
M["__bug-take"] = function(args)
  local id = args[1] or fail("usage: iso __bug-take <id>")
  local report = bugs.read(id) or fail("no report " .. id .. " is taken")
  if report.taken then
    fail(("%s is %s's already"):format(id, report.taken.worker))
  end
  local ok, result = c.try(spawn, report)
  if not ok then
    bugs.update(id, { error = "could not spawn its worker: " .. tostring(result) })
    fail(("%s: could not spawn its worker: %s"):format(id, result))
  end
  bugs.update(id, { taken = { at = os.time(), worker = result } })
  events.publish(events.topic("bug", id, "taken"), { id = id, worker = result })
  out(("%s: %s takes it"):format(id, result))
end

-- iso __bug-done <id> <url>: the report's issue, as its worker opened or commented on it.
M["__bug-done"] = function(args)
  local id, url = args[1], args[2]
  if not (id and url) then
    fail("usage: iso __bug-done <id> <url>")
  end
  if not bugs.update(id, { issue = { url = url, at = os.time() } }) then
    fail("no report " .. id .. " is taken")
  end
  events.publish(events.topic("bug", id, "issued"), { id = id, url = url })
  out(("%s: %s"):format(id, url))
end

return M
