-- One PR as its own surface (filetype isovim_pr), opened as a tab (isovim.show) by <CR> on its line
-- in the PRs surface or from the jump: its header (#n and title; state, author, base ← head, the
-- agent that registered it, age, mergeable), its description as the chat draws an agent's markdown
-- (isovim.acp.look, tables too), its checks with their glyph and duration, its reviews and comments
-- with the inline threads by file:line (resolved ones folded), and its files with their +/- counts.
-- Each section folds (za). It's read-only: approving, merging and commenting are the browser's (o).
--
-- The data comes from gh in the background (gh pr view, and gh api graphql for the review threads),
-- kept under run/<repo>/pr-<n>.json and drawn from there at once, with "refreshing…" in the header
-- until the fetch lands; r fetches again, and a pr.<repo>.<n>.ci|review|state event does too. <CR> on a
-- failed check opens its log (gh run view --log-failed) as a tab, on a file its diff (from gh pr
-- diff, as a diff buffer), c every file's.
local store = require("isovim.store")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_pr_view")
local FIELDS = "number,title,state,isDraft,author,baseRefName,headRefName,mergeable,body,createdAt,url,statusCheckRollup,reviews,files,comments"
local THREADS = [[query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100) { nodes { isResolved path line originalLine
      comments(first: 50) { nodes { author { login } body } } } } } } }]]

---@class isovim.PrView
---@field repo string the repo key the PR is registered under
---@field url string
---@field buf integer
---@field rows table<integer, {check?: table, file?: string}> what each line is, for <CR>
---@field levels table<integer, string> each line's fold level, for foldexpr
---@field refreshing? boolean
---@field failed? boolean the last fetch got nothing from gh

---@type table<string, isovim.PrView> by url
M.views = _G.isovim_pr_views or {}
_G.isovim_pr_views = M.views

local fetching = {} ---@type table<string, boolean>

local function parts(url)
  local owner, name, number = url:match("github%.com/([^/]+)/([^/]+)/pull/(%d+)")
  return owner, name, tonumber(number)
end

local function cache_file(repo, url, ext)
  local _, _, number = parts(url)
  return ("%s/pr-%d.%s"):format(store.run_dir(repo), number, ext or "json")
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(value) == "table" and value or nil
end

-- How long between two of gh's times, or since one: 40s, 5m, 3h, 2d.
local function span(from, to)
  local prs = require("isovim.prs")
  local a, b = prs.time(from), to and prs.time(to) or os.time()
  if not a or not b then
    return nil
  end
  local seconds = math.max(0, b - a)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local FAILED = { FAILURE = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true, STARTUP_FAILURE = true, ERROR = true }

-- A check's glyph and color, and whether it failed.
local function check_mark(check)
  local done = check.status == "COMPLETED" or (check.state and check.state ~= "PENDING" and check.state ~= "EXPECTED")
  local verdict = check.conclusion or check.state
  if FAILED[verdict] then
    return "✗", "DiagnosticError", true
  elseif not done then
    return "●", "DiagnosticWarn", false
  elseif verdict == "SUCCESS" then
    return "✓", "DiagnosticOk", false
  end
  return "–", "Comment", false
end

local REVIEW = {
  APPROVED = { "approved", "DiagnosticOk" },
  CHANGES_REQUESTED = { "changes requested", "DiagnosticError" },
  COMMENTED = { "commented", "Comment" },
  DISMISSED = { "dismissed", "Comment" },
}

