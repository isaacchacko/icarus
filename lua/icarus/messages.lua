-- Agents talking to each other, through ica (icarus.cli): ica agents lists the agents on the
-- caller's task, ica msg <id> <text> sends one a message, ica log <id> reads what one and the user
-- said lately, and ica questions lists what's open with the user across the task (comment threads
-- in its files, and an agent whose last word to the user asked something), to check before asking.
-- A message is a prompt in the recipient's queue (icarus.acp.session), so it goes when its turn
-- ends, batched with whatever else waits, and shows in its chat as one line, "◉ from <sender>:
-- ...". The recipient answers with ica msg too.
-- Both answer only in the icarus the caller runs in (its chat open there); another icarus passes.
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local M = {}

-- The caller's open chat, if it runs in this icarus.
local function caller(args)
  return args.chat and _G.icarus_open_chats and _G.icarus_open_chats[args.chat]
end

local function task_of(record)
  return tasks.read(record.task or tasks.SENTINEL)
end

---@return boolean ok, string result, boolean here
function M.agents(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local task = task_of(me.record)
  local lines = { ("agents on %s:"):format(task and task.title or "(no task)") }
  for _, record in ipairs(chats.on_task(me.record.task or tasks.SENTINEL)) do
    local open = _G.icarus_open_chats[record.id]
    lines[#lines + 1] = ("%s  %-9s %s%s%s"):format(record.id, open and chats.status(record.id) or "not open",
      record.title or "new chat", record.forked_from and (" (a fork of " .. record.forked_from .. ")") or "",
      record.id == me.record.id and "  ← you" or "")
    local peers = task and require("icarus.orchestration").style(task) == "democracy" and not record.retired
    local place = peers and require("icarus.democracy").describe(task.slug, record.id)
    if place and #place > 0 then
      lines[#lines + 1] = "    " .. table.concat(place, " · ")
    end
  end
  return true, table.concat(lines, "\n"), true
end

---@return boolean ok, string result, boolean here
function M.msg(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local record = chats.get(args.to)
  if not record then
    return false, ("no agent %s (ica agents lists them)"):format(args.to), true
  end
  if record.id == me.record.id then
    return false, "that's you", true
  end
  local refused = me.record.task and require("icarus.democracy").refuse_message(me.record.task, me.record.id, record.id)
  if refused then
    return false, refused, true
  end
  local from = me.record.title or me.record.id
  local task = task_of(me.record)
  local text = table.concat({
    ("Message from the agent %s (icarus://agent/%s), on %s:"):format(from, me.record.id, task and task.title or "no task"),
    "",
    args.text,
    "",
    ("If it needs an answer: `ica msg %s <reply>`."):format(me.record.id),
  }, "\n")
  -- Opened here if it isn't: its session loads, and the message waits for it.
  local chat = require("icarus.acp.chat").get(record)
  chat.session:prompt(text, nil, ("◉ from %s:\n%s"):format(from, vim.trim(args.text)))
  if me.record.task then
    pcall(require("icarus.democracy").messaged, me.record.task, me.record.id, record.id)
  end
  local waiting = #chat.session.queue
  return true, waiting > 0 and ("sent to %s; it gets it when its turn ends (%d waiting)"):format(record.title or record.id, waiting)
    or ("sent to %s"):format(record.title or record.id), true
end

-- ica name <name>: the caller's title, what the user sees it as in the sidebars, the org and links.
---@return boolean ok, string result, boolean here
-- ica status: the caller's task's status and the line on where it stands, read or set.
---@return boolean ok, string result, boolean here
function M.status(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local task = me.record.task and tasks.read(me.record.task)
  if not task or task.sentinel then
    return false, "you're not on a task", true
  end
  if args.status and not vim.tbl_contains(tasks.STATUSES, args.status) then
    return false, ("no status %s: it's one of %s"):format(args.status, table.concat(tasks.STATUSES, ", ")), true
  end
  if args.status and task.pinned then
    return false, task.title .. " is pinned, so it has no status: use ica status --now <where it stands>", true
  end
  local changes = {}
  changes.status = args.status
  changes.now = args.now and vim.trim((args.now:gsub("%s+", " "))) or nil
  if next(changes) then
    tasks.set(task, changes)
    me.status_at = me.turns or 0
    task = tasks.read(task.slug)
  end
  return true, ("%s: %s%s"):format(task.title, task.status or "pinned", task.attrs.now and (" — " .. task.attrs.now) or ""), true
end

-- ica link [--remove] <url>...: links on the caller's task (a PR's shows with its tickets, icarus.prs).
function M.link(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local task = me.record.task and tasks.read(me.record.task)
  if not task or task.sentinel then
    return false, "you're not on a task", true
  end
  local links = vim.deepcopy(task.links)
  for _, url in ipairs(args.urls or {}) do
    if args.remove then
      links = vim.tbl_filter(function(each)
        return each ~= url
      end, links)
    elseif not vim.tbl_contains(links, url) then
      links[#links + 1] = url
    end
  end
  tasks.set(task, { links = links })
  if _G.icarus_prs then
    _G.icarus_prs[task.slug] = nil
  end
  return true, #links > 0 and table.concat(links, "\n") or "no links", true
end

function M.name(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local title = vim.trim((args.name or ""):gsub("%s+", " "))
  if title == "" then
    return false, "usage: ica name <name>", true
  end
  title = vim.fn.strchars(title) > 40 and vim.fn.strcharpart(title, 0, 39) .. "…" or title
  me.record.title = (me.record.forked_from and "⑂ " or "") .. title
  me.named_at = me.turns or 0
  chats.save(me.record)
  -- Its file in the task's org, where the sidebar takes its name from, renamed to match.
  local org = require("icarus.org")
  local dir = me.record.task and org.dir(me.record.task)
  for path, kind in vim.fs.dir(dir or "", { depth = 20 }) do
    local full = dir .. "/" .. path
    if kind == "file" and org.chat_of(full) == me.record.id then
      local file = title:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
      local to = vim.fs.dirname(full) .. "/" .. (file ~= "" and file or "agent")
      if to ~= full and vim.fn.filereadable(to) == 0 then
        vim.uv.fs_rename(full, to)
      end
      break
    end
  end
  pcall(vim.cmd.redrawstatus)
  return true, "you're now " .. me.record.title, true
end

-- ica log <id> [n]: the last n things said between that agent and the user, from its transcript.
---@return boolean ok, string result, boolean here
function M.log(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local record = chats.get(args.agent)
  if not record then
    return false, ("no agent %s (ica agents lists them)"):format(args.agent), true
  end
  local said = vim.tbl_filter(function(each)
    return each.who ~= "tools"
  end, require("icarus.acp.thread").said(record) or {})
  local n = tonumber(args.n) or 10
  local lines = { ("%s (icarus://agent/%s), its last %d:"):format(record.title or record.id, record.id, math.min(n, #said)) }
  for i = math.max(1, #said - n + 1), #said do
    local each = said[i]
    local text = each.who == "you" and require("icarus.acp.thread").label(each.text) or each.text
    lines[#lines + 1] = ""
    lines[#lines + 1] = (each.who == "you" and "to it: " or "it said: ") .. text
  end
  if #said == 0 then
    lines[#lines + 1] = "(nothing said yet)"
  end
  return true, table.concat(lines, "\n"), true
end

-- ica questions: what's open with the user across the caller's task.
---@return boolean ok, string result, boolean here
function M.questions(args)
  local me = caller(args)
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local slug = me.record.task or tasks.SENTINEL
  local watch = require("icarus.watch")
  local lines = {}
  for _, open in ipairs(watch.threads_under(tasks.dir(slug) .. "/")) do
    local thread = watch.thread(open.item)
    local first, last = thread[1], thread[#thread]
    local by = first.who == "you" and "the user" or watch.agent_name(first.chat or open.item.chat)
    lines[#lines + 1] = ("%s:%s  comment %s, started by %s, %d in thread, last %s: %s"):format(
      open.path:sub(#tasks.dir(slug) + 2), open.line or "?", open.item.id, by, #thread,
      last.who == "you" and "the user" or watch.agent_name(last.chat or open.item.chat),
      (last.text:gsub("\n", " ")):sub(1, 140))
  end
  for _, record in ipairs(chats.on_task(slug)) do
    local said = require("icarus.acp.thread").said(record) or {}
    local last
    for i = #said, 1, -1 do
      if said[i].who ~= "tools" then
        last = said[i]
        break
      end
    end
    if last and last.who == "agent" and vim.trim(last.text):match("%?%s*$") then
      lines[#lines + 1] = ("%s (icarus://agent/%s) asked the user in its chat: %s"):format(record.title or record.id, record.id,
        (vim.trim(last.text):gsub("\n", " ")):sub(-200))
    end
  end
  return true, #lines > 0 and table.concat(lines, "\n") or "nothing open with the user on this task", true
end

return M
