-- A surface as you see it on Enter: rendered, not the raw file, in a buffer of its own beside the
-- chat (or in the main window).
--
-- A markdown surface or the Task Board, with an input box under it. A markdown surface is a
-- read-only markdown buffer (render-markdown draws it, as LazyVim's markdown extra sets it up), its
-- body without its frontmatter. The Task Board is drawn here instead, as markdown would draw the
-- router's words as markup (<C-j> as an HTML tag) and every task as a bullet and an empty checkbox
-- whatever its status: the sections that hold tasks, each task after its status's glyph (the
-- sidebar's), wrapped lines hung under its text, `code` drawn as code and an owner at the end like
-- (a1) dimmed. The input box is a buffer like the chat's composer, shown under the view and closed
-- with it; <CR> sends what's in it to the repo's router (the host root for the root pseudo-repo)
-- with iso send, so it goes into the router's queue through its supervisor, as any prompt of yours
-- does, and starts the router if it isn't running.
--
-- A question: who asked and what, its options numbered as the chat's question box draws them
-- (isovim.acp.look's palette), answered in the buffer: <CR> on an option or its number picks it, or
-- for a multi question toggles it, and Submit (or s) sends what's ticked. One that takes your own
-- words has the input box under it, whose <CR> sends them as the other answer (with what's ticked).
-- The answer goes through surfaces.answer, as iso answer's does, so the asker gets it the same way;
-- then the buffer shows it, and q closes it.
--
-- Each follows the file: each rescan that changes the surface (isovim.surfaces.watch) redraws it, a
-- question answered elsewhere shows its answer, and one that's gone says so.
local surfaces = require("isovim.surfaces")
local store = require("isovim.store")
local look = require("isovim.acp.look")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_surface_view")

---@class isovim.SurfaceView
---@field repo string
---@field name string
---@field kind "markdown"|"question"
---@field buf integer the rendered view
---@field input integer the input box
---@field under? integer the window the input box was opened under
---@field entry? isovim.Surface question: as last drawn
---@field chosen? string[] question: the options ticked so far (multi)
---@field answer? table question: its answer, once seen; kept after its asker removes it
---@field rows? table[] question: what each line of the buffer is, for <CR>
---@field opened? number question: when it was opened, epoch seconds
---@field split? boolean question: its window was made for it, so q closes it
---@field prev? integer question: the buffer its window showed before, which q brings back

-- In _G, so a hot reload re-binds the views the old code opened.
_G.isovim_surface_views = _G.isovim_surface_views or {} ---@type table<string, isovim.SurfaceView> by <repo>/<name>
M.views = _G.isovim_surface_views

local function key(repo, name)
  return repo .. "/" .. name
end

local function scratch(name, filetype)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = filetype
  return buf
end

-- Who reads what's typed under a surface: the repo's router, or for the root pseudo-repo (the host
-- root's surfaces) the host root.
---@return string? address <key>/aN
function M.reader(repo)
  if repo == "root" then
    for _, ws in ipairs(store.list()) do
      for _, agent in ipairs(store.agents(ws.id)) do
        if store.role(agent) == "root" then
          return ws.id .. "/" .. agent.id
        end
      end
    end
    return nil
  end
  return store.router(repo)
end

-- A task's text drawn: `code` as code with its backticks hidden, an owner at the end, like (a1) or
-- (a1, owner/repo/a3), dimmed.
local function task_marks(marks, row, col, text, done)
  if done then
    marks[#marks + 1] = { row, col, col + #text, "Comment" }
  end
  local from = 1
  while true do
    local open, close = text:find("`[^`]+`", from)
    if not open then
      break
    end
    marks[#marks + 1] = { row, col + open - 1, col + open, conceal = "" }
    marks[#marks + 1] = { row, col + open, col + close - 1, "@markup.raw" }
    marks[#marks + 1] = { row, col + close - 1, col + close, conceal = "" }
    from = close + 1
  end
  local owner = text:match("%s(%([^()]+%))$")
  if owner and vim.iter(vim.split(owner:sub(2, -2), ",")):all(function(part)
    return vim.trim(part):match("^[%w._:/-]*a%d+$") ~= nil
  end) then
    marks[#marks + 1] = { row, col + #text - #owner, col + #text, "Comment" }
  end
end

-- The Task Board's lines and their highlights ({row, col, end_col, hl} or with conceal): its title,
-- then each status that holds tasks, in the file's order of statuses. A board that doesn't parse
-- says why over the file as it is.
local function board(entry)
  local lines, marks = {}, {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      marks[#marks + 1] = { #lines - 1, 0, #text, hl }
    end
  end
  add("Task Board", "Title")
  if entry.repo ~= "general" then
    local repo = "  " .. entry.repo
    marks[#marks + 1] = { 0, #lines[1], #lines[1] + #repo, "Comment" }
    lines[1] = lines[1] .. repo
  end
  if entry.error then
    add("")
    add(("\u{f071} tasks.md doesn't parse: %s"):format(entry.error), "DiagnosticWarn")
    add("")
    vim.list_extend(lines, vim.split(vim.trim(entry.body or ""), "\n", { plain = true }))
    return lines, marks
  end
  local glyphs = require("isovim.sidebar").task_glyphs
  for _, status in ipairs(surfaces.statuses) do
    local under = vim.tbl_filter(function(task)
      return task.status == status
    end, entry.tasks or {})
    if #under > 0 then
      add("")
      local name = status:sub(1, 1):upper() .. status:sub(2)
      add(("%s  %d"):format(name, #under))
      marks[#marks + 1] = { #lines - 1, 0, #name, "Bold" }
      marks[#marks + 1] = { #lines - 1, #name, #lines[#lines], "Comment" }
      local glyph, hl = unpack(glyphs[status])
      for _, task in ipairs(under) do
        local prefix = "  " .. glyph .. " "
        add(prefix .. task.text)
        marks[#marks + 1] = { #lines - 1, 2, 2 + #glyph, hl }
        task_marks(marks, #lines - 1, #prefix, task.text, status == "done")
      end
    end
  end
  if #lines == 1 then
    add("")
    add("Nothing on the board.", "Comment")
  end
  return lines, marks
end

-- The lines the view shows for a surface, and their highlights: a markdown surface's body (drawn
-- by render-markdown, so no highlights), the Task Board as board draws it.
---@param entry isovim.Surface
---@return string[] lines, table[] marks
function M.render(entry)
  if entry.type == "tasks" then
    return board(entry)
  end
  local lines = {}
  if entry.error then
    lines[#lines + 1] = ("> **%s is broken:** %s"):format(entry.base, entry.error)
    lines[#lines + 1] = ""
  end
  if entry.title and entry.title ~= entry.name then
    lines[#lines + 1] = "# " .. entry.title
    lines[#lines + 1] = ""
  end
  local body = vim.split(entry.body or "", "\n", { plain = true })
  while #body > 0 and vim.trim(body[1]) == "" do
    table.remove(body, 1)
  end
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  vim.list_extend(lines, body)
  return lines, {}
end

---@param entry isovim.Surface
---@return string[]
function M.lines(entry)
  return (M.render(entry))
end

local function set_lines(buf, lines, marks)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mark in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(buf, NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4], conceal = mark.conceal })
  end
end

local function winbar(view)
  if view.kind == "question" then
    return view.entry.multi and " ↳ your own answer, with what's ticked · <CR> sends" or " ↳ your own answer · <CR> sends"
  end
  local reader = M.reader(view.repo)
  return reader and (" ↳ to %s · <CR> sends"):format(reader:gsub("%%", "%%%%"))
    or (" no router in %s to send to"):format(view.repo)
end

local function input_text(view)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(view.input, 0, -1, false), "\n"))
end

-- questions

-- Who asked a question, how ("asks", or "asks to run" for a permission) and what. An agent's
-- question names it in its text ("a3 asks: ..."); a router's names its asker in the surface.
local function asked(entry)
  local who, verb, text = entry.question:match("^(.-) (asks to run): (.+)$")
  if not who then
    who, verb, text = entry.question:match("^(.-) (asks): (.+)$")
  end
  if who then
    return who, verb, text
  end
  local by = entry.asker or M.reader(entry.repo)
  local ws, id = (by or ""):match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, id)
  if record and record.name and record.name ~= id then
    by = ("%s (%s)"):format(record.name, by)
  end
  return by or (entry.repo == "root" and "the host root" or entry.repo .. "'s router"), "asks", entry.question
end

local HINT = {
  one = " <CR> or its number picks · j/k moves · q closes",
  multi = " <Space>, <CR> or its number ticks · s or Submit sends · q closes",
}

-- The question view's lines as rows {text, hl?, spans?, rule?, option?, submit?, other?}: who
-- asked, the question, then its options (ticked or not for a multi question), or its answer once
-- it has one. A span's end of -1 is the line's.
---@param view isovim.SurfaceView
function M.question_rows(view)
  local entry = view.entry
  local who, verb, text = asked(entry)
  local chip = (" ? %s %s "):format(who, verb)
  local rows = {
    { "", rule = true },
    { " " .. chip .. "  " .. entry.repo .. "/" .. entry.name, spans = { { 1, 1 + #chip, "IsovimAcpAskChip" },
      { 1 + #chip, -1, "IsovimAcpOptionNote" } } },
    { "" },
  }
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    rows[#rows + 1] = { " " .. line, "IsovimAcpBold" }
  end
  rows[#rows + 1] = { "" }
  if view.answer then
    local by = view.answer.by and view.answer.by ~= "user" and view.answer.by or "you"
    rows[#rows + 1] = { ("  ⎿  Answered by %s:"):format(by), "IsovimAcpToolDone" }
    for _, line in ipairs(vim.split(surfaces.answer_text(view.answer), "\n", { plain = true })) do
      rows[#rows + 1] = { "     " .. line, "IsovimAcpBold" }
    end
  elseif view.gone then
    rows[#rows + 1] = { "  ⎿  Taken down without an answer", "IsovimAcpNotice" }
  else
    for n, option in ipairs(entry.options) do
      local ticked = entry.multi and vim.tbl_contains(view.chosen, option.label)
      local prefix = ("   %d. %s"):format(n, entry.multi and (ticked and "[x] " or "[ ] ") or "")
      local spans = { { 3, 3 + #tostring(n) + 1, "IsovimAcpOptionNr" }, { #prefix, -1, "IsovimAcpBold" } }
      if ticked then
        spans[#spans + 1] = { #prefix - 4, #prefix - 1, "IsovimAcpToolDone" }
      end
      rows[#rows + 1] = { prefix .. option.label, option = n, spans = spans }
      if option.description and option.description ~= "" then
        rows[#rows + 1] = { (" "):rep(#prefix) .. option.description, "IsovimAcpOptionNote" }
      end
    end
    if entry.other then
      rows[#rows + 1] = { ("   %d. Type something below."):format(#entry.options + 1), "IsovimAcpOptionNote", other = true }
    end
    if entry.multi then
      rows[#rows + 1] = { "" }
      rows[#rows + 1] = { "   Submit", "IsovimAcpAskTitle", submit = true }
    end
    rows[#rows + 1] = { "" }
    rows[#rows + 1] = { entry.multi and HINT.multi or HINT.one, "IsovimAcpHint" }
    return rows
  end
  rows[#rows + 1] = { "" }
  rows[#rows + 1] = { " q closes", "IsovimAcpHint" }
  return rows
end

local function draw(view)
  look.highlights()
  local rows = M.question_rows(view)
  view.rows = rows
  local win = vim.fn.bufwinid(view.buf)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win)
  set_lines(view.buf, vim.tbl_map(function(row)
    return row[1]
  end, rows))
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  for i, row in ipairs(rows) do
    if row.rule then
      vim.api.nvim_buf_set_extmark(view.buf, NS, i - 1, 0, { virt_text = { { ("─"):rep(400), "IsovimAcpAskRule" } },
        virt_text_pos = "overlay" })
    end
    if row[2] and row[1] ~= "" then
      vim.api.nvim_buf_set_extmark(view.buf, NS, i - 1, 0, { end_col = #row[1], hl_group = row[2] })
    end
    for _, span in ipairs(row.spans or {}) do
      vim.api.nvim_buf_set_extmark(view.buf, NS, i - 1, span[1], { end_col = span[2] < 0 and #row[1] or span[2],
        hl_group = span[3], priority = 150 })
    end
  end
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], #rows), cursor[2] })
  end
end

local function pending(view)
  return not (view.answer or view.gone)
end

local function close_input(view)
  local input_win = vim.fn.bufwinid(view.input)
  if input_win ~= -1 then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
end

-- Answers the question with {labels, other?} through surfaces.answer, as iso answer does; then the
-- view shows the answer.
local function respond(view, value)
  local answer, err = surfaces.answer(view.entry, value)
  if not answer then
    return vim.notify("isovim: " .. err, vim.log.levels.ERROR)
  end
  view.answer = answer
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  close_input(view)
  draw(view)
  local win = vim.fn.bufwinid(view.buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
end

local function to_input(view)
  local win = vim.fn.bufwinid(view.input)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert()
  end
end

-- Option n: picked (one question) or ticked and unticked (multi); one past the options goes to the
-- input box of a question that takes your own words.
local function choose(view, n)
  local options = view.entry.options
  if not pending(view) then
    return
  elseif not options[n] then
    return view.entry.other and n == #options + 1 and to_input(view)
  elseif not view.entry.multi then
    return respond(view, { labels = { options[n].label } })
  end
  local label = options[n].label
  if vim.tbl_contains(view.chosen, label) then
    view.chosen = vim.tbl_filter(function(each)
      return each ~= label
    end, view.chosen)
  else
    view.chosen[#view.chosen + 1] = label
  end
  draw(view)
end

-- Sends a multi question's ticked options, with the input box's words if any.
local function submit_ticked(view)
  if pending(view) then
    local other = input_text(view)
    respond(view, { labels = view.chosen, other = other ~= "" and other or nil })
  end
end

-- <CR> in the view: what's under the cursor.
local function enter(view)
  local row = view.rows[vim.api.nvim_win_get_cursor(0)[1]] or {}
  if row.option then
    choose(view, row.option)
  elseif row.submit then
    submit_ticked(view)
  elseif row.other then
    to_input(view)
  end
end

-- j/k: to the next or previous option (or Submit, or Type something), plain motions once there are
-- none.
local function step(view, dir)
  local function stop(row)
    return row.option or row.submit or row.other
  end
  if not vim.iter(view.rows):any(stop) then
    return vim.cmd("normal! " .. vim.v.count1 .. (dir > 0 and "j" or "k"))
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _ = 1, vim.v.count1 do
    local next_line = line + dir
    while view.rows[next_line] and not stop(view.rows[next_line]) do
      next_line = next_line + dir
    end
    if not view.rows[next_line] then
      break
    end
    line = next_line
  end
  vim.api.nvim_win_set_cursor(0, { line, 3 })
end

-- q: the view's windows go, or the window it took shows what it showed before.
local function close(view)
  close_input(view)
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    return
  end
  local others = vim.tbl_filter(function(each)
    return each ~= win and vim.api.nvim_win_get_config(each).relative == ""
      and not vim.b[vim.api.nvim_win_get_buf(each)].isovim_sidebar
  end, vim.api.nvim_tabpage_list_wins(0))
  if view.prev and vim.api.nvim_buf_is_valid(view.prev) and not view.split then
    vim.api.nvim_win_set_buf(win, view.prev)
  elseif #others > 0 then
    vim.api.nvim_win_close(win, true)
  else
    vim.api.nvim_win_call(win, vim.cmd.enew)
  end
end

-- The answer surface.<repo>.<name>.answered carried since the view opened: an asker collects an
-- answer given elsewhere (iso answer, another host) and removes its question at once, often
-- before a rescan here sees it answered.
local function answered_elsewhere(view)
  local events = require("isovim.events")
  local fd = vim.uv.fs_open(events.log, "r", 0)
  if not fd then
    return nil
  end
  local size = vim.uv.fs_fstat(fd).size
  local start = math.max(0, size - 65536)
  local text = vim.uv.fs_read(fd, size - start, start) or ""
  vim.uv.fs_close(fd)
  local topic, found = events.topic("surface", view.repo, view.name, "answered"), nil
  for line in text:gmatch("[^\n]+") do
    if line:find("answered", 1, true) then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" and event.topic == topic and type(event.answer) == "table"
        and (tonumber(event.time) or 0) >= view.opened - 1 then
        found = event.answer
      end
    end
  end
  return found
end

-- A question view after a rescan: entry is its surface as it is now, nil once it's gone.
local function refresh(view, entry)
  if entry and entry.type == "question" then
    -- What's ticked stays while it's an option (a router can reword a question in place).
    view.chosen = vim.tbl_filter(function(label)
      return pending(view) and vim.iter(entry.options):any(function(option)
        return option.label == label
      end)
    end, view.chosen)
    view.entry, view.answer, view.gone = entry, entry.answer, nil
  elseif pending(view) then
    view.answer = answered_elsewhere(view)
    view.gone = not view.answer
  end
  if not pending(view) then
    close_input(view)
  end
  draw(view)
end

-- The keys of the view and its input box, and the box going with the view.
local function bind(view)
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = view.input, nowait = true, desc = "isovim: " .. desc })
  end
  map({ "n", "i" }, "<CR>", function()
    M.submit(view)
  end, view.kind == "question" and "send as your own answer" or "send to the repo's router")
  map("i", "<S-CR>", "<CR>", "new line")
  map("i", "<C-j>", "<CR>", "new line")
  map({ "n", "i" }, "<C-k>", function()
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(view.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end, "go to the surface")
  if view.kind == "question" then
    local function on(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
    end
    on("<CR>", function()
      enter(view)
    end, "pick the option (tick it, for a multi question)")
    on("<Space>", function()
      local row = view.rows[vim.api.nvim_win_get_cursor(0)[1]] or {}
      if row.option and view.entry.multi then
        choose(view, row.option)
      end
    end, "tick the option")
    for n = 1, 9 do
      on(tostring(n), function()
        choose(view, n)
      end, "pick option " .. n)
    end
    on("s", function()
      if view.entry.multi then
        submit_ticked(view)
      end
    end, "send what's ticked")
    for lhs, dir in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
      on(lhs, function()
        step(view, dir)
      end, dir > 0 and "next option" or "previous option")
    end
    for _, lhs in ipairs({ "i", "a", "o" }) do
      on(lhs, function()
        to_input(view)
      end, "type your own answer")
    end
    on("q", function()
      close(view)
    end, "close")
  else
    for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
      vim.keymap.set("n", lhs, function()
        local win = vim.fn.bufwinid(view.input)
        if win ~= -1 then
          vim.api.nvim_set_current_win(win)
          vim.cmd.startinsert()
        end
      end, { buffer = view.buf, nowait = true, desc = "isovim: type to the repo's router" })
    end
  end
  -- The input box goes with the view: once no window shows the view (another buffer took its
  -- window, or it closed), its box closes too, rather than stay behind under whatever's there. The
  -- last window beside the sidebar is emptied instead, as :q there would otherwise quit isovim.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = vim.api.nvim_create_augroup("isovim_surface_view_" .. view.buf, { clear = true }),
    buffer = view.buf,
    callback = function()
      vim.schedule(function()
        local input_win = vim.fn.bufwinid(view.input)
        if vim.fn.bufwinid(view.buf) ~= -1 or input_win == -1 then
          return
        end
        local is_sidebar = require("isovim").is_sidebar
        if vim.iter(vim.api.nvim_tabpage_list_wins(0)):all(function(win)
          return win == input_win or is_sidebar(win)
        end) then
          vim.api.nvim_win_set_buf(input_win, vim.api.nvim_create_buf(true, false))
          vim.wo[input_win][0].winbar, vim.wo[input_win][0].winfixheight = "", false
        else
          pcall(vim.api.nvim_win_close, input_win, true)
        end
      end)
    end,
  })
end

local function make(entry)
  local id = key(entry.repo, entry.name)
  local view = M.views[id]
  if view and vim.api.nvim_buf_is_valid(view.buf) and vim.api.nvim_buf_is_valid(view.input) then
    return view
  end
  local question = entry.type == "question"
  view = { repo = entry.repo, name = entry.name, kind = question and "question" or "markdown", chosen = {} }
  if question then
    view.buf = scratch(("isovim-question://%s"):format(id), "isovim_question")
    vim.b[view.buf].completion = false
  else
    view.buf = scratch(("isovim-surface://%s"):format(id), entry.type == "tasks" and "isovim_tasks" or "markdown")
  end
  vim.b[view.buf].isovim_surface = id
  view.input = scratch(("isovim-surface://%s/input"):format(id), "isovim_surface_input")
  vim.b[view.input].isovim_surface_input = id
  vim.b[view.input].completion = false
  bind(view)
  M.views[id] = view
  return view
end

-- Sends the input box's text and empties it: under a markdown surface to the reader (on failure
-- the text stays), under a question as your own answer.
function M.submit(view)
  local text = input_text(view)
  if view.kind == "question" then
    if view.entry.multi and text == "" then
      return submit_ticked(view)
    elseif text ~= "" and pending(view) then
      return respond(view, { labels = view.entry.multi and view.chosen or {}, other = text })
    end
    return
  end
  if text == "" then
    return
  end
  local reader = M.reader(view.repo)
  if not reader then
    return vim.notify(("isovim: %s has no router to send to"):format(view.repo), vim.log.levels.WARN)
  end
  local message = ("[on the %s surface %s] %s"):format(view.repo, view.name, text)
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  vim.system({ require("isovim.panes").bin, "send", reader, message }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      vim.api.nvim_buf_set_lines(view.input, 0, -1, false, vim.split(text, "\n", { plain = true }))
      vim.notify("isovim: could not send to " .. reader .. ": " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
    end
  end))
end

-- The Task Board's wrapped lines hang under its task's text, two cells in from the line's indent.
local function view_window(win, question, tasks)
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.conceallevel = true, true, 2
  wo.number, wo.relativenumber, wo.signcolumn, wo.spell = false, false, "no", false
  wo.cursorline = question or false
  wo.breakindent, wo.breakindentopt = tasks, tasks and "shift:2" or ""
end

local function input_window(win, view)
  local wo = vim.wo[win][0]
  wo.winbar, wo.winfixheight = winbar(view), true
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, "no", "0", ""
end

-- A window for the view in this tab: beside a chat when one shows (in the window beside it, else a
-- split to its right), else in the main window (the biggest that isn't the sidebar or a float).
---@return integer win, boolean split made for it, integer? prev the buffer the window showed
local function place(buf)
  local chat, others = nil, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and not vim.b[b].isovim_sidebar
      and vim.bo[b].filetype ~= "isovim_sidebar" and vim.bo[b].filetype ~= "isovim_composer" and not vim.b[b].isovim_surface_input then
      if vim.bo[b].filetype == "isovim_acp" or vim.b[b].isovim_id then
        chat = chat or win
      else
        others[#others + 1] = win
      end
    end
  end
  table.sort(others, function(a, b)
    return vim.api.nvim_win_get_width(a) * vim.api.nvim_win_get_height(a) > vim.api.nvim_win_get_width(b) * vim.api.nvim_win_get_height(b)
  end)
  local win = others[1]
  if chat and not win then
    return vim.api.nvim_open_win(buf, true, { split = "right", win = chat }), true
  elseif win then
    local prev = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
    return win, false, prev
  end
  vim.cmd("vsplit")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win, true
end

-- Opens the surface rendered, beside the chat, with its input box under it (a question's only
-- while it waits and takes your own words).
---@param entry isovim.Surface
function M.open(entry)
  local view = make(entry)
  local question = view.kind == "question"
  if question then
    view.opened = os.time()
    refresh(view, entry)
  else
    set_lines(view.buf, M.render(entry))
  end
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    win, view.split, view.prev = place(view.buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  view_window(win, question, entry.type == "tasks")
  -- Its box under it, moved there if it shows anywhere else.
  local input_win = vim.fn.bufwinid(view.input)
  if input_win ~= -1 and view.under ~= win then
    pcall(vim.api.nvim_win_close, input_win, true)
    input_win = -1
  end
  if input_win == -1 and (not question or (entry.other and pending(view))) then
    input_win = vim.api.nvim_open_win(view.input, false, { split = "below", win = win, height = 3 })
    view.under = win
  end
  if input_win ~= -1 then
    input_window(input_win, view)
  end
  if question then
    -- Answered in normal mode, whatever was being typed where it was opened from (the composer).
    vim.cmd.stopinsert()
    -- On the first option, or what's under the cursor already.
    local first = vim.iter(ipairs(view.rows)):find(function(_, row)
      return row.option
    end)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    if first and not (view.rows[line] and view.rows[line].option) then
      vim.api.nvim_win_set_cursor(win, { first, 3 })
    end
    return view
  end
  if entry.type == "tasks" then
    return view
  end
  -- render-markdown loads on the first markdown buffer and skips that one (its FileType has gone
  -- by), so the view's FileType goes again once it's loaded, which attaches it.
  if not vim.b[view.buf].isovim_rendered and pcall(require, "render-markdown") then
    vim.b[view.buf].isovim_rendered = true
    vim.api.nvim_win_call(win, function()
      vim.bo[view.buf].filetype = "markdown"
    end)
  end
  return view
end

-- After a hot reload the open views take the new keys and are drawn again by the new code, each
-- window kept where it was scrolled.
function M.rebind()
  for _, view in pairs(M.views) do
    if vim.api.nvim_buf_is_valid(view.buf) and vim.api.nvim_buf_is_valid(view.input) then
      for _, buf in ipairs({ view.buf, view.input }) do
        for _, mode in ipairs({ "n", "i" }) do
          for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if vim.startswith(map.desc or "", "isovim: ") then
              vim.api.nvim_buf_del_keymap(buf, mode, map.lhs)
            end
          end
        end
      end
      bind(view)
      local views = {}
      for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      end
      local entry = surfaces.get(view.repo, view.name)
      if view.kind == "question" then
        draw(view)
      elseif entry then
        set_lines(view.buf, M.render(entry))
      end
      for win, saved in pairs(views) do
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(saved)
        end)
      end
    end
  end
end

-- A rescan of repo changed its surfaces: open views redraw, a question answered elsewhere shows its
-- answer, and one whose surface went says so.
function M.changed(repo, entries)
  for _, view in pairs(M.views) do
    if view.repo == repo and vim.api.nvim_buf_is_valid(view.buf) then
      local entry = vim.iter(entries):find(function(each)
        return each.name == view.name
      end)
      if view.kind == "question" then
        refresh(view, entry)
      else
        if entry then
          set_lines(view.buf, M.render(entry))
        else
          local gone = ("%s/%s is gone: its router removed it."):format(view.repo, view.name)
          set_lines(view.buf, { vim.bo[view.buf].filetype == "markdown" and "> " .. gone or gone })
        end
        local input_win = vim.fn.bufwinid(view.input)
        if input_win ~= -1 then
          vim.wo[input_win][0].winbar = winbar(view)
        end
      end
    end
  end
end

return M
