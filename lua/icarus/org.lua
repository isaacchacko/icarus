-- The agent sidebar (<leader>h): a task's agents as a tree, a fork under the agent it forked from and
-- an agent's subagents under it, each with its status, how long its turn has run, and what it's doing
-- now (its tool call while it works, else the last thing said in its thread). The agent you're in is
-- marked. <CR>, l or <Tab> opens the one under the cursor; q closes the sidebar. It follows the task
-- you're on and redraws every second while open.
--
-- An agent's name is its file's in ~/.icarus/tasks/<slug>/org/ (a file per agent, first line
-- "chat: <chat id>", which agents rename for their role), else its chat's title. icarus makes a file
-- for an agent that has none (agent-<n>).
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local M = {}

local REFRESH_MS = 1000

local WIDTH = 42
local NAME = "icarus://agents"
local NS = vim.api.nvim_create_namespace("icarus_agents")

local GLYPH = { working = "●", ["needs you"] = "◆", idle = "○" }
local STATUS_HL = { working = "IcarusAgentsWorking", ["needs you"] = "IcarusAgentsNeeds", idle = "IcarusAgentsIdle" }

vim.api.nvim_set_hl(0, "IcarusAgentsWorking", { link = "DiagnosticWarn", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsNeeds", { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsIdle", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsTree", { link = "NonText", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsName", { link = "Normal", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsCurrent", { link = "Title", default = true })
vim.api.nvim_set_hl(0, "IcarusAgentsHeader", { link = "Title", default = true })

-- In _G, so a hot reload keeps one timer.
_G.icarus_org = _G.icarus_org or {}
local state = _G.icarus_org

function M.dir(slug)
  return tasks.dir(slug) .. "/org"
end

-- The chat id a file names, read again only when the file changes.
local ids = {}
function M.chat_of(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local seen = ids[path]
  if not (seen and seen.mtime == stat.mtime.sec and seen.size == stat.size) then
    local first = vim.fn.readfile(path, "", 1)[1] or ""
    seen = { mtime = stat.mtime.sec, size = stat.size, id = first:match("^%s*chat:%s*(%S+)") }
    ids[path] = seen
  end
  return seen.id
end

-- Makes a file for each of the task's agents that has none.
function M.ensure(task)
  local dir = M.dir(task.slug)
  vim.fn.mkdir(dir, "p")
  local have = {}
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" then
      local id = M.chat_of(dir .. "/" .. name)
      if id then
        have[id] = true
      end
    end
  end
  for _, record in ipairs(chats.on_task(task.slug)) do
    if not have[record.id] then
      local n = record.cwd:match("/agents/(%d+)$")
      local name = n and ("agent-" .. n) or ("agent-" .. record.id)
      local path = dir .. "/" .. name
      local i = 1
      while vim.fn.filereadable(path) == 1 do
        i = i + 1
        path = ("%s/%s-%d"):format(dir, name, i)
      end
      vim.fn.writefile({ "chat: " .. record.id }, path)
    end
  end
end

-- The task the screen is on, else the current chat's.
local function current_task()
  local icarus = require("icarus")
  local view = icarus.view()
  local record = icarus.current() and chats.get(icarus.current())
  return tasks.read(view and view.task or record and record.task or tasks.SENTINEL)
end

-- Each agent's name from its file in org/, by chat id; the default agent-<n> names don't count.
local function names(slug)
  local dir, out = M.dir(slug), {}
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" then
      local id = M.chat_of(dir .. "/" .. name)
      local base = vim.fs.basename(name)
      if id and not base:match("^agent%-") then
        out[id] = base
      end
    end
  end
  return out
end

local function clip(text, width)
  text = vim.trim((text or ""):gsub("%*%*", ""):gsub("`", ""):gsub("⑂%s*", ""):gsub("%s+", " "))
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, width - 1)) .. "…"
end

-- The last thing said in the chat's thread, as "you: ..." if it was the user's.
local function last_said(open)
  local buf = open and open.thread
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local count = require("icarus.acp.compose").start(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, count - 40), count, false)
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i])
    if line ~= "" then
      local mine = line:match("^❯%s*(.*)$")
      return mine and ("you: " .. mine) or line:gsub("^[%*#>%-]+%s*", ""), mine ~= nil
    end
  end
end

