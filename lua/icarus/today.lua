-- Today's note: a page for the day, on no task, ~/.icarus/today/<date>.md, made the first time it opens
-- (<leader>t anywhere, d on home). You write what the day needs, and <leader>p passes it to the
-- dispatcher, one agent on "(no task)" kept for this: it reads your tasks and writes a plan at the
-- note's end, a line per instruction,
--
--   - <task-slug>: <what to tell it>
--   - new "<Title>": <what to tell it>
--
-- which you edit in place. Nothing goes out until go: <leader>G in the note, or go said to the
-- dispatcher, which runs ica dispatch --plan. Each line then goes to its task's lead (started if the
-- task has none, opened if it isn't), a new task made for a new line, and the line is marked sent,
-- with the agent it went to:
--
--   - ✓ <task-slug>: <what to tell it> → icarus://agent/<id>
local tasks = require("icarus.tasks")
local chats = require("icarus.chats")

local M = {}

local PLAN = "## Plan"

function M.dir()
  return tasks.ROOT .. "/today"
end

-- The note for the day it is, or for date (YYYY-MM-DD).
function M.path(date)
  return ("%s/%s.md"):format(M.dir(), date or os.date("%Y-%m-%d"))
end

-- The day's note, made if it isn't yet.
function M.ensure()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(M.dir(), "p")
    vim.fn.writefile({ "# " .. os.date("%A %d %B"), "", "" }, path)
  end
  return path
end

-- The dispatcher: the agent on "(no task)" marked for it, the newest if there are several; made if
-- there's none, not started until it's used.
---@return icarus.ChatRecord
local function dispatcher()
  local found
  for _, record in ipairs(chats.on_task(tasks.SENTINEL)) do
    if record.dispatcher and not record.retired then
      found = record
    end
  end
  if not found then
    found = require("icarus.task_page").new_agent(tasks.sentinel())
    found.dispatcher = true
  end
  if found.title ~= "day planner" then
    found.title = "day planner"
    chats.save(found)
  end
  return found
end

M.planner = dispatcher

-- <leader>a in the note: the planner's chat in main, started if it isn't, to spar on the day.
function M.open_planner()
  require("icarus.task_page").show(tasks.sentinel(), { chat = dispatcher().id })
end

