-- A surface as you see it on Enter: rendered, not the raw file, in a buffer of its own, a tab in the
-- main window (isovim.show).
--
-- A markdown surface: a read-only markdown buffer (render-markdown draws it, as LazyVim's markdown
-- extra sets it up), its body without its frontmatter, with an input box under it. The Task Board,
-- alone in its window with no input box: drawn here instead, as markdown would draw the router's
-- words as markup (<C-j> as an HTML tag) and every task as a bullet and an empty checkbox whatever
-- its status: the sections that hold tasks, each task after its status's glyph (the sidebar's),
-- wrapped lines hung under its text, `code` drawn as code and an owner at the end like (a1)
-- dimmed. The input box is a buffer of its own, shown under the view and closed with it; <CR> sends what's in it to the repo's router (the host root for the root pseudo-repo)
-- with iso send, so it goes into the router's queue through its supervisor, as any prompt of yours
-- does, and starts the router if it isn't running. It takes images as the chat's composer does
-- (isovim.acp.images), sent with iso send --image.
--
-- A page (isovim.pages): rendered as a markdown surface is, with its comments drawn on it (a sign
-- and a note under the lines each is on) and keys to comment on lines, reply and step through them;
-- its input box takes a comment or a reply as well as words to the router.
--
-- A question: who asked and what, its options numbered as the chat's question box draws them
-- (isovim.acp.look's palette), answered in the buffer: <CR> on an option or its number picks it, or
-- for a multi question toggles it, and Submit (or s) sends what's ticked. One that takes your own
-- words has the input box under it, whose <CR> sends them as the other answer (with what's ticked).
-- The answer goes through surfaces.answer, as iso answer's does, so the asker gets it the same way;
-- then the buffer shows it, and q closes it.
--
-- Each is a tab of its own in its repo's scope (isovim.scope lists it only there), named and marked
-- as its Inbox row is; deleting the buffer (closing the tab) closes the view and its input box.
--
-- Each follows the file: each rescan that changes the surface (isovim.surfaces.watch) redraws it, a
-- question answered elsewhere shows its answer, and one that's gone says so.
local surfaces = require("isovim.surfaces")
local images = require("isovim.acp.images")
local store = require("isovim.store")
local look = require("isovim.acp.look")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_surface_view")

-- The PRs surface's keys on a PR's line, for its view and ? help: {lhs, what, fn(pr, view)}.
M.prs_keys = {
  { "<CR>", "open the PR as its own view (isovim.pr_view)", function(pr, view)
    require("isovim.pr_view").open(view.repo, pr.url)
  end },
  { "o", "open the PR in the browser", function(pr)
    vim.ui.open(pr.url)
  end },
  { "y", "copy the PR's URL", function(pr)
    vim.fn.setreg("+", pr.url)
    vim.notify("Copied " .. pr.url)
  end },
  { "c", "the PR's Files changed", function(pr)
    vim.ui.open(pr.url .. "/files")
  end },
  { "a", "the chat of the agent that registered it", function(pr)
    local ws, agent = (pr.by or ""):match("^(.*)/([^/]+)$")
    if not ws then
      return vim.notify("isovim: no agent registered " .. pr.url, vim.log.levels.WARN)
    end
    require("isovim").open(ws, agent)
  end },
}

---@class isovim.SurfaceView
---@field repo string
---@field name string
---@field kind "markdown"|"tasks"|"prs"|"decisions"|"page"|"question"
---@field line_items? table<integer, table> prs and decisions: the PR or decision each line is, for its keys
---@field buf integer the rendered view
---@field input integer the input box
---@field under? integer the window the input box was opened under
---@field entry? isovim.Surface question: as last drawn
---@field chosen? string[] question: the options ticked so far (multi)
---@field answer? table question: its answer, once seen; kept after its asker removes it
---@field rows? table[] question: what each line of the buffer is, for <CR>
---@field opened? number question: when it was opened, epoch seconds
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

local PR_GROUPS = { { "open", "Open" }, { "draft", "Draft" }, { "merged", "Merged today" }, { "closed", "Closed" } }
local CI = { pass = { "✓", "DiagnosticOk" }, fail = { "✗", "DiagnosticError" }, pending = { "●", "DiagnosticWarn" } }
local REVIEW = {
  APPROVED = { "approved", "DiagnosticOk" },
  CHANGES_REQUESTED = { "changes requested", "DiagnosticError" },
  REVIEW_REQUIRED = { "review required", "DiagnosticWarn" },
}

-- How long ago, in one unit: 5m, 3h, 2d.
local function age(at)
  local seconds = math.max(0, os.time() - at)
  if seconds < 3600 then
    return ("%dm"):format(math.floor(seconds / 60))
  elseif seconds < 86400 then
    return ("%dh"):format(math.floor(seconds / 3600))
  end
  return ("%dd"):format(math.floor(seconds / 86400))
end

-- The PRs surface's lines, highlights and the PR on each line: its title, then each group that has
-- PRs, a PR a line: its CI (or merged/closed glyph), #n and title, then dim: its review, the agent
-- that registered it and its age.
-- The views isovim draws itself, with no input box under them.
local DRAWN = { tasks = true, prs = true, decisions = true }

-- A view of what isovim makes rather than a file's: its entry, made afresh; nil for any other view.
local function own_entry(view)
  if view.kind == "prs" then
    return surfaces.prs_entry(view.repo, true)
  elseif view.kind == "decisions" then
    return surfaces.decisions_entry(view.repo, true)
  end
end

-- Where the root reasoned about a decision: its transcript, at the question's last mention.
local function open_reasoning(decision)
  local ws, agent = decision.by:match("^(.*)/([^/]+)$")
  local path = ws and require("isovim.transcript").path(ws, agent)
  if not (path and vim.uv.fs_stat(path)) then
    return vim.notify(("isovim: %s has no transcript here"):format(decision.by), vim.log.levels.WARN)
  end
  local last
  for i, line in ipairs(vim.fn.readfile(path)) do
    if line:find(decision.name, 1, true) then
      last = i
    end
  end
  require("isovim").show(path, last)
end

-- A PR's line: its CI glyph (the merged or closed one once it's done), #n and title, its review,
-- then dim the agent that registered it and its age; an isovim.boxes line.
local function pr_line(pr)
  local prs, boxes = require("isovim.prs"), require("isovim.boxes")
  local seg = boxes.seg
  local glyph, hl
  if pr.state == "MERGED" or pr.state == "CLOSED" then
    glyph, hl = prs.icon(pr)
  else
    glyph, hl = unpack(CI[pr.checks or ""] or { "·", "Comment" })
  end
  local parts = { seg(glyph, hl), seg(" ") }
  if pr.number then
    vim.list_extend(parts, { seg(("#%d"):format(pr.number), "Comment"), seg(" ") })
  end
  parts[#parts + 1] = seg(pr.title or pr.url)
  local review = pr.state == "OPEN" and REVIEW[pr.review or ""]
  if review then
    vim.list_extend(parts, { seg("  "), seg(review[1], review[2]) })
  end
  local tail = {}
  local ws, agent = (pr.by or ""):match("^(.*)/([^/]+)$")
  if ws then
    local spec = store.agent(ws, agent)
    tail[#tail + 1] = spec and spec.name or agent
  end
  local since = prs.time(pr.createdAt) or pr.registered
  if since then
    tail[#tail + 1] = age(since)
  end
  if #tail > 0 then
    parts[#parts + 1] = seg("  " .. table.concat(tail, " · "), "Comment")
  end
  return boxes.cat(unpack(parts))
end

-- The PRs surface's lines, highlights and the PR on each line: its title, then the router's groups
-- (iso <role> pr group), each a box with its name and count in its top border and its note under
-- it, the PRs in none in Other; with none, the state sections (open, draft, merged today, closed).
-- width: the window's, for the boxes.
local function prs_board(entry, width)
  local boxes = require("isovim.boxes")
  local seg, cat = boxes.seg, boxes.cat
  local lines, marks, rows = {}, {}, {}
  local function add(line, pr)
    lines[#lines + 1] = line.text
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3] }
    end
    rows[#lines] = pr
  end
  add(cat(seg("PRs", "Title"), seg("  " .. entry.repo, "Comment")))
  if entry.sections then
    boxes.highlights()
    width = math.max(40, (width or 100) - 1)
    for _, section in ipairs(entry.sections) do
      add(seg(""))
      add(boxes.top(width, cat(seg(section.name, "IsovimPrTitle"), seg("  " .. #section.prs, "IsovimPrDim"))))
      if section.note and section.note ~= "" then
        add(boxes.side(width, seg(section.note, "IsovimPrDim")))
      end
      for _, pr in ipairs(section.prs) do
        add(boxes.side(width, pr_line(pr)), pr)
      end
      add(boxes.bottom(width))
    end
    return lines, marks, rows
  end
  for _, group in ipairs(PR_GROUPS) do
    local list = entry.groups and entry.groups[group[1]] or {}
    if #list > 0 then
      add(seg(""))
      add(cat(seg(group[2], "Bold"), seg(("  %d"):format(#list), "Comment")))
      for _, pr in ipairs(list) do
        add(cat(seg("  "), pr_line(pr)), pr)
      end
    end
  end
  if #lines == 1 then
    add(seg(""))
    add(seg(entry.registered == 0 and "No PRs registered here yet (iso <role> pr registers one)." or "No PRs from the last day.", "Comment"))
  end
  return lines, marks, rows
end

-- The decision log's lines, highlights and the decision on each line: its title, then a box for each
-- decision, newest first: when and who over the question, the answer and the why; its transcript's
-- a key away.
local function decisions_board(entry, width)
  local boxes = require("isovim.boxes")
  local seg, cat = boxes.seg, boxes.cat
  boxes.highlights()
  width = math.max(40, (width or 100) - 1)
  local lines, marks, rows = {}, {}, {}
  local function add(line, decision)
    lines[#lines + 1] = line.text
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3] }
    end
    rows[#lines] = decision
  end
  add(cat(seg("Decisions", "Title"), seg("  " .. entry.repo, "Comment")))
  local decisions = surfaces.decisions(entry.repo)
  for _, decision in ipairs(decisions) do
    local who = entry.repo == "root" and decision.by or decision.by:match("[^/]+$")
    local where = decision.repo ~= entry.repo and ("  " .. decision.repo) or ""
    add(seg(""))
    add(boxes.top(width, cat(seg(os.date("%b %-d %H:%M", decision.at), "IsovimPrTitle"), seg("  " .. who .. where, "IsovimPrDim"))), decision)
    for _, line in ipairs(boxes.markdown(decision.question or decision.name, width - 4)) do
      add(boxes.side(width, line), decision)
    end
    add(boxes.side(width, seg("")), decision)
    local answer = surfaces.answer_text(decision):gsub("\n", " · ")
    add(boxes.side(width, cat(seg("→ ", "IsovimPrDim"), seg(answer, "Bold"))), decision)
    if decision.why then
      for _, line in ipairs(boxes.markdown(decision.why, width - 4)) do
        add(boxes.side(width, line), decision)
      end
    end
    add(boxes.bottom(width, (decision.why and "" or "no why given  ") .. "<CR> " .. who:match("[^/]+$") .. "'s transcript"), decision)
  end
  if #decisions == 0 then
    add(seg(""))
    add(seg("Nothing decided yet: what a root answers in root mode lands here.", "Comment"))
  end
  return lines, marks, rows
end

-- The lines the view shows for a surface, and their highlights: a markdown surface's body (drawn
-- by render-markdown, so no highlights), the Task Board as board draws it, the PRs surface as
-- prs_board does (with the PR on each line).
---@param entry isovim.Surface
---@param width? integer the window's, for what's drawn in boxes
---@return string[] lines, table[] marks, table<integer, isovim.Pr>? rows
function M.render(entry, width)
  if entry.type == "tasks" then
    return board(entry)
  elseif entry.type == "prs" then
    return prs_board(entry, width)
  elseif entry.type == "decisions" then
    return decisions_board(entry, width)
  elseif entry.type == "page" then
    -- Its body line for line (no title over it, nothing trimmed from its top), so a comment's
    -- lines are the file's less where the body starts (isovim.pages.draw).
    local lines = vim.split(entry.body or "", "\n", { plain = true })
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
      table.remove(lines)
    end
    if entry.error then
      table.insert(lines, 1, ("> **%s is broken:** %s"):format(entry.base, entry.error))
    end
    return lines, {}
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

-- Its tab: the Task Board, a markdown surface's title, a question's name, after its Inbox row's glyph
-- (the starter's bufferline reads b:isovim_tab).
local function tab(view, entry)
  local mark = require("isovim.sidebar").surface_chunks(entry)[1]
  vim.b[view.buf].isovim_tab = { name = view.kind == "question" and entry.name or entry.title, icon = mark[1], hl = mark[2] }
  vim.cmd.redrawtabline()
end

local set_lines

-- A view drawn from its surface: its lines, and for the PRs surface the PR on each.
local function draw_surface(view, entry)
  view.base = entry.base
  local win = vim.fn.bufwinid(view.buf)
  view.width = win ~= -1 and vim.api.nvim_win_get_width(win) or 100
  local lines, marks, rows = M.render(entry, view.width)
  view.line_items = rows
  set_lines(view.buf, lines, marks)
  if view.kind == "page" then
    view.page_offset = (entry.body_line or 1) - 1 - (entry.error and 1 or 0)
    view.source_lines = lines
    require("isovim.pages").draw(view)
    -- Its iso: addresses as chips in their place (isovim.links); the comments go by the lines above.
    require("isovim.links").substitute(view.buf)
  end
end

function set_lines(buf, lines, marks)
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
  local page = view.kind == "page" and require("isovim.pages").winbar(view)
  if page then
    return page
  elseif view.kind == "question" then
    return view.entry.multi and " ↳ your own answer, with what's ticked · <CR> sends" or " ↳ your own answer · <CR> sends"
  end
  local reader = M.reader(view.repo)
  return reader and (" ↳ to %s · <CR> sends · <C-v> image · u above marks it unread"):format(reader:gsub("%%", "%%%%"))
    or (" no router in %s to send to"):format(view.repo)
end

M.winbar = winbar

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
  one = " <CR> or its number picks · j/k moves · n next · q closes",
  multi = " <Space>, <CR> or its number ticks · s or Submit sends · n next · q closes",
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
  -- Root mode: the root deciding it, or the why of a root that raised it to you.
  if not view.answer and not view.gone and entry.deciding then
    rows[#rows + 1] = { (" %s is deciding this (root mode); you can answer it anyway."):format(entry.deciding),
      "IsovimAcpOptionNote" }
    rows[#rows + 1] = { "" }
  elseif not view.answer and not view.gone and entry.raised and entry.raised_by and entry.raised_by ~= "isovim" then
    rows[#rows + 1] = { (" ↑ %s raised it to you%s"):format(entry.raised_by, entry.why and (": " .. entry.why) or ""),
      "IsovimAcpNotice" }
    rows[#rows + 1] = { "" }
  end
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
  rows[#rows + 1] = { " n next · q closes", "IsovimAcpHint" }
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

-- q: the window it took shows what it showed before.
local function close(view)
  close_input(view)
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    return
  end
  if view.prev and vim.api.nvim_buf_is_valid(view.prev) and view.prev ~= view.buf then
    vim.api.nvim_win_set_buf(win, view.prev)
  else
    vim.api.nvim_win_call(win, vim.cmd.enew)
  end
end

-- n / N: the next or previous question waiting on you after this one, in the Inbox's order
-- (isovim.waiting_surfaces, needs_you only, so one a root is deciding is skipped), round past the
-- end; it replaces this view in its window, and q there goes back to what this one replaced.
local function next_question(view, dir)
  local isovim = require("isovim")
  local here = isovim.inbox_place(view.entry)
  local function before(a, b)
    for i = 1, 3 do
      if a[i] ~= b[i] then
        return a[i] < b[i]
      end
    end
    return false
  end
  local others = vim.tbl_filter(function(item)
    return item.entry.type == "question" and not (item.entry.repo == view.repo and item.entry.name == view.name)
  end, isovim.waiting_surfaces())
  if #others == 0 then
    return Snacks.notify.info("No other questions waiting", { title = "isovim" })
  end
  local pick
  if dir > 0 then
    pick = vim.iter(others):find(function(item)
      return before(here, item.at)
    end) or others[1]
  else
    pick = vim.iter(others):rfind(function(item)
      return before(item.at, here)
    end) or others[#others]
  end
  local prev = view.prev
  local next_view = M.open(pick.entry)
  if next_view.prev == view.buf then
    next_view.prev = prev
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
  if view.kind == "markdown" or view.kind == "page" then
    images.setup(view.input, surfaces.dir(view.repo) .. "/images")
  end
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
  require("isovim").map_to_sidebar(view.input, { "n", "i" })
  require("isovim").map_to_sidebar(view.buf)
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
    on("n", function()
      next_question(view, 1)
    end, "the next question waiting")
    on("N", function()
      next_question(view, -1)
    end, "the previous question waiting")
  elseif view.kind == "prs" then
    for _, key in ipairs(M.prs_keys) do
      vim.keymap.set("n", key[1], function()
        local pr = (view.line_items or {})[vim.api.nvim_win_get_cursor(0)[1]]
        if pr then
          key[3](pr, view)
        end
      end, { buffer = view.buf, nowait = true, desc = "isovim: " .. key[2] })
    end
  elseif view.kind == "decisions" then
    vim.keymap.set("n", "<CR>", function()
      local decision = (view.line_items or {})[vim.api.nvim_win_get_cursor(0)[1]]
      if decision then
        open_reasoning(decision)
      end
    end, { buffer = view.buf, nowait = true, desc = "isovim: the root's transcript, at this question" })
  elseif view.kind == "page" then
    require("isovim.pages").bind(view)
  elseif view.kind == "markdown" then
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
  -- u: back in the Inbox until it's opened again (a question says why it needs no marking).
  vim.keymap.set("n", "u", function()
    local entry = view.kind == "question" and view.entry
      or view.kind == "prs" and surfaces.prs_entry(view.repo) or surfaces.get(view.repo, view.name)
    if entry then
      surfaces.mark_unread(entry)
    end
  end, { buffer = view.buf, nowait = true, desc = "isovim: mark it unread" })
  -- The input box goes with the view: once no window shows the view (another buffer took its
  -- window, or it closed), its box closes too, rather than stay behind under whatever's there. The
  -- last window beside the sidebar is emptied instead, as :q there would otherwise quit isovim.
  local group = vim.api.nvim_create_augroup("isovim_surface_view_" .. view.buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = view.buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      require("isovim.safe").schedule("a surface's view", function()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == view.buf then
          M.dress(view, win)
          -- Come back to by its tab: what you marked unread is read again.
          if view.base then
            surfaces.opened(view.repo, view.base)
          end
        end
      end)
    end,
  })
  -- Its tab closed (Snacks.bufdelete, :bd): the view goes, its box and its buffers with it.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = view.buf,
    callback = function()
      require("isovim.safe").schedule("closing a surface's view", function()
        close_input(view)
        M.views[key(view.repo, view.name)] = nil
        pcall(vim.api.nvim_buf_delete, view.input, { force = true })
        pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = view.buf,
    callback = function()
      require("isovim.safe").schedule("a surface's input box", function()
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
  view = { repo = entry.repo, name = entry.name, kind = entry.type, chosen = {} }
  if question then
    view.buf = scratch(("isovim-question://%s"):format(id), "isovim_question")
    vim.b[view.buf].completion = false
  else
    local filetype = ({ tasks = "isovim_tasks", prs = "isovim_prs", decisions = "isovim_decisions" })[entry.type] or "markdown"
    view.buf = scratch(("isovim-surface://%s"):format(id), filetype)
  end
  vim.b[view.buf].isovim_surface = id
  vim.b[view.buf].isovim_scope = entry.repo
  vim.bo[view.buf].buflisted = true
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
  elseif view.kind == "page" and require("isovim.pages").submit(view, text) then
    return
  end
  local reader = M.reader(view.repo)
  if not reader then
    return vim.notify(("isovim: %s has no router to send to"):format(view.repo), vim.log.levels.WARN)
  end
  local attached
  text, attached = images.collect(view.input, text)
  local cmd = { require("isovim.panes").bin, "send", reader, ("[on the %s surface %s] %s"):format(view.repo, view.name, text) }
  for _, image in ipairs(attached) do
    vim.list_extend(cmd, { "--image", image.path })
  end
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      vim.api.nvim_buf_set_lines(view.input, 0, -1, false, vim.split(text, "\n", { plain = true }))
      images.set(view.input, attached)
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

-- The window showing the view: its options, and its input box under it (moved there if it shows
-- anywhere else), whenever the view comes into a window, by Enter in an Inbox or by its tab.
function M.dress(view, win)
  local question = view.kind == "question"
  view_window(win, question, DRAWN[view.kind] or false)
  if view.kind == "page" then
    require("isovim.pages").dress(win)
  end
  local boxed = view.kind == "markdown" or view.kind == "page" or (question and view.entry.other and pending(view))
  local input_win = vim.fn.bufwinid(view.input)
  if input_win ~= -1 and (view.under ~= win or not boxed) then
    pcall(vim.api.nvim_win_close, input_win, true)
    input_win = -1
  end
  if input_win == -1 and boxed then
    input_win = vim.api.nvim_open_win(view.input, false, { split = "below", win = win, height = 3 })
    view.under = win
  end
  if input_win ~= -1 then
    input_window(input_win, view)
  end
end

-- Opens the surface rendered, as a tab in the main window, with its input box under it: a markdown surface's
-- always, a question's while it waits and takes your own words, the Task Board's never.
---@param entry isovim.Surface
function M.open(entry)
  local view = make(entry)
  local question = view.kind == "question"
  if question then
    view.opened = os.time()
    refresh(view, entry)
  else
    draw_surface(view, entry)
  end
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    -- As a tab in the main window, replacing what it showed (isovim.show).
    win, view.prev = require("isovim").show(view.buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  tab(view, entry)
  M.dress(view, win)
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
  if DRAWN[view.kind] then
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
        for _, mode in ipairs({ "n", "i", "x" }) do
          for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if vim.startswith(map.desc or "", "isovim: ") then
              vim.api.nvim_buf_del_keymap(buf, mode, map.lhs)
            end
          end
        end
      end
      -- A Task Board opened before it had a kind of its own was a markdown one, with a box.
      if view.kind == "markdown" and view.name == "tasks" then
        view.kind = "tasks"
        local input_win = vim.fn.bufwinid(view.input)
        if input_win ~= -1 then
          pcall(vim.api.nvim_win_close, input_win, true)
        end
      end
      bind(view)
      local views = {}
      for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      end
      local entry = own_entry(view) or surfaces.get(view.repo, view.name)
      -- One opened before views had tabs gets its own.
      if vim.b[view.buf].isovim_scope == nil then
        vim.b[view.buf].isovim_scope = view.repo
        vim.bo[view.buf].buflisted = true
      end
      if entry then
        tab(view, entry)
      end
      if view.kind == "question" then
        draw(view)
      elseif entry then
        draw_surface(view, entry)
      end
      for win, saved in pairs(views) do
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(saved)
        end)
      end
    end
  end
end

-- A PRs surface's or decision log's window resized: drawn again, its boxes to the new width.
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("isovim_prs_resize", { clear = true }),
  callback = function()
    for _, view in pairs(M.views) do
      local win = own_entry(view) and vim.api.nvim_buf_is_valid(view.buf) and vim.fn.bufwinid(view.buf) or -1
      if win ~= -1 and vim.api.nvim_win_get_width(win) ~= view.width then
        return require("isovim.safe").wrap("drawing the boards", M.refresh_boards)()
      end
    end
  end,
})

-- The PRs surfaces and decision logs open, drawn again from what they read: run as the sidebar
-- refreshes, which it does as a fetch lands, a PR is registered, a pr.* event comes or a root answers.
function M.refresh_boards()
  for _, view in pairs(M.views) do
    local entry = vim.api.nvim_buf_is_valid(view.buf) and own_entry(view)
    if entry then
      tab(view, entry)
      draw_surface(view, entry)
    end
  end
end

-- A rescan of repo changed its surfaces: open views redraw, a question answered elsewhere shows its
-- answer, and one whose surface went says so.
-- Closes a surface's open tabs, as closing them would: the user removed or hid it (d).
function M.close(repo, name)
  for _, view in pairs(M.views) do
    if view.repo == repo and (view.name == name or (name == "PRs" and view.kind == "prs")) and vim.api.nvim_buf_is_valid(view.buf) then
      pcall(Snacks.bufdelete, { buf = view.buf, force = true })
    end
  end
end

function M.changed(repo, entries)
  for _, view in pairs(M.views) do
    -- These aren't its files: M.refresh_boards draws them.
    if view.repo == repo and not own_entry(view) and vim.api.nvim_buf_is_valid(view.buf) then
      local entry = vim.iter(entries):find(function(each)
        return each.name == view.name
      end)
      if entry then
        tab(view, entry)
      end
      if view.kind == "question" then
        refresh(view, entry)
      else
        if entry then
          draw_surface(view, entry)
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