-- The last thing said with an agent that isn't open, from its transcript, read again only when the
-- transcript changes.
local said_cache = {}
local function last_said_closed(record)
  if not record.session then
    return nil
  end
  local base = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
  local path = ("%s/projects/%s/%s.jsonl"):format(base, (record.cwd:gsub("[^%w]", "-")), record.session)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local seen = said_cache[record.id]
  if not (seen and seen.mtime == stat.mtime.sec and seen.size == stat.size) then
    local said = require("icarus.acp.thread").said(record) or {}
    local last
    for i = #said, 1, -1 do
      if said[i].who ~= "tools" then
        last = said[i]
        break
      end
    end
    local text = last and (last.who == "you" and require("icarus.acp.thread").label(last.text) or last.text)
    local line = text and vim.trim(text:match("[^\n]*%S[^\n]*$") or text)
    seen = { mtime = stat.mtime.sec, size = stat.size,
      text = line and ((last.who == "you" and "you: " or "") .. line:gsub("^[%*#>%-]+%s*", "")), mine = last and last.who == "you" }
    said_cache[record.id] = seen
  end
  return seen.text, seen.mine
end

-- The rows of the tree: {indent, glyph, name, status, note, detail, target, current}.
local function rows(task)
  local records = chats.on_task(task.slug)
  local by_id, children, roots = {}, {}, {}
  for _, record in ipairs(records) do
    by_id[record.id] = record
  end
  table.sort(records, function(a, b)
    return a.id < b.id
  end)
  for _, record in ipairs(records) do
    local of = require("icarus.orchestration").parent(record)
    local parent = of and by_id[of] and of
    if parent then
      children[parent] = children[parent] or {}
      table.insert(children[parent], record)
    else
      roots[#roots + 1] = record
    end
  end
  local named = names(task.slug)
  local current = require("icarus").current()
  local out = {}
  local function add(record, prefix, last, depth)
    local open = _G.icarus_open_chats and _G.icarus_open_chats[record.id]
    local now, note = require("icarus.graph").agent(record)
    local name = named[record.id] or (record.title or "new chat"):gsub("^⑂%s*", ""):gsub("^You are%s+", "")
    local detail, dim = nil, true
    local call = open and open.busy and open.last_tool
    if call and call.title then
      detail = "⚙ " .. call.title:gsub("\n.*", "")
    else
      local said, mine
      if open then
        said, mine = last_said(open)
      else
        said, mine = last_said_closed(record)
      end
      detail, dim = said, mine or now ~= "needs you"
    end
    local branch = depth == 0 and "" or (last and "└ " or "├ ")
    local rest = depth == 0 and "" or (last and "  " or "│ ")
    out[#out + 1] = { tree = prefix .. branch, cont = prefix .. rest, glyph = GLYPH[now] or "○", status = now,
      name = name, note = record.retired and "retired" or note ~= "" and note ~= "not open" and note or nil, detail = detail, dim = dim,
      target = { chat = record.id }, current = record.id == current }
    local kids = {}
    for _, kid in ipairs(children[record.id] or {}) do
      kids[#kids + 1] = { record = kid }
    end
    for id, child in pairs(open and open.subagents or {}) do
      kids[#kids + 1] = { child = child, id = id }
    end
    for i, kid in ipairs(kids) do
      local kid_last = i == #kids
      local kid_prefix = prefix .. rest
      if kid.record then
        add(kid.record, kid_prefix, kid_last, depth + 1)
      else
        local sub = require("icarus.subagents")
        local running = sub.running(kid.child)
        out[#out + 1] = { tree = kid_prefix .. (kid_last and "└ " or "├ "), cont = kid_prefix .. (kid_last and "  " or "│ "),
          glyph = running and "◌" or "·", status = running and "working" or "idle", name = sub.label(kid.child),
          note = running and "subagent" or kid.child.state, detail = kid.child.last and kid.child.last:gsub("\n.*", ""),
          dim = true, target = { subagent = kid.id } }
      end
    end
  end
  for i, record in ipairs(roots) do
    add(record, "", i == #roots, 0)
  end
  return out
end

local function buf()
  local b = vim.fn.bufnr("^" .. NAME .. "$")
  if b == -1 then
    b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, NAME)
    vim.bo[b].filetype = "icarus_agents"
    vim.bo[b].modifiable = false
  end
  return b
end

local function win()
  for _, each in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[each].icarus_agents then
      return each
    end
  end
end

-- What's on each line of the sidebar: the agent or subagent it opens.
local targets = {}

local function draw()
  local w = win()
  local task = current_task()
  if not (w and task) then
    return
  end
  local b = vim.api.nvim_win_get_buf(w)
  local width = vim.api.nvim_win_get_width(w)
  local list = rows(task)
  local counts = { working = 0, ["needs you"] = 0 }
  for _, row in ipairs(list) do
    if row.target.chat then
      counts[row.status] = (counts[row.status] or 0) + 1
    end
  end
  local lines, marks, map = {}, {}, {}
  local function mark(row, from, to, group)
    marks[#marks + 1] = { row, from, to, group }
  end
  lines[1] = " " .. clip(task.title, width - 2)
  mark(0, 0, -1, "IcarusAgentsHeader")
  local summary = {}
  if counts["needs you"] > 0 then
    summary[#summary + 1] = counts["needs you"] .. " need you"
  end
  if counts.working > 0 then
    summary[#summary + 1] = counts.working .. " working"
  end
  local agents = #vim.tbl_filter(function(row)
    return row.target.chat ~= nil
  end, list)
  lines[2] = (" %d agent%s%s"):format(agents, agents == 1 and "" or "s", #summary > 0 and (" · " .. table.concat(summary, " · ")) or "")
  mark(1, 0, -1, "IcarusAgentsIdle")
  lines[3] = ""
  if #list == 0 then
    lines[4] = "  no agents yet"
    mark(3, 0, -1, "IcarusAgentsIdle")
  end
  for _, row in ipairs(list) do
    local r = #lines
    local gutter = row.current and "▎" or " "
    local right = row.note and (" " .. row.note .. " ") or " "
    local left = gutter .. row.tree .. row.glyph .. " "
    local room = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
    local name = clip(row.name, math.max(4, room))
    local pad = math.max(1, width - vim.fn.strdisplaywidth(left .. name) - vim.fn.strdisplaywidth(right) + 1)
    local line = left .. name .. string.rep(" ", pad) .. vim.trim(right)
    lines[#lines + 1] = line
    map[r + 1] = row.target
    mark(r, #gutter + #row.tree, #gutter + #row.tree + #row.glyph, STATUS_HL[row.status] or "IcarusAgentsIdle")
    mark(r, 0, #gutter + #row.tree, row.current and "IcarusAgentsCurrent" or "IcarusAgentsTree")
    mark(r, #left, #left + #name, row.current and "IcarusAgentsCurrent" or "IcarusAgentsName")
    mark(r, #left + #name, -1, "IcarusAgentsIdle")
    if row.detail and row.detail ~= "" then
      local indent = " " .. row.cont .. "  "
      local text = clip(row.detail, width - vim.fn.strdisplaywidth(indent) - 1)
      lines[#lines + 1] = indent .. text
      map[r + 2] = row.target
      mark(r + 1, 0, #indent, "IcarusAgentsTree")
      mark(r + 1, #indent, -1, row.dim and "IcarusAgentsIdle" or STATUS_HL["needs you"])
    end
  end
  -- The cursor stays on the agent it was on.
  local cursor = vim.api.nvim_win_get_cursor(w)
  local was = targets[cursor[1]]
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  targets = map
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(b, NS, m[1], m[2], { end_col = m[3] == -1 and #lines[m[1] + 1] or m[3], hl_group = m[4] })
  end
  local row = cursor[1]
  for i = 1, #lines do
    local target = was and map[i]
    if target and target.chat == was.chat and target.subagent == was.subagent then
      row = i
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, w, { math.min(row, #lines), 0 })
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- <CR>: the agent or subagent on the line opens.
local function enter()
  local target = targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not target then
    return
  end
  if target.subagent then
    return require("icarus.subagents").open(target.subagent)
  end
  local record = chats.get(target.chat)
  local task = record and tasks.read(record.task or tasks.SENTINEL)
  if record and task then
    require("icarus.task_page").open(task, record)
  end
end

function M.open(task)
  task = task or current_task()
  if not task then
    return
  end
  M.ensure(task)
  -- The sidebar as it was before, a file tree, if a hot reload left one open.
  pcall(function()
    for _, old in ipairs(require("icarus.ui").snacks().picker.get({ source = "explorer", tab = false })) do
      if old.opts.icarus_org then
        old:close()
      end
    end
  end)
  local w = win()
  if not w then
    local width = math.min(WIDTH, math.floor(vim.o.columns * 0.3))
    w = vim.api.nvim_open_win(buf(), true, { split = "left", win = -1, width = width })
    vim.w[w].icarus_agents = true
    for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false,
      winfixwidth = true, cursorline = true, statuscolumn = "", foldcolumn = "0", list = false, spell = false }) do
      vim.wo[w][0][option] = value
    end
    local b = buf()
    for _, lhs in ipairs({ "<CR>", "l", "<Tab>" }) do
      vim.keymap.set("n", lhs, enter, { buffer = b, nowait = true, desc = "Open this agent" })
    end
    vim.keymap.set("n", "q", M.toggle, { buffer = b, nowait = true, desc = "Close the agent sidebar" })
    pcall(vim.api.nvim_win_set_cursor, w, { 4, 0 })
  else
    vim.api.nvim_set_current_win(w)
  end
  draw()
  stop()
  state.timer = assert(vim.uv.new_timer())
  state.timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
    if not win() then
      return stop()
    end
    pcall(draw)
  end))
end

-- Whether the sidebar is open.
function M.open_now()
  return win() ~= nil
end

-- <leader>h: opens the sidebar, or closes it.
function M.toggle()
  local w = win()
  if w then
    stop()
    return vim.api.nvim_win_close(w, true)
  end
  M.open()
end

return M
