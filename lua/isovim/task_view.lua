-- A task's view (isovim.board_tasks), drawn in the board's own buffer: no buffer or tab of its own ("one
-- buffer for the board and everything is in that buffer"). <CR> on its card, its sidebar row, its chip
-- or <leader><leader> shows it there, and <Esc> goes back to the board, on its card, scrolled and filtered as
-- it was. view.task_open says which task the board's buffer shows. Its title and markdown description
-- are the body, its properties a compact block under them, then its threads where Linear has sub-issues,
-- its relations, its PRs and tickets, and its log. Everything in it is the user's to change, by keys;
-- agents read it with iso <role> task show. The keys here and on the board's cards are one set, M.actions.
local surfaces = require("isovim.surfaces")
local tasks = require("isovim.board_tasks")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_task_view")

local function define_label_highlights()
  for i, color in ipairs(tasks.PALETTE) do
    vim.api.nvim_set_hl(0, "IsovimLabel" .. i, { default = true, fg = color[2] })
  end
end

function M.label_hl(labels, name)
  define_label_highlights()
  return "IsovimLabel" .. (labels[name] or #tasks.PALETTE)
end

-- Whatever shows this repo's tasks drawn again, after a change by key.
local function changed(repo)
  surfaces.scan(repo)
  surfaces.recheck()
  require("isovim.surface_view").threads_changed(repo)
end

local function select(items, prompt, format, then_do)
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(item)
    if item ~= nil then
      then_do(item)
    end
  end)
end

-- A date as typed: 2026-11-30, today, tomorrow or +3 (days from now); "" clears it. Nil if it's none.
local function parse_due(text)
  text = vim.trim(text):lower()
  local day = 86400
  if text == "today" then
    return os.date("%Y-%m-%d")
  elseif text == "tomorrow" then
    return os.date("%Y-%m-%d", os.time() + day)
  end
  local plus = text:match("^%+(%d+)$")
  if plus then
    return os.date("%Y-%m-%d", os.time() + tonumber(plus) * day)
  end
  local y, m, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
  if y and tonumber(m) >= 1 and tonumber(m) <= 12 and tonumber(d) >= 1 and tonumber(d) <= 31 then
    return ("%s-%02d-%02d"):format(y, tonumber(m), tonumber(d))
  end
end

-- What the user can do to a task, each by a key here and on the board: fn(repo, task).
M.actions = {}

function M.actions.status(repo, task)
  local names = require("isovim.thread_board").COLUMNS
  select(names, ("%s's status:"):format(task.id), function(column)
    return column.name
  end, function(column)
    tasks.move(repo, task.id, column.key)
    changed(repo)
  end)
end

function M.actions.priority(repo, task)
  select({ 0, 1, 2, 3, 4 }, ("%s's priority:"):format(task.id), function(value)
    return tasks.PRIORITIES[value]
  end, function(value)
    tasks.set_priority(repo, task.id, value)
    changed(repo)
  end)
end

function M.actions.assignee(repo, task)
  local choices = { { label = "No one" }, { label = "You", value = "user" } }
  for _, agent in ipairs(require("isovim.store").agents(repo)) do
    if not agent.of and require("isovim.panes").reports(agent.kind) then
      choices[#choices + 1] = { label = ("%s (%s)"):format(agent.name or agent.id, agent.id), value = repo .. "/" .. agent.id }
    end
  end
  select(choices, ("Assign %s to (a label, it tells nobody):"):format(task.id), function(choice)
    return choice.label
  end, function(choice)
    tasks.set(repo, task.id, "assignee", choice.value)
    changed(repo)
  end)
end

-- A label ticked or not, or a new one: its name, then its color.
function M.actions.labels(repo, task)
  local _, labels = tasks.read(repo)
  local names = vim.tbl_keys(labels)
  table.sort(names)
  local choices = vim.tbl_map(function(name)
    return { name = name, on = vim.tbl_contains(task.labels, name) }
  end, names)
  choices[#choices + 1] = { new = true }
  select(choices, ("%s's labels:"):format(task.id), function(choice)
    return choice.new and "New label…" or ((choice.on and "✓ " or "  ") .. choice.name)
  end, function(choice)
    if not choice.new then
      tasks.tag(repo, task.id, choice.name, not choice.on)
      return changed(repo)
    end
    vim.ui.input({ prompt = "New label: " }, function(name)
      name = name and vim.trim(name)
      if not name or name == "" then
        return
      end
      select(tasks.PALETTE, ("%s's color:"):format(name), function(color)
        return color[1]
      end, function(color)
        for i, each in ipairs(tasks.PALETTE) do
          if each == color then
            tasks.define_label(repo, name, i)
          end
        end
        tasks.tag(repo, task.id, name, true)
        changed(repo)
      end)
    end)
  end)
end

function M.actions.due(repo, task)
  vim.ui.input({ prompt = "Due (2026-11-30, today, tomorrow, +3; empty clears): ", default = task.due or "" }, function(text)
    if text == nil then
      return
    elseif vim.trim(text) == "" then
      tasks.set(repo, task.id, "due", nil)
      return changed(repo)
    end
    local due = parse_due(text)
    if not due then
      return vim.notify("isovim: " .. text .. " isn't a date", vim.log.levels.WARN)
    end
    tasks.set(repo, task.id, "due", due)
    changed(repo)
  end)
end

function M.actions.estimate(repo, task)
  local choices = { { label = "None" } }
  for _, value in ipairs(tasks.ESTIMATES) do
    choices[#choices + 1] = { label = tostring(value), value = value }
  end
  select(choices, ("%s's estimate:"):format(task.id), function(choice)
    return choice.label
  end, function(choice)
    tasks.set(repo, task.id, "estimate", choice.value)
    changed(repo)
  end)
end

function M.actions.rename(repo, task)
  vim.ui.input({ prompt = "Rename task: ", default = task.title }, function(title)
    if title then
      tasks.set(repo, task.id, "title", title)
      changed(repo)
    end
  end)
end

function M.actions.new_thread(repo, task)
  require("isovim.acp.chat").new_thread(repo, task.id)
end

-- A relation to another task, added or, picked from those it has, taken off.
function M.actions.relation(repo, task)
  local others = vim.tbl_filter(function(other)
    return other.id ~= task.id
  end, vim.tbl_values((tasks.read(repo))))
  table.sort(others, function(a, b)
    return (tonumber(a.id:sub(2)) or 0) > (tonumber(b.id:sub(2)) or 0)
  end)
  local choices = {}
  if #others > 0 then
    choices = { { label = "Blocks…", type = "blocks" }, { label = "Blocked by…", type = "blocked_by" }, { label = "Related to…", type = "related" } }
  end
  for _, other in ipairs(task.blocks) do
    choices[#choices + 1] = { label = "Remove: blocks " .. other, off = { task.id, other, "blocks" } }
  end
  for _, other in ipairs(task.blocked_by) do
    choices[#choices + 1] = { label = "Remove: blocked by " .. other, off = { other, task.id, "blocks" } }
  end
  for _, other in ipairs(task.related) do
    choices[#choices + 1] = { label = "Remove: related to " .. other, off = { task.id, other, "related" } }
  end
  if #choices == 0 then
    return vim.notify("isovim: there's no other task to relate it to", vim.log.levels.INFO)
  end
  select(choices, ("%s's relations:"):format(task.id), function(choice)
    return choice.label
  end, function(choice)
    if choice.off then
      tasks.relate(repo, choice.off[1], choice.off[2], choice.off[3], false)
      -- Related is either way round.
      if choice.off[3] == "related" then
        tasks.relate(repo, choice.off[2], choice.off[1], "related", false)
      end
      return changed(repo)
    end
    select(others, choice.label, function(other)
      return ("%s  %s"):format(other.id, other.title)
    end, function(other)
      if choice.type == "blocked_by" then
        tasks.relate(repo, other.id, task.id, "blocks", true)
      else
        tasks.relate(repo, task.id, other.id, choice.type, true)
      end
      changed(repo)
    end)
  end)
end

-- A PR or ticket: linked, or, picked from those it has, unlinked.
function M.actions.link(repo, task)
  local choices = { { label = "Link a PR or Linear ticket…", add = true } }
  for _, link in ipairs(task.links) do
    choices[#choices + 1] = { label = "Unlink " .. link.ref, ref = link.ref }
  end
  select(choices, ("%s's PRs and tickets:"):format(task.id), function(choice)
    return choice.label
  end, function(choice)
    if choice.ref then
      local link = vim.iter(task.links):find(function(each)
        return each.ref == choice.ref
      end)
      tasks.unlink(repo, task.id, link.url or link.ref, "user")
      return changed(repo)
    end
    vim.ui.input({ prompt = "PR (URL, owner/repo#n, #n) or ticket (URL, ABC-123): " }, function(ref)
      if not ref or vim.trim(ref) == "" then
        return
      end
      local stored, err = tasks.link(repo, task.id, ref, nil, "user")
      if not stored then
        return vim.notify("isovim: " .. tostring(err), vim.log.levels.WARN)
      end
      changed(repo)
    end)
  end)
end

-- A: one of the repo's open threads not on this task, picked, put on it, moving it if it's on another.
function M.actions.attach_thread(repo, task)
  local choices = vim.tbl_filter(function(info)
    return info.task ~= task.id
  end, require("isovim.threads").list(repo))
  if #choices == 0 then
    return vim.notify("isovim: every open thread is on this task already", vim.log.levels.INFO)
  end
  select(choices, ("Attach to %s:"):format(task.id), function(info)
    return ("%s  %s%s"):format(info.id, info.title, info.task and ("  (on %s)"):format(info.task) or "")
  end, function(info)
    require("isovim.threads").set_task(repo, info.id, task.id, "user")
    changed(repo)
  end)
end

-- A on a thread: a task for it, picked, moving it from any it's on; first, on a thread with one, No task,
-- taking it off, and on a thread with none, a new task of its title.
function M.actions.thread_task(repo, entry, on_done)
  local choices = vim.tbl_filter(function(task)
    return task.id ~= entry.task
  end, vim.tbl_values((tasks.read(repo))))
  table.sort(choices, function(a, b)
    return (tonumber(a.id:sub(2)) or 0) > (tonumber(b.id:sub(2)) or 0)
  end)
  table.insert(choices, 1, entry.task and { none = true } or { new = true })
  select(choices, ("Attach %s to:"):format(entry.name), function(task)
    if task.none then
      return "No task"
    end
    return task.new and ("New task: " .. entry.title) or ("%s  %s"):format(task.id, task.title)
  end, function(task)
    local id = task.none and "none" or task.new and tasks.new(repo, entry.title) or task.id
    if id then
      require("isovim.threads").set_task(repo, entry.name, id, "user")
      if on_done then
        on_done(id, task.new)
      end
      changed(repo)
    end
  end)
end

-- Keys both here and on the board's cards: {lhs, the action, what it does}.
M.KEYS = {
  { "s", "status", "its status" },
  { "p", "priority", "its priority" },
  { "a", "assignee", "its assignee (a label: it tells nobody)" },
  { "t", "labels", "its labels, or a new one with its color" },
  { "D", "due", "its due date" },
  { "e", "estimate", "its estimate" },
  { "r", "rename", "rename it" },
  { "n", "new_thread", "a new thread on it: its title, then your first post" },
  { "R", "relation", "add or remove a relation to another task" },
  { "K", "link", "link or unlink a PR or Linear ticket" },
}

-- The view's keys, for the help (`?` here and in the sidebar).
function M.help_keys()
  local list = vim.tbl_map(function(key)
    return { key[1], key[3] }
  end, M.KEYS)
  vim.list_extend(list, {
    { "A", "on a thread's row, move it to another task or take it off (No task, first); elsewhere, attach one of the repo's open threads, picked, moving it if it's on another task" },
    { "<Esc>", "back to the board, on this task's card" },
    { "i", "edit the description in place (<Esc> in normal mode saves and leaves the edit, :w saves)" },
    { "<CR>", "open the thread, task, PR or ticket on this line (a PR in the browser); on the description, edit it" },
    { "o", "a PR's own view here" },
    { "<Tab>", "open the link under the cursor" },
    { "[ / ]", "the previous / next project's board" },
    { "<C-d> <C-u>", "scroll, as anywhere" },
    { "?", "these keys" },
  })
  return list
end

local function ago(at)
  local seconds = os.time() - (at or 0)
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m ago"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h ago"
  end
  return os.date("%Y-%m-%d", at)
end

-- The lines of a task's view for width: {lines, marks, rows (what a line is, for <CR>), addresses,
-- still written out for isovim.links to draw as chips, and chips, those a description has as boxes drew them}.
local function layout(repo, id, width)
  local all, labels = tasks.read(repo)
  local task = all[id]
  if not task then
    return nil
  end
  local board = require("isovim.thread_board")
  local lines, marks, rows, addresses, chips = {}, {}, {}, {}, {}
  local function add(chunks, item)
    local text = ""
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        marks[#marks + 1] = { #lines, #text, #text + #chunk[1], chunk[2] }
      end
      text = text .. chunk[1]
    end
    lines[#lines + 1] = text
    rows[#lines] = item
  end
  local function address(addr)
    addresses[#addresses + 1] = addr
    return addr
  end
  local function heading(name, tail)
    add({})
    add({ { " " .. name, "Title" }, tail and { "  " .. tail, "Comment" } or nil })
  end
  add({ { " " .. task.title, "Title" } }, { title = true })
  add({})
  if vim.trim(task.description or "") == "" then
    add({ { " No description: i writes one.", "Comment" } }, { description = true })
  else
    -- Markdown as isovim draws it, in the board's own buffer, a space in from the edge.
    for _, seg in ipairs(require("isovim.boxes").markdown(task.description, math.max(10, width - 2))) do
      lines[#lines + 1] = " " .. seg.text
      rows[#lines] = { description = true }
      for _, mark in ipairs(seg.marks) do
        if mark[4] then
          chips[#chips + 1] = { #lines - 1, mark[1] + 1, mark[2] + 1, mark[4] }
        elseif mark[3] then
          marks[#marks + 1] = { #lines - 1, mark[1] + 1, mark[2] + 1, mark[3] }
        end
      end
    end
  end
  add({})
  -- Properties, compact. Names dim, in two columns of cells.
  local column = vim.iter(board.COLUMNS):find(function(each)
    return each.key == task.column
  end) or board.COLUMNS[2]
  local function property(name, chunks)
    local out = { { (" %-9s"):format(name), "Comment" } }
    return vim.list_extend(out, chunks)
  end
  local function cells(chunks)
    local n = 0
    for _, chunk in ipairs(chunks) do
      n = n + vim.fn.strdisplaywidth(chunk[1])
    end
    return n
  end
  local function pair(left, right)
    -- Narrow, one to a line.
    if width < 70 then
      add(left)
      return add(right)
    end
    local out = vim.deepcopy(left)
    out[#out + 1] = { (" "):rep(math.max(1, 34 - cells(left))) }
    add(vim.list_extend(out, right))
  end
  local priority = board.BADGES[task.priority or 0]
  local today = os.date("%Y-%m-%d")
  local overdue = task.due and task.due < today and task.column ~= "done"
  local label_chunks = {}
  for i, name in ipairs(task.labels) do
    if i > 1 then
      label_chunks[#label_chunks + 1] = { "  " }
    end
    label_chunks[#label_chunks + 1] = { "● ", M.label_hl(labels, name) }
    label_chunks[#label_chunks + 1] = { name }
  end
  pair(property("Status", { { column.glyph .. " ", column.hl }, { column.name } }),
    property("Priority", priority and { { priority[1] .. " ", priority[2] }, { priority[3] } } or { { "none", "Comment" } }))
  pair(property("Assignee", task.assignee and { { tasks.assignee_name(task.assignee) } } or { { "no one", "Comment" } }),
    property("Labels", #label_chunks > 0 and label_chunks or { { "none", "Comment" } }))
  pair(property("Due", task.due and { { task.due, overdue and "DiagnosticError" or nil } } or { { "none", "Comment" } }),
    property("Estimate", task.estimate and { { tostring(task.estimate) } } or { { "none", "Comment" } }))
  pair(property("Created", { { os.date("%Y-%m-%d %H:%M", task.at), "Comment" } }), property("Updated", { { ago(task.last_at), "Comment" } }))
  pair(property("Id", { { task.id, "Comment" } }), property("Link", { { ("iso:task/%s#%s"):format(repo, task.id):gsub("^iso:", ""), "Comment" } }))

  local own = vim.tbl_filter(function(entry)
    return entry.task == id
  end, vim.tbl_values(surfaces.thread_rows(repo)))
  table.sort(own, function(a, b)
    if (a.resolved or false) ~= (b.resolved or false) then
      return not a.resolved
    end
    return (tonumber(a.name:sub(2)) or 0) < (tonumber(b.name:sub(2)) or 0)
  end)
  local resolved = #vim.tbl_filter(function(entry)
    return entry.resolved
  end, own)
  heading("Threads", #own > 0 and ("%d/%d done"):format(resolved, #own) or nil)
  if #own == 0 then
    add({ { " None yet: n starts one.", "Comment" } })
  end
  for _, entry in ipairs(own) do
    local chunks = { { "  " } }
    for _, seg in ipairs(board.thread_marks(entry)) do
      chunks[#chunks + 1] = { seg.text, seg.marks[1] and seg.marks[1][3] }
      chunks[#chunks + 1] = { " " }
    end
    chunks[#chunks + 1] = { address(("iso:thread/%s#%s"):format(repo, entry.name)) }
    add(chunks, { thread = entry })
  end
  if #task.blocks + #task.blocked_by + #task.related > 0 then
    heading("Relations")
    local function relation(name, list)
      for _, other in ipairs(list) do
        add({ { ("  %-10s  "):format(name), "Comment" }, { address(("iso:task/%s#%s"):format(repo, other)) } }, { task = other })
      end
    end
    relation("blocks", task.blocks)
    relation("blocked by", task.blocked_by)
    relation("related to", task.related)
  end
  local prs = vim.tbl_filter(function(link)
    return link.type == "pr"
  end, task.links)
  local tickets = vim.tbl_filter(function(link)
    return link.type == "linear"
  end, task.links)
  if #prs > 0 then
    heading("PRs")
    for _, link in ipairs(prs) do
      add({ { "  " }, { address("iso:pr/" .. link.ref) } }, { pr = "iso:pr/" .. link.ref })
    end
  end
  if #tickets > 0 then
    heading("Linear")
    for _, link in ipairs(tickets) do
      add({ { "  \u{f0ac} ", "Special" }, { link.ref, "IsovimLink" }, { link.title and ("  " .. link.title) or "" } }, { ticket = link })
    end
  end
  heading("Activity")
  for i = #task.activity, 1, -1 do
    local each = task.activity[i]
    add({ { "  " .. os.date("%m-%d %H:%M", each.at) .. "  ", "Comment" },
      { (each.by == "user" and "you" or tasks.assignee_name(each.by) or each.by) .. " ", "Comment" }, { each.what, "Comment" } })
  end
  return { lines = lines, marks = marks, rows = rows, addresses = addresses, chips = chips, task = task }
end

-- The view's text, for a preview.
function M.lines(repo, id)
  local laid = layout(repo, id, 80)
  return laid and laid.lines or { "gone" }
end

local function drawn_key(laid, width)
  return vim.json.encode({ laid.lines, laid.marks, vim.tbl_map(require("isovim.links").chip, laid.addresses), width })
end

local function view_width(view)
  local win = vim.fn.bufwinid(view.buf)
  return win ~= -1 and vim.api.nvim_win_get_width(win) or view.width or 100
end

-- The window showing a task: its lines wrap and it has line numbers, unlike the board's (isovim.thread_board
-- dress puts those back), and the winbar says how to go back.
local function dress(view)
  local win = vim.fn.bufwinid(view.buf)
  if win ~= -1 then
    local wo = vim.wo[win][0]
    wo.wrap, wo.linebreak, wo.cursorline = true, true, true
    wo.number, wo.relativenumber = true, true
    wo.winbar = (" <Esc> back to the board · %s · i edit · ? keys"):format(view.task_open)
  end
end

M.dress = dress

-- Draws the task in the board's buffer, the cursor staying on its line. Not while the description's edited.
function M.draw(view)
  if view.editing then
    return
  end
  local width = view_width(view)
  local laid = layout(view.repo, view.task_open, width)
  -- It went (deleted): only the board's left.
  if not laid then
    return M.back(view)
  end
  local links = require("isovim.links")
  view.line_items = laid.rows
  view.task_drawn = drawn_key(laid, width)
  view.width = width
  require("isovim.surface_view").set_lines(view.buf, laid.lines, laid.marks)
  links.substitute(view.buf)
  for _, chip in ipairs(laid.chips) do
    links.register(view.buf, chip[1], chip[2], chip[3], chip[4], {})
  end
  dress(view)
end

-- Its threads or traits may have changed: drawn again if it reads differently.
function M.refresh(view)
  if view.editing then
    return
  end
  local width = view_width(view)
  local laid = layout(view.repo, view.task_open, width)
  if not laid or drawn_key(laid, width) ~= view.task_drawn then
    M.draw(view)
  end
end

-- Shows a task in the board's buffer. Coming from the board itself, how that's scrolled is kept for <Esc>.
function M.show(view, id)
  if view.editing then
    M.leave_edit(view)
  end
  local win = vim.fn.bufwinid(view.buf)
  if not view.task_open and win ~= -1 then
    view.board_saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  view.task_open = id
  require("isovim.thread_board").bind(view)
  M.draw(view)
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
end

-- <Esc>: back to the board, on this task's card, scrolled and filtered as it was.
function M.back(view)
  if view.editing then
    M.leave_edit(view)
  end
  local board = require("isovim.thread_board")
  local id = view.task_open
  view.task_open, view.line_items = nil, nil
  view.board_focus = id or view.board_focus
  view.board_columns = nil
  require("isovim.links").substitute(view.buf)
  board.bind(view)
  local win = vim.fn.bufwinid(view.buf)
  if win ~= -1 then
    board.dress(win)
  end
  board.draw(view)
  if win ~= -1 and view.board_saved then
    -- The scroll as it was, then the cursor on its card, which only scrolls if it has to.
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view.board_saved)
    end)
    board.draw(view)
  end
  view.board_saved = nil
end

-- Saves what's being edited, and with leave goes back to the drawn view.
local function save_description(view, leave)
  local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
  local task = tasks.read(view.repo)[view.task_open]
  if task and vim.trim(text) ~= vim.trim(task.description or "") then
    tasks.set(view.repo, view.task_open, "description", vim.trim(text))
  end
  vim.bo[view.buf].modified = false
  if not leave then
    return
  end
  view.editing = nil
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  pcall(vim.api.nvim_del_augroup_by_name, "isovim_task_edit_" .. view.buf)
  pcall(vim.treesitter.stop, view.buf)
  vim.bo[view.buf].buftype = "nofile"
  require("isovim.thread_board").bind(view)
  vim.cmd.stopinsert()
  changed(view.repo)
  M.draw(view)
end

function M.leave_edit(view)
  save_description(view, true)
end

local function bind_edit_keys(view)
  view.mode_keys = { "<Esc>" }
  vim.keymap.set("n", "<Esc>", function()
    require("isovim.safe").wrap("saving a task's description", save_description)(view, true)
  end, { buffer = view.buf, nowait = true, desc = "isovim: save the description and leave the edit" })
end

-- i: its description, editable in place, in the same buffer as markdown. Keys are vim's till it's saved.
local function edit_description(view)
  local task = tasks.read(view.repo)[view.task_open]
  if not task or view.editing then
    return
  end
  require("isovim.thread_board").clear_keys(view)
  view.editing = true
  vim.bo[view.buf].modifiable = true
  vim.bo[view.buf].buftype = "acwrite"
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  require("isovim.links").forget(view.buf, 0, -1)
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, vim.split(task.description or "", "\n", { plain = true }))
  require("isovim.surface_view").clear_marks(view.buf)
  vim.bo[view.buf].modified = false
  -- Plain markdown while it's edited, highlighted but with its marks showing.
  pcall(vim.treesitter.start, view.buf, "markdown")
  local win = vim.fn.bufwinid(view.buf)
  if win ~= -1 then
    vim.wo[win][0].winbar = (" %s's description · <Esc> in normal mode saves and leaves the edit · :w saves"):format(view.task_open)
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
  local group = vim.api.nvim_create_augroup("isovim_task_edit_" .. view.buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = view.buf,
    callback = function()
      require("isovim.safe").wrap("saving a task's description", save_description)(view, false)
    end,
  })
  -- Going elsewhere keeps what's typed.
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = view.buf,
    callback = function()
      require("isovim.safe").wrap("saving a task's description", save_description)(view, false)
    end,
  })
  bind_edit_keys(view)
  vim.cmd.startinsert()
end

local function here(view)
  return (view.line_items or {})[vim.api.nvim_win_get_cursor(0)[1]] or {}
end

local function enter(view)
  local row = here(view)
  local links = require("isovim.links")
  if row.description then
    edit_description(view)
  elseif row.thread then
    surfaces.open(row.thread)
  elseif row.task then
    M.show(view, row.task)
  elseif row.pr then
    links.open(row.pr)
  elseif row.ticket then
    links.open_url(tasks.link_url(view.repo, row.ticket))
  end
end

local function bind_keys(view)
  local bound = {}
  local function on(lhs, fn, desc)
    bound[#bound + 1] = lhs
    vim.keymap.set("n", lhs, function()
      require("isovim.safe").wrap("a task's view", fn)()
    end, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
  end
  for _, key in ipairs(M.KEYS) do
    on(key[1], function()
      local task = tasks.read(view.repo)[view.task_open]
      if task then
        M.actions[key[2]](view.repo, task)
      end
    end, key[3])
  end
  on("A", function()
    local row = here(view)
    local task = tasks.read(view.repo)[view.task_open]
    if row.thread then
      M.actions.thread_task(view.repo, row.thread)
    elseif task then
      M.actions.attach_thread(view.repo, task)
    end
  end, "move this thread, or attach an open one")
  on("<Esc>", function()
    M.back(view)
  end, "back to the board")
  on("[", function()
    require("isovim.thread_board").step_project(view, -1)
  end, "the previous project's board")
  on("]", function()
    require("isovim.thread_board").step_project(view, 1)
  end, "the next project's board")
  on("i", function()
    edit_description(view)
  end, "edit the description")
  on("<CR>", function()
    enter(view)
  end, "open what's on this line")
  on("o", function()
    local row = here(view)
    if row.pr then
      local target = require("isovim.links").resolve(row.pr)
      if target and target.secondary then
        target.secondary()
      end
    else
      require("isovim.links").secondary()
    end
  end, "a PR's own view here")
  on("?", function()
    local text = vim.tbl_map(function(key)
      return ("%-12s %s"):format(key[1], key[2])
    end, M.help_keys())
    vim.notify(table.concat(text, "\n"), vim.log.levels.INFO, { title = "A task" })
  end, "the task's keys")
  view.mode_keys = bound
end

function M.bind(view)
  vim.b[view.buf].completion = false
  if view.editing then
    bind_edit_keys(view)
  else
    bind_keys(view)
  end
end

return M
