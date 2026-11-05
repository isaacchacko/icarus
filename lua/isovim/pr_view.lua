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
local boxes = require("isovim.boxes")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_pr_view")
local FIELDS = "number,title,state,isDraft,author,baseRefName,headRefName,mergeable,body,createdAt,url,statusCheckRollup,reviews,files,comments"
local THREADS = [[query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100) { nodes { isResolved path line originalLine
      comments(first: 50) { nodes { author { login } body createdAt } } } } } } }]]

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

local highlights = boxes.highlights

local G = {
  description = "\u{f405}", -- oct-book
  checks = "\u{f45e}", -- oct-checklist
  reviews = "\u{f442}", -- oct-comment-discussion
  files = "\u{f440}", -- oct-diff
  person = "\u{f415}", -- oct-person
  branch = "\u{f418}", -- oct-git-branch
  robot = "\u{f06a9}", -- md-robot
  clock = "\u{f43a}", -- oct-clock
  check = "\u{f42e}", -- oct-check
  warn = "\u{f071}", -- fa-warning
}

local FAILED = { FAILURE = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true, STARTUP_FAILURE = true, ERROR = true }

-- A check's glyph and color, and whether it failed.
local function check_mark(check)
  local done = check.status == "COMPLETED" or (check.state and check.state ~= "PENDING" and check.state ~= "EXPECTED")
  local verdict = check.conclusion or check.state
  if FAILED[verdict] then
    return "✗", "IsovimPrError", true
  elseif not done then
    return "●", "IsovimPrPending", false
  elseif verdict == "SUCCESS" then
    return "✓", "IsovimPrOk", false
  end
  return "–", "IsovimPrDim", false
end

local REVIEW = {
  APPROVED = { "approved", "IsovimPrOk" },
  CHANGES_REQUESTED = { "changes requested", "IsovimPrError" },
  COMMENTED = { "commented", "IsovimPrDim" },
  DISMISSED = { "dismissed", "IsovimPrDim" },
}

-- Lines with their highlights, boxes and markdown in them: isovim.boxes, shared with threads.
local seg, cat, cells, fit = boxes.seg, boxes.cat, boxes.cells, boxes.fit
local top, bottom, side, markdown = boxes.top, boxes.bottom, boxes.side, boxes.markdown

-- How long ago a time of gh's was, if it has one.
local function ago(at)
  return at and span(at) or nil
end