local function write(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
end

-- The note's lines: the buffer's when it's loaded, unsaved edits included, else the file's.
local function lines_of(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
  end
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}, nil
end

-- The plan's lines not sent yet: {row (1-based), slug?, title?, text}.
function M.plan(path)
  local lines = lines_of(path)
  local out, inside = {}, false
  for row, line in ipairs(lines) do
    if line:match("^##%s") then
      inside = vim.trim(line) == PLAN
    elseif inside and not line:match("^%s*%- ✓") then
      local title, text = line:match('^%s*%-%s+new%s+"(.-)"%s*:%s*(.+)$')
      if title then
        out[#out + 1] = { row = row, title = title, text = vim.trim(text) }
      else
        local slug, rest = line:match("^%s*%-%s+([%w%-_]+)%s*:%s*(.+)$")
        if slug then
          out[#out + 1] = { row = row, slug = slug, text = vim.trim(rest) }
        end
      end
    end
  end
  return out
end

-- The lead to tell something on task: an open one first, else the newest; one started if it has none.
---@return icarus.ChatRecord
local function lead_for(task)
  local orchestration = require("icarus.orchestration")
  local open, newest
  for _, record in ipairs(chats.on_task(task.slug)) do
    if not record.retired and orchestration.parent(record) == nil then
      newest = record
      if (_G.icarus_open_chats or {})[record.id] then
        open = record
      end
    end
  end
  return open or newest or require("icarus.task_page").new_agent(task)
end

-- What a lead is told: your instruction, from the note, as yours.
local function instruction(text, path)
  return table.concat({
    ("The user's instruction, from their note for today (%s), which they approved for you:"):format(path),
    "",
    text,
  }, "\n")
end

-- Sends text to task slug's lead, or to a new task titled title; returns the agent it went to.
---@return boolean ok, string agent id or why not
function M.send(slug, title, text, path)
  local task
  if title then
    task = tasks.create(title)
    local lines = vim.fn.readfile(task.file)
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    vim.fn.writefile(vim.list_extend(lines, vim.split(text, "\n", { plain = true })), task.file)
  else
    task = tasks.read(slug)
    if not task or task.sentinel then
      return false, ("no task %s (its slug, the folder name under %s/tasks)"):format(tostring(slug), tasks.ROOT)
    end
  end
  local record = lead_for(task)
  if not record.title then
    record.title = task.title .. " lead"
    chats.save(record)
  end
  local chat = require("icarus.acp.chat").get(record)
  chat.session:prompt(instruction(text, path or M.path()), nil, "◉ from today's note:\n" .. text)
  return true, record.id
end

-- Go: every plan line not sent yet goes out, and is marked sent in the note with where it went.
---@return string[] what happened, a line each
function M.go(path)
  path = path or M.path()
  local lines, buf = lines_of(path)
  local report = {}
  for _, line in ipairs(M.plan(path)) do
    local ok, result = M.send(line.slug, line.title, line.text, path)
    local target = line.title and ('new "%s"'):format(line.title) or line.slug
    if ok then
      lines[line.row] = ("- ✓ %s: %s → icarus://agent/%s"):format(target, line.text, result)
      report[#report + 1] = ("%s → icarus://agent/%s"):format(target, result)
    else
      report[#report + 1] = ("%s: not sent, %s"):format(target, result)
    end
  end
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    write(buf)
  else
    vim.fn.writefile(lines, path)
  end
  return report
end

-- The dispatcher's standing role, in its instructions (icarus.acp.session), so it knows the note before
-- it's passed one.
function M.role()
  return table.concat({
    ("You're the user's day planner and sparring partner. Their note for each day is %s/<YYYY-MM-DD>.md; today's is the one for the date it is."):format(M.dir()),
    "Spar with them on it: say where the day is overcommitted or vague, what their high and today tasks need that the note leaves out, what to drop or do first, and why. Disagree when you do; give your recommendation, not a list of options.",
    "Ask on the note itself: one `ica comment` per question, on the line it's about, with your recommendation. Their replies and edits come back to you; answer in the note.",
    "When they pass you the note, you also write the plan (its steps come with the pass). Nothing goes to other agents until they say go.",
  }, " ")
end

-- What the dispatcher is told when you pass it the note.
local function pass_text(path)
  return table.concat({
    ("The user passed you today's note, %s. You're their dispatcher and sparring partner: you push on the day, then turn the note into instructions for their tasks' agents. Nothing goes out until they say go."):format(path),
    "",
    ("1. `ica watch %s`, so their edits reach you."):format(path),
    ("2. Read their tasks: each folder in %s/tasks except no-task, its task.json (title, status, now, high, today) and task.md. Skip merged and cancelled ones unless the note names them."):format(tasks.ROOT),
    ("3. Write the plan at the end of the note, under a `%s` heading (make it if it's missing; keep every line marked ✓, which has gone out). One line for each thing to tell an agent:"):format(PLAN),
    "   `- <task-slug>: <what to tell it>` for an existing task, or",
    '   `- new "<Title>": <what to tell it>` for work no task covers.',
    "   Each instruction stands alone: the agent reading it has never seen the note. Propose only what the note asks for that no ✓ line already covers.",
    "4. Spar on it: comment on the note's lines where the day is overcommitted, vague or missing something their tasks need, each with your recommendation; then tell the user in one line that the plan is ready to edit and what you'd change first. Revise the plan as they decide.",
    "",
    ("When the user says go: `ica dispatch --plan %s`, which sends every line not marked ✓ and marks it; then tell them in a line what went where. Before go, send nothing."):format(path),
  }, "\n")
end

-- <leader>p: the note to the dispatcher, started if there's none, saved first so it reads what you wrote.
function M.pass(path)
  path = path or M.path()
  local _, buf = lines_of(path)
  if buf and vim.bo[buf].modified then
    write(buf)
  end
  local record = dispatcher()
  require("icarus.acp.chat").get(record).session:prompt(pass_text(path), nil, "◉ today's note passed")
  vim.notify("Today's note passed to the dispatcher: its plan lands at the note's end")
  return record
end

-- The note's own keys.
local function bind(buf, path)
  vim.keymap.set("n", "<leader>p", function()
    require("icarus.today").pass(path)
  end, { buffer = buf, desc = "Pass today's note to the dispatcher, for a plan" })
  vim.keymap.set("n", "<leader>G", function()
    local report = require("icarus.today").go(path)
    vim.notify(#report > 0 and ("Sent:\n" .. table.concat(report, "\n")) or "Nothing in the plan to send")
  end, { buffer = buf, desc = "Go: send the plan's unsent lines to their tasks" })
  vim.keymap.set("n", "<leader>a", function()
    require("icarus.today").open_planner()
  end, { buffer = buf, desc = "The day planner's chat, to spar on the day" })
end

-- <leader>t: the day's note in main, on "(no task)"; the outline's top rows are it and the day planner.
function M.open()
  local path = M.ensure()
  local page = require("icarus.task_page")
  local sentinel = tasks.sentinel()
  page.enter(sentinel, dispatcher())
  page.show(sentinel, { file = path })
  bind(vim.api.nvim_get_current_buf(), path)
end

-- ica dispatch <slug> <message...|-> | --new <title> <message...|-> | --plan [<note>]
---@return boolean ok, string result, boolean here
function M.remote(args)
  if args.plan then
    local report = M.go(args.note ~= "" and args.note or nil)
    return true, #report > 0 and table.concat(report, "\n") or "nothing in the plan to send", true
  end
  local text = vim.trim(args.text or "")
  if text == "" or not (args.slug or args.title) then
    return false, "usage: ica dispatch <task-slug> <message...|-> | --new <title> <message...|-> | --plan [<note>]", true
  end
  local ok, result = M.send(args.slug, args.title, text)
  return ok, ok and ("sent to icarus://agent/" .. result) or result, true
end

return M