-- The view's lines, highlights {row, col, end_col, hl[, conceal]}, what each line is and each line's
-- fold level: 0 for the header, >1 opening a section, 1 in it, >2 a resolved thread (closed).
local function render(view, data)
  local lines, marks, rows, levels = {}, {}, {}, {}
  local function add(text, hl, level)
    lines[#lines + 1] = text
    levels[#lines] = level or "1"
    if hl then
      marks[#marks + 1] = { #lines - 1, 0, #text, hl }
    end
    return #lines - 1
  end
  local function dim(row, from, to)
    marks[#marks + 1] = { row, from, to, "Comment" }
  end
  local function section(title, count)
    add("", nil, "0")
    local text = count and ("%s  %s"):format(title, count) or title
    local row = add(text, nil, ">1")
    marks[#marks + 1] = { row, 0, #title, "Bold" }
    dim(row, #title, #text)
  end
  if not data then
    add(("#%d"):format(select(3, parts(view.url))), "Title", "0")
    add(view.refreshing and "Fetching from GitHub…" or "gh gave nothing for it: r tries again.", "Comment", "0")
    return lines, marks, rows, levels
  end
  -- Header.
  local row = add(("#%d %s"):format(data.number or 0, data.title or ""), "Title", "0")
  local state = data.isDraft and data.state == "OPEN" and "draft" or (data.state or "?"):lower()
  local facts = { state }
  if type(data.author) == "table" and data.author.login then
    facts[#facts + 1] = "by " .. data.author.login
  end
  if data.baseRefName then
    facts[#facts + 1] = ("%s ← %s"):format(data.baseRefName, data.headRefName or "?")
  end
  local info = store.pr_info(view.repo)[view.url] or {}
  local ws, agent = (info.by or ""):match("^(.*)/([^/]+)$")
  if ws then
    local spec = store.agent(ws, agent)
    facts[#facts + 1] = "registered by " .. (spec and spec.name or agent)
  end
  facts[#facts + 1] = span(data.createdAt)
  local mergeable = ({ MERGEABLE = { "mergeable", "DiagnosticOk" }, CONFLICTING = { "conflicts", "DiagnosticError" } })[data.mergeable or ""]
  local text = table.concat(vim.tbl_filter(function(fact)
    return fact ~= nil
  end, facts), " · ")
  row = add(text, "Comment", "0")
  if data.state == "OPEN" and mergeable then
    local col = #lines[#lines] + 3
    lines[#lines] = lines[#lines] .. " · " .. mergeable[1]
    marks[#marks + 1] = { row, col, #lines[#lines], mergeable[2] }
  end
  local state_hl = ({ open = "DiagnosticOk", draft = "Comment", merged = "Special", closed = "DiagnosticError" })[state]
  if state_hl then
    marks[#marks + 1] = { row, 0, #state, state_hl }
  end
  -- Description, as the chat draws markdown, in its colors.
  section("Description")
  local look = require("isovim.acp.look")
  look.highlights()
  local body = vim.split(vim.trim((data.body or ""):gsub("\r", "")), "\n", { plain = true })
  if #body == 1 and body[1] == "" then
    add("  No description.", "Comment")
  end
  local i = 1
  while i <= #body do
    if look.table_row(body[i]) and body[i + 1] and look.table_alignments(body[i + 1]) then
      local tbl = {}
      while body[i] and look.table_row(body[i]) do
        tbl[#tbl + 1] = body[i]
        i = i + 1
      end
      local drawn, spans = look.table(tbl, 100)
      local first = #lines
      for _, line in ipairs(drawn) do
        add("  " .. line)
      end
      for _, span_ in ipairs(spans) do
        marks[#marks + 1] = { first + span_[1], span_[2] + 2, span_[3] + 2, span_[4] }
      end
    else
      local line = body[i] == "" and "" or "  " .. body[i]
      local r = add(line)
      local spans, conceals = look.markdown(line)
      for _, s in ipairs(spans) do
        marks[#marks + 1] = { r, s[1], s[2], s[3] }
      end
      for _, c in ipairs(conceals) do
        marks[#marks + 1] = { r, c[1], c[2], conceal = "" }
      end
      i = i + 1
    end
  end
  -- Checks.
  local checks = type(data.statusCheckRollup) == "table" and data.statusCheckRollup or {}
  local passed, failed, pending = 0, 0, 0
  for _, check in ipairs(checks) do
    local glyph, _, bad = check_mark(check)
    passed = passed + (glyph == "✓" and 1 or 0)
    failed = failed + (bad and 1 or 0)
    pending = pending + (glyph == "●" and 1 or 0)
  end
  section("Checks", #checks > 0 and ("%d ✓  %d ✗  %d ●"):format(passed, failed, pending) or "none")
  for _, check in ipairs(checks) do
    local glyph, hl, bad = check_mark(check)
    local name = check.name or check.context or "?"
    if check.workflowName and check.workflowName ~= "" and check.workflowName ~= name then
      name = check.workflowName .. " / " .. name
    end
    local took = span(check.startedAt, check.completedAt)
    local line = "  " .. glyph .. " " .. name
    local r = add(line .. (took and "  " .. took or "") .. (bad and "  <CR> its log" or ""))
    marks[#marks + 1] = { r, 2, 2 + #glyph, hl }
    dim(r, #line, #lines[#lines])
    rows[r + 1] = { check = check }
  end
  -- Reviews and comments, then the inline threads by file:line.
  local reviews = vim.tbl_filter(function(review)
    return review.state ~= "PENDING" and (review.state ~= "COMMENTED" or vim.trim(review.body or "") ~= "")
  end, type(data.reviews) == "table" and data.reviews or {})
  local comments = type(data.comments) == "table" and data.comments or {}
  local threads = type(data.threads) == "table" and data.threads or {}
  section("Reviews and comments", tostring(#reviews + #comments + #threads))
  local function body_lines(text, indent)
    for _, line in ipairs(vim.split(vim.trim((text or ""):gsub("\r", "")), "\n", { plain = true })) do
      line = line == "" and "" or indent .. line
      local r = add(line)
      local spans, conceals = look.markdown(line)
      for _, s in ipairs(spans) do
        marks[#marks + 1] = { r, s[1], s[2], s[3] }
      end
      for _, c in ipairs(conceals) do
        marks[#marks + 1] = { r, c[1], c[2], conceal = "" }
      end
    end
  end
  for _, review in ipairs(reviews) do
    local verdict = REVIEW[review.state] or { (review.state or ""):lower(), "Comment" }
    local who = type(review.author) == "table" and review.author.login or "?"
    local r = add(("  %s  %s"):format(verdict[1], who))
    marks[#marks + 1] = { r, 2, 2 + #verdict[1], verdict[2] }
    if vim.trim(review.body or "") ~= "" then
      body_lines(review.body, "    ")
    end
  end
  for _, comment in ipairs(comments) do
    local who = type(comment.author) == "table" and comment.author.login or "?"
    local r = add(("  %s commented"):format(who))
    dim(r, 2 + #who, #lines[#lines])
    body_lines(comment.body, "    ")
  end
  for _, thread in ipairs(threads) do
    local where = ("%s:%s"):format(thread.path or "?", tostring(thread.line or thread.originalLine or "?"))
    local text_ = "  " .. where .. (thread.isResolved and "  resolved" or "")
    local r = add(text_, nil, thread.isResolved and ">2" or "1")
    marks[#marks + 1] = { r, 2, 2 + #where, "Directory" }
    dim(r, 2 + #where, #text_)
    local nodes = type(thread.comments) == "table" and thread.comments.nodes or {}
    for _, comment in ipairs(nodes) do
      local who = type(comment.author) == "table" and comment.author.login or "?"
      local first = add("    " .. who, "Bold", thread.isResolved and "2" or "1")
      local _ = first
      local before = #lines
      body_lines(comment.body, "      ")
      if thread.isResolved then
        for n = before + 1, #lines do
          levels[n] = "2"
        end
      end
    end
  end
  -- Files changed.
  local files = type(data.files) == "table" and data.files or {}
  local plus, minus = 0, 0
  for _, file in ipairs(files) do
    plus, minus = plus + (file.additions or 0), minus + (file.deletions or 0)
  end
  section("Files changed", ("%d  +%d −%d  <CR> a file's diff · c every file's"):format(#files, plus, minus))
  for _, file in ipairs(files) do
    local add_text, del_text = "+" .. (file.additions or 0), "−" .. (file.deletions or 0)
    local line = ("  %6s %6s  %s"):format(add_text, del_text, file.path or "?")
    local r = add(line)
    local a = line:find("+", 1, true)
    marks[#marks + 1] = { r, a - 1, a - 1 + #add_text, "DiffAdd" }
    local d = line:find("−", a + #add_text, true)
    marks[#marks + 1] = { r, d - 1, d - 1 + #del_text, "DiffDelete" }
    rows[r + 1] = { file = file.path }
  end
  return lines, marks, rows, levels
end

-- foldexpr: each line's level as render gave it.
function M.fold(lnum)
  local view = M.views[vim.b[vim.api.nvim_get_current_buf()].isovim_pr or ""]
  return view and view.levels and view.levels[lnum] or "0"
end

local function draw(view)
  if not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  local data = read_json(cache_file(view.repo, view.url))
  local lines, marks, rows, levels = render(view, data)
  view.rows, view.levels = rows, levels
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].modified = false
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, view.buf, NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4], conceal = mark.conceal })
  end
  -- What the fetch is doing, after the title: refreshing, or that gh couldn't (the cache stays).
  local note = view.refreshing and "  refreshing…" or view.failed and "  couldn't refresh · r tries again"
  if note and data then
    vim.api.nvim_buf_set_extmark(view.buf, NS, 0, 0, { virt_text = { { note, "Comment" } } })
  end
  -- Folds follow the new levels.
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("silent! normal! zx")
    end)
  end
  local icon, hl = require("isovim.prs").icon(data and { state = data.state, isDraft = data.isDraft } or {})
  vim.b[view.buf].isovim_tab = { name = ("#%d"):format(select(3, parts(view.url))), icon = icon, hl = hl }
  vim.cmd.redrawtabline()
end

-- Fetches the PR and its review threads in the background, writes the cache and draws it again.
function M.fetch(view)
  if fetching[view.url] then
    return
  end
  fetching[view.url], view.refreshing = true, true
  draw(view)
  local owner, name, number = parts(view.url)
  local pending, data, threads = 2, nil, nil
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    fetching[view.url], view.refreshing = nil, false
    view.failed = not data
    if data then
      data.threads = threads or (read_json(cache_file(view.repo, view.url)) or {}).threads
      vim.fn.mkdir(store.run_dir(view.repo), "p")
      vim.fn.writefile({ vim.json.encode(data) }, cache_file(view.repo, view.url))
    end
    draw(view)
  end
  local safe = require("isovim.safe")
  vim.system({ "gh", "pr", "view", view.url, "--json", FIELDS }, { text = true }, safe.schedule_wrap("fetching a PR", function(result)
    local ok, value = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    data = ok and type(value) == "table" and value or nil
    done()
  end))
  vim.system({ "gh", "api", "graphql", "-f", "query=" .. THREADS, "-F", "owner=" .. owner, "-F", "name=" .. name, "-F", "number=" .. number },
    { text = true }, safe.schedule_wrap("fetching a PR's threads", function(result)
      local ok, value = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
      local pr = ok and type(value) == "table" and vim.tbl_get(value, "data", "repository", "pullRequest", "reviewThreads", "nodes")
      threads = type(pr) == "table" and pr or nil
      done()
    end))
end

-- A scratch tab for text gh gives (a check's log, a diff): listed in the PR's scope, named for it.
local function text_tab(view, name, label, filetype, fill)
  local buf = vim.fn.bufnr(name)
  if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(true, true)
    vim.bo[buf].bufhidden = "wipe"
    pcall(vim.api.nvim_buf_set_name, buf, name)
    vim.bo[buf].filetype = filetype
    vim.b[buf].isovim_scope = view.repo
    vim.b[buf].isovim_tab = { name = label, icon = "\u{f407}", hl = "Special" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Fetching from GitHub…" })
    vim.bo[buf].modifiable = false
    fill(function(lines)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].modified = false
      end
    end)
  end
  require("isovim").show(buf)
end

-- A failed check's log: gh run view --log-failed, of its job when its link names one.
local function open_log(view, check)
  local run, job = (check.detailsUrl or ""):match("/actions/runs/(%d+)/job/(%d+)")
  run = run or (check.detailsUrl or ""):match("/actions/runs/(%d+)")
  if not run then
    return vim.notify("isovim: " .. (check.name or "that check") .. " isn't a GitHub Actions run; o opens the PR", vim.log.levels.WARN)
  end
  local owner, name, number = parts(view.url)
  local cmd = { "gh", "run", "view", run, "--log-failed", "-R", owner .. "/" .. name }
  if job then
    vim.list_extend(cmd, { "--job", job })
  end
  text_tab(view, ("isovim-pr-log://%s/%s/%d/%s"):format(owner, name, number, job or run), ("#%d %s log"):format(number, check.name or "check"), "log", function(set)
    vim.system(cmd, { text = true }, require("isovim.safe").schedule_wrap("fetching a check's log", function(result)
      set(vim.split(result.code == 0 and result.stdout or ("gh run view failed:\n" .. (result.stderr or "")), "\n", { plain = true }))
    end))
  end)
end

-- The PR's diff (gh pr diff, cached beside its data), or one file's part of it.
local function open_diff(view, path)
  local owner, name, number = parts(view.url)
  local label = path and ("#%d %s"):format(number, vim.fn.fnamemodify(path, ":t")) or ("#%d diff"):format(number)
  text_tab(view, ("isovim-pr-diff://%s/%s/%d/%s"):format(owner, name, number, path or ""), label, "diff", function(set)
    local function from(text)
      local lines = vim.split(text, "\n", { plain = true })
      if not path then
        return set(lines)
      end
      local out, inside = {}, false
      for _, line in ipairs(lines) do
        if line:match("^diff %-%-git ") then
          inside = line:find(" b/" .. path, 1, true) ~= nil
        end
        if inside then
          out[#out + 1] = line
        end
      end
      set(#out > 0 and out or { "No diff for " .. path })
    end
    vim.system({ "gh", "pr", "diff", view.url }, { text = true }, require("isovim.safe").schedule_wrap("fetching a PR's diff", function(result)
      from(result.code == 0 and result.stdout or ("gh pr diff failed:\n" .. (result.stderr or "")))
    end))
  end)
end

-- The view's keys, for its buffer and ? help: {lhs, what, fn(view, line)}.
M.keys = {
  { "<CR>", "on a failed check, its log; on a file, its diff", function(view, line)
    local row = view.rows and view.rows[line]
    if row and row.check and select(3, check_mark(row.check)) then
      open_log(view, row.check)
    elseif row and row.file then
      open_diff(view, row.file)
    end
  end },
  { "c", "every file's diff", function(view)
    open_diff(view, nil)
  end },
  { "o", "open the PR in the browser", function(view)
    vim.ui.open(view.url)
  end },
  { "y", "copy the PR's URL", function(view)
    vim.fn.setreg("+", view.url)
    vim.notify("Copied " .. view.url)
  end },
  { "a", "the chat of the agent that registered it", function(view)
    local ws, agent = ((store.pr_info(view.repo)[view.url] or {}).by or ""):match("^(.*)/([^/]+)$")
    if not ws then
      return vim.notify("isovim: no agent registered " .. view.url, vim.log.levels.WARN)
    end
    require("isovim").open(ws, agent)
  end },
  { "r", "fetch it again", function(view)
    M.fetch(view)
  end },
  { "za", "fold or open the section (vim's)" },
}

local function window(win)
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.breakindent, wo.breakindentopt = true, true, true, "shift:2"
  wo.number, wo.relativenumber, wo.signcolumn, wo.spell, wo.conceallevel, wo.list = false, false, "no", false, 2, false
  wo.foldmethod, wo.foldexpr, wo.foldtext, wo.foldlevel = "expr", "v:lua.require'isovim.pr_view'.fold(v:lnum)", "", 1
  wo.fillchars = "fold: ,eob: "
end

-- pr.<repo>.<n>.ci|review|state: an open view of that PR fetches again. One watch for the TUI's life.
local function watch()
  if _G.isovim_pr_view_watching then
    return
  end
  _G.isovim_pr_view_watching = true
  require("isovim.events").watch(function(_, event)
    if event.topic:match("^pr%.") and (event.topic:match("%.ci$") or event.topic:match("%.review$") or event.topic:match("%.state$")) then
      local view = require("isovim.pr_view").views[event.url or ""]
      if view and vim.api.nvim_buf_is_valid(view.buf) then
        require("isovim.pr_view").fetch(view)
      end
    end
  end)
end

-- Opens the PR registered under repo as its own tab: drawn from its cache at once, fetched again
-- in the background.
function M.open(repo, url)
  local view = M.views[url]
  if not (view and vim.api.nvim_buf_is_valid(view.buf)) then
    local owner, name, number = parts(url)
    if not owner then
      return vim.notify("isovim: not a PR: " .. tostring(url), vim.log.levels.WARN)
    end
    view = { repo = repo, url = url, rows = {}, levels = {} }
    view.buf = vim.api.nvim_create_buf(true, true)
    vim.bo[view.buf].bufhidden = "hide"
    vim.bo[view.buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, view.buf, ("isovim-pr://%s/%s/%d"):format(owner, name, number))
    vim.bo[view.buf].filetype = "isovim_pr"
    vim.b[view.buf].isovim_pr = url
    vim.b[view.buf].isovim_scope = repo
    vim.b[view.buf].isovim_surface = ("%s/#%d"):format(repo, number)
    for _, key in ipairs(M.keys) do
      if key[3] then
        vim.keymap.set("n", key[1], function()
          key[3](view, vim.api.nvim_win_get_cursor(0)[1])
        end, { buffer = view.buf, nowait = true, desc = "isovim: " .. key[2] })
      end
    end
    vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = view.buf,
      callback = function()
        window(vim.api.nvim_get_current_win())
      end,
    })
    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = view.buf,
      callback = function()
        M.views[url] = nil
      end,
    })
    M.views[url] = view
  end
  view.repo = repo
  draw(view)
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    win = require("isovim").show(view.buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  window(win)
  vim.cmd("silent! normal! zx")
  watch()
  M.fetch(view)
  return view
end

return M