-- The view's lines, highlights {row, col, end_col, hl}, what each line is and each line's fold level:
-- the banner at 0; a section's box opening its fold, so a folded one shows its top line; a resolved
-- thread a fold inside it, closed. width: the window's.
local function render(view, data, width)
  local lines, marks, rows, levels = {}, {}, {}, {}
  local function add(line, level, row)
    lines[#lines + 1] = line.text
    levels[#lines] = level or "1"
    rows[#lines] = row
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3], mark[4], mark[5] }
    end
  end
  width = math.max(48, width - 1)
  local inner = width - 4
  if not data then
    add(seg(("#%d"):format(select(3, parts(view.url))), "IsovimPrTitle"), "0")
    add(seg(view.refreshing and "Fetching from GitHub…" or "gh gave nothing for it: r tries again.", "IsovimPrDim"), "0")
    return lines, marks, rows, levels
  end
  -- A section: its box, title bold after its glyph, its counts dim in the top border; level 1.
  local function section(glyph, title, counts, body, note)
    add(seg(""), "0")
    add(top(width, cat(seg(glyph .. " " .. title, "IsovimPrTitle"), seg(counts and ("  " .. counts) or "", "IsovimPrDim"))), ">1")
    for _, line in ipairs(body) do
      add(side(width, line.line or line), line.level or "1", line.row or (line.image and { image = line.image }))
    end
    add(bottom(width, note), "1")
  end

  -- The banner: the state as a pill, #n and the title bold, then a dim line of facts with glyphs.
  local state = data.isDraft and data.state == "OPEN" and "draft" or (data.state or "?"):lower()
  local pill = ({ open = "IsovimPrPillOpen", draft = "IsovimPrPillDraft", merged = "IsovimPrPillMerged", closed = "IsovimPrPillClosed" })[state] or "IsovimPrPillDraft"
  add(cat(seg(" " .. state .. " ", pill), seg(" "), seg(("#%d"):format(data.number or 0), "IsovimPrTitle"), seg(" "), seg(data.title or "", "IsovimPrTitle")), "0")
  local facts = {}
  local function fact(glyph, text, hl)
    if #facts > 0 then
      facts[#facts + 1] = seg("  ·  ", "IsovimPrDim")
    end
    facts[#facts + 1] = cat(seg(glyph .. " ", hl or "IsovimPrDim"), seg(text, hl or "IsovimPrDim"))
  end
  if type(data.author) == "table" and data.author.login then
    fact(G.person, data.author.login)
  end
  if data.baseRefName then
    fact(G.branch, ("%s ← %s"):format(data.baseRefName, data.headRefName or "?"))
  end
  local by = ((store.pr_info(view.repo)[view.url] or {}).by or "")
  local ws, agent = by:match("^(.*)/([^/]+)$")
  if ws then
    local spec = store.agent(ws, agent)
    fact(G.robot, spec and spec.name or agent)
  end
  if ago(data.createdAt) then
    fact(G.clock, ago(data.createdAt))
  end
  if data.state == "OPEN" and data.mergeable == "MERGEABLE" then
    fact(G.check, "mergeable", "IsovimPrOk")
  elseif data.state == "OPEN" and data.mergeable == "CONFLICTING" then
    fact(G.warn, "conflicts", "IsovimPrError")
  end
  add(cat(seg(" "), cat(unpack(facts))), "0")

  -- Description.
  local description = markdown(data.body, inner)
  if #description == 0 or (#description == 1 and description[1].text == "") then
    description = { seg("No description.", "IsovimPrDim") }
  end
  section(G.description, "Description", nil, description)

  -- Checks: failed first, then running, then the rest; names aligned, durations at the right.
  local checks = vim.deepcopy(type(data.statusCheckRollup) == "table" and data.statusCheckRollup or {})
  local order = { ["✗"] = 0, ["●"] = 1 }
  local counts = { ["✓"] = 0, ["✗"] = 0, ["●"] = 0 }
  for i, check in ipairs(checks) do
    check.glyph, check.hl, check.failed = check_mark(check)
    check.name_ = (check.workflowName and check.workflowName ~= "" and check.workflowName ~= (check.name or check.context))
      and (check.workflowName .. " / " .. (check.name or "?")) or (check.name or check.context or "?")
    check.i = i
    counts[check.glyph] = (counts[check.glyph] or 0) + 1
  end
  table.sort(checks, function(a, b)
    local oa, ob = order[a.glyph] or 2, order[b.glyph] or 2
    return oa ~= ob and oa < ob or (oa == ob and a.i < b.i)
  end)
  local body, name_width, took_width = {}, 0, 0
  for _, check in ipairs(checks) do
    check.took = span(check.startedAt, check.completedAt) or ""
    name_width = math.max(name_width, vim.fn.strdisplaywidth(check.name_))
    took_width = math.max(took_width, #check.took)
  end
  for _, check in ipairs(checks) do
    local name = seg(check.name_, check.failed and "IsovimPrTitle" or nil)
    local gap = name_width - cells(name) + 3 + took_width - #check.took
    body[#body + 1] = {
      line = cat(seg(check.glyph, check.hl), seg(" "), name, seg((" "):rep(gap)), seg(check.took, "IsovimPrDim")),
      row = { check = check },
    }
  end
  if #body == 0 then
    body = { seg("No checks.", "IsovimPrDim") }
  end
  section(G.checks, "Checks", #checks > 0 and ("%d✓ %d✗ %d●"):format(counts["✓"], counts["✗"], counts["●"]) or nil, body,
    counts["✗"] > 0 and "<CR> on a failed one opens its log" or nil)

  -- Reviews and comments, each in a small box; then the inline threads, each boxed under its
  -- file:line, replies on a │ rail; a resolved one folded to a dim line.
  local reviews = vim.tbl_filter(function(review)
    return review.state ~= "PENDING" and (review.state ~= "COMMENTED" or vim.trim(review.body or "") ~= "")
  end, type(data.reviews) == "table" and data.reviews or {})
  local comments = type(data.comments) == "table" and data.comments or {}
  local threads = type(data.threads) == "table" and data.threads or {}
  body = {}
  local box = inner
  local function small(title, text, level)
    body[#body + 1] = { line = top(box, title), level = level }
    for _, line in ipairs(text and vim.trim(text) ~= "" and markdown(text, box - 4) or {}) do
      body[#body + 1] = { line = side(box, line), level = level, row = line.image and { image = line.image } }
    end
    body[#body + 1] = { line = bottom(box), level = level }
  end
  for _, review in ipairs(reviews) do
    local verdict = REVIEW[review.state] or { (review.state or ""):lower(), "IsovimPrDim" }
    local who = type(review.author) == "table" and review.author.login or "?"
    local title = cat(seg(who, "IsovimPrTitle"), seg(" · ", "IsovimPrDim"), seg(verdict[1], verdict[2]))
    if ago(review.submittedAt) then
      title = cat(title, seg(" · " .. ago(review.submittedAt), "IsovimPrDim"))
    end
    small(title, review.body)
  end
  for _, comment in ipairs(comments) do
    local who = type(comment.author) == "table" and comment.author.login or "?"
    local title = cat(seg(who, "IsovimPrTitle"), seg(" · commented", "IsovimPrDim"))
    if ago(comment.createdAt) then
      title = cat(title, seg(" · " .. ago(comment.createdAt), "IsovimPrDim"))
    end
    small(title, comment.body)
  end
  for _, thread in ipairs(threads) do
    local where = ("%s:%s"):format(thread.path or "?", tostring(thread.line or thread.originalLine or "?"))
    local nodes = type(thread.comments) == "table" and thread.comments.nodes or {}
    local level
    if thread.isResolved then
      body[#body + 1] = { line = cat(seg("✓ ", "IsovimPrOk"), seg(where, "IsovimPrDim"), seg(("  resolved · %d"):format(#nodes), "IsovimPrDim")), level = ">2" }
      level = "2"
    end
    body[#body + 1] = { line = top(box, seg(where, "IsovimPrLink")), level = level }
    for n, comment in ipairs(nodes) do
      local who = type(comment.author) == "table" and comment.author.login or "?"
      local head = seg(who, "IsovimPrTitle")
      if ago(comment.createdAt) then
        head = cat(head, seg(" · " .. ago(comment.createdAt), "IsovimPrDim"))
      end
      body[#body + 1] = { line = side(box, head), level = level }
      for _, line in ipairs(markdown(comment.body, box - 8)) do
        body[#body + 1] = { line = side(box, cat(seg("│ ", "IsovimPrBorder"), line)), level = level, row = line.image and { image = line.image } }
      end
      if n < #nodes then
        body[#body + 1] = { line = side(box, seg("")), level = level }
      end
    end
    body[#body + 1] = { line = bottom(box), level = level }
  end
  if #body == 0 then
    body = { seg("No reviews or comments.", "IsovimPrDim") }
  end
  section(G.reviews, "Reviews and comments", tostring(#reviews + #comments + #threads), body)

  -- Files: + and − right-aligned in their columns, a file-type glyph, the path.
  local files = type(data.files) == "table" and data.files or {}
  local plus, minus, wide_plus, wide_minus = 0, 0, 2, 2
  for _, file in ipairs(files) do
    plus, minus = plus + (file.additions or 0), minus + (file.deletions or 0)
    wide_plus = math.max(wide_plus, #tostring(file.additions or 0) + 1)
    wide_minus = math.max(wide_minus, #tostring(file.deletions or 0) + 1)
  end
  local ok_icons, icons = pcall(require, "mini.icons")
  body = {}
  for _, file in ipairs(files) do
    local add_text, del_text = "+" .. (file.additions or 0), "−" .. (file.deletions or 0)
    local glyph, glyph_hl = "\u{f15b}", "IsovimPrDim"
    if ok_icons then
      local got, icon, hl = pcall(icons.get, "file", file.path or "")
      if got then
        glyph, glyph_hl = icon, hl
      end
    end
    body[#body + 1] = {
      line = cat(seg((" "):rep(wide_plus - #tostring(file.additions or 0) - 1)), seg(add_text, "IsovimPrAdd"), seg(" "),
        seg((" "):rep(wide_minus - #tostring(file.deletions or 0) - 1)), seg(del_text, "IsovimPrDelete"), seg("  "),
        seg(glyph, glyph_hl), seg(" "), seg(file.path or "?")),
      row = { file = file.path },
    }
  end
  if #body == 0 then
    body = { seg("No files.", "IsovimPrDim") }
  end
  section(G.files, "Files changed", ("%d  +%d −%d"):format(#files, plus, minus), body, "<CR> a file's diff · c every file's")
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
  local win = vim.fn.bufwinid(view.buf)
  view.width = win ~= -1 and vim.api.nvim_win_get_width(win) or 100
  local lines, marks, rows, levels = render(view, data, view.width)
  view.rows, view.levels = rows, levels
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  -- Its iso: addresses (a description's, a comment's) as chips, <Tab> opening them (isovim.links).
  require("isovim.links").decorate(view.buf)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].modified = false
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  for _, mark in ipairs(marks) do
    if mark[5] then
      -- A link's chip (isovim.boxes put it there): which address it is, for <Tab> (isovim.links).
      require("isovim.links").register(view.buf, mark[1], mark[2], mark[3], mark[5], {}, mark[6])
    elseif mark[4] then
      pcall(vim.api.nvim_buf_set_extmark, view.buf, NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
    end
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
  { "<CR>", "on a failed check, its log; on a file, its diff; on an image, the image", function(view, line)
    local row = view.rows and view.rows[line]
    if row and row.image then
      require("isovim.image").open(row.image, view.repo)
    elseif row and row.check and select(3, check_mark(row.check)) then
      open_log(view, row.check)
    elseif row and row.file then
      open_diff(view, row.file)
    end
  end },
  { "c", "every file's diff", function(view)
    open_diff(view, nil)
  end },
  { "o", "open the PR in the browser; on another PR's link, its view here", function(view)
    if not require("isovim.links").secondary() then
      vim.ui.open(view.url)
    end
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
  -- Drawn to the window's width, boxes and all: no wrapping (a resize draws it again).
  wo.wrap, wo.sidescrolloff = false, 0
  wo.number, wo.relativenumber, wo.signcolumn, wo.spell, wo.conceallevel, wo.list = false, false, "no", false, 2, false
  wo.foldmethod, wo.foldexpr, wo.foldtext, wo.foldlevel = "expr", "v:lua.require'isovim.pr_view'.fold(v:lnum)", "", 1
  wo.fillchars = "fold: ,eob: "
end

-- A view's window resized: drawn again to its width.
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("isovim_pr_view_resize", { clear = true }),
  callback = function()
    for _, view in pairs(M.views) do
      local win = vim.api.nvim_buf_is_valid(view.buf) and vim.fn.bufwinid(view.buf) or -1
      if win ~= -1 and vim.api.nvim_win_get_width(win) ~= view.width then
        require("isovim.safe").wrap("drawing a PR", draw)(view)
      end
    end
  end,
})

-- pr.<repo>.<n>.ci|review|state: an open view of that PR fetches again. One watch for the TUI's life.
local function watch()
  if _G.isovim_pr_view_watching then
    return
  end
  _G.isovim_pr_view_watching = true
  require("isovim.events").watch(function(_, event)
    if event.topic:match("^pr%.") and (event.topic:match("%.ci$") or event.topic:match("%.review$") or event.topic:match("%.state$")) then
      local view = require("isovim.pr_view").views[(event.url or ""):lower()]
      if view and vim.api.nvim_buf_is_valid(view.buf) then
        require("isovim.pr_view").fetch(view)
      end
    end
  end)
end

-- Opens the PR registered under repo as its own tab: drawn from its cache at once, fetched again
-- in the background.
function M.open(repo, url)
  url = url:lower()
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
    require("isovim.links").attach(view.buf)
    vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = view.buf,
      callback = function()
        window(vim.api.nvim_get_current_win())
      end,
    })
    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = view.buf,
      callback = function()
        -- Not when its project stops being current and isovim.scope unlists it, which leaves it loaded.
        require("isovim.safe").schedule("closing a PR's view", function()
          if not vim.api.nvim_buf_is_loaded(view.buf) then
            M.views[url] = nil
          end
        end)
      end,
    })
    M.views[url] = view
  end
  view.repo = repo
  highlights()
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
