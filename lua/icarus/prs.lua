-- The pull requests a task is working on, and the Linear tickets each is for. Found three ways: the
-- branch of every git worktree under the task's folder (its agents'), the GitHub PR links in its
-- task.md's links, and the PRs its agents opened (gh pr create, in their transcripts); each looked
-- up with gh for its state, draft, review, checks and body. A ticket is an id like ABC-123 in the
-- PR's branch, title or body, or a linear.app link in its body. Fetched in the background and kept
-- for a few minutes; shown under task.md's header (icarus.head) and in the board's <Tab>.
local tasks = require("icarus.tasks")

local M = {}

local FRESH = 300
local FIELDS = "number,title,url,state,isDraft,reviewDecision,headRefName,body,statusCheckRollup"
-- Upper-case words that look like ticket ids and aren't.
local NOT_TICKETS = { UTF = true, SHA = true, ISO = true, RFC = true, HTTP = true, TLS = true }

-- In _G, so a hot reload keeps what's been fetched.
_G.icarus_prs = _G.icarus_prs or {}
local cache = _G.icarus_prs ---@type table<string, {at: integer, prs?: table[], waiting?: function[]}>

local function repo_of(dir)
  local url = vim.trim(vim.fn.system({ "git", "-C", dir, "remote", "get-url", "origin" }))
  return url:match("github%.com[:/]([%w%-%._]+/[%w%-%._]-)%.git$") or url:match("github%.com[:/]([%w%-%._]+/[%w%-%._]+)$")
end

-- The worktrees under the task's folder, as {repo, branch}.
local function branches(slug)
  local out = {}
  for name, kind in vim.fs.dir(tasks.dir(slug), { depth = 4 }) do
    if name:match("/%.git$") or name == ".git" then
      local dir = tasks.dir(slug) .. "/" .. vim.fs.dirname(name)
      local branch = vim.trim(vim.fn.system({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }))
      local repo = vim.v.shell_error == 0 and repo_of(dir)
      if repo and branch ~= "" and branch ~= "HEAD" and branch ~= "main" and branch ~= "master" then
        out[#out + 1] = { repo = repo, branch = branch }
      end
      local _ = kind
    end
  end
  return out
end

-- PR links in the task's links and its agents' transcripts.
local function linked(slug)
  local urls, seen = {}, {}
  local function add(text)
    for url in text:gmatch("https://github%.com/[%w%-%._]+/[%w%-%._]+/pull/%d+") do
      if not seen[url] then
        seen[url] = true
        urls[#urls + 1] = url
      end
    end
  end
  local task = tasks.read(slug)
  for _, link in ipairs(task and task.links or {}) do
    add(link)
  end
  -- From a chat, only the PRs its agent opened: what its `gh pr create` calls answered, not every
  -- PR it happened to mention.
  local base = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
  for _, record in ipairs(require("icarus.chats").on_task(slug)) do
    local path = record.session and ("%s/projects/%s/%s.jsonl"):format(base, (record.cwd:gsub("[^%w]", "-")), record.session)
    if path and vim.fn.filereadable(path) == 1 then
      local creates = {}
      for line in io.lines(path) do
        if line:find("gh pr create", 1, true) or line:find("tool_result", 1, true) then
          local ok, entry = pcall(vim.json.decode, line)
          local content = ok and type(entry) == "table" and type(entry.message) == "table" and entry.message.content
          for _, block in ipairs(type(content) == "table" and content or {}) do
            if type(block) == "table" and block.type == "tool_use" and type(block.input) == "table"
              and type(block.input.command) == "string" and block.input.command:find("gh pr create", 1, true) then
              creates[block.id] = true
            elseif type(block) == "table" and block.type == "tool_result" and creates[block.tool_use_id] then
              add(vim.json.encode(block.content))
            end
          end
        end
      end
    end
  end
  return urls
end

local function checks(rollup)
  local failed, pending, any = false, false, false
  for _, check in ipairs(type(rollup) == "table" and rollup or {}) do
    any = true
    local result = check.conclusion ~= vim.NIL and check.conclusion or check.state or check.status
    if result == "FAILURE" or result == "ERROR" or result == "TIMED_OUT" or result == "ACTION_REQUIRED" then
      failed = true
    elseif result == "PENDING" or result == "IN_PROGRESS" or result == "QUEUED" or result == "EXPECTED" then
      pending = true
    end
  end
  return not any and "" or failed and "failing" or pending and "running" or "passing"
end

local function tickets(pr)
  local found, seen = {}, {}
  local function add(id, url)
    id = id:upper()
    if not seen[id] then
      seen[id] = true
      found[#found + 1] = { id = id, url = url }
    elseif url then
      for _, each in ipairs(found) do
        if each.id == id then
          each.url = each.url or url
        end
      end
    end
  end
  local body = type(pr.body) == "string" and pr.body or ""
  for url, id in body:gmatch("(https://linear%.app/[%w%-]+/issue/(%w+%-%d+)[%w%-/]*)") do
    add(id, url)
  end
  for _, text in ipairs({ pr.headRefName or "", pr.title or "", body }) do
    for prefix, num in text:gmatch("%f[%w](%a%a%a?%a?)%-(%d%d+)%f[^%w]") do
      if (text ~= pr.headRefName and prefix:match("^%u+$") or text == pr.headRefName) and not NOT_TICKETS[prefix:upper()] then
        add(prefix .. "-" .. num)
      end
    end
  end
  return found
end

-- A PR link's state, seen by any lookup: {state, draft, at}. In _G, so a hot reload keeps them.
_G.icarus_pr_states = _G.icarus_pr_states or {}
local states = _G.icarus_pr_states
local GLYPHS = {
  OPEN = { "\u{f407}", "IcarusPrOpen" },
  DRAFT = { "\u{f4dd}", "IcarusPrDraft" },
  MERGED = { "\u{f419}", "IcarusPrMerged" },
  CLOSED = { "\u{f4dc}", "IcarusPrClosed" },
}
local MAX_LOOKUPS = 4
local looking, waiting = 0, {}

vim.api.nvim_set_hl(0, "IcarusPrOpen", { fg = "#98c379", default = true })
vim.api.nvim_set_hl(0, "IcarusPrDraft", { fg = "#7f848e", default = true })
vim.api.nvim_set_hl(0, "IcarusPrMerged", { fg = "#c678dd", default = true })
vim.api.nvim_set_hl(0, "IcarusPrClosed", { fg = "#e06c75", default = true })

local function remember(url, state, draft)
  states[url] = { state = state, draft = draft, at = os.time() }
end

local function look_up()
  while looking < MAX_LOOKUPS and #waiting > 0 do
    local url = table.remove(waiting, 1)
    looking = looking + 1
    vim.system({ "gh", "pr", "view", url, "--json", "state,isDraft" }, { text = true, timeout = 30000 }, vim.schedule_wrap(function(result)
      looking = looking - 1
      local ok, pr = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
      if ok and type(pr) == "table" and pr.state then
        remember(url, pr.state, pr.isDraft)
        require("icarus.links").relabel_all()
      end
      look_up()
    end))
  end
end

-- What a PR link starts with, {glyph, group}: its state's, or open's dimmed until it's known. Looks
-- up one it doesn't know, or an open one gone stale, and the labels are drawn again when it's in.
function M.glyph(url)
  url = url:match("^https://github%.com/[^/]+/[^/]+/pull/%d+") or url
  local known = states[url]
  local final = known and (known.state == "MERGED" or known.state == "CLOSED")
  if not final and (not known or os.time() - known.at >= FRESH) then
    -- Asked once a while, found or not, as drawing asks often.
    known = known or { at = 0 }
    known.at = os.time()
    states[url] = known
    waiting[#waiting + 1] = url
    look_up()
  end
  if not known.state then
    return { GLYPHS.OPEN[1], "IcarusLinkMark" }
  end
  return GLYPHS[known.state == "OPEN" and known.draft and "DRAFT" or known.state] or GLYPHS.OPEN
end

local function shape(pr)
  remember(pr.url, pr.state, pr.isDraft)
  return { number = pr.number, title = pr.title, url = pr.url, state = pr.state, draft = pr.isDraft,
    review = pr.reviewDecision ~= vim.NIL and pr.reviewDecision or "", checks = checks(pr.statusCheckRollup),
    branch = pr.headRefName, tickets = tickets(pr) }
end

-- Looks the task's PRs up, then done(prs).
local function fetch(slug, done)
  local found, seen, left = {}, {}, 0
  local function keep(pr)
    if pr and pr.url and not seen[pr.url] then
      seen[pr.url] = true
      found[#found + 1] = shape(pr)
    end
  end
  local function finish()
    left = left - 1
    if left == 0 then
      table.sort(found, function(a, b)
        return a.number > b.number
      end)
      done(found)
    end
  end
  local jobs = {}
  for _, each in ipairs(branches(slug)) do
    jobs[#jobs + 1] = { "gh", "pr", "list", "--repo", each.repo, "--head", each.branch, "--state", "all", "--json", FIELDS }
  end
  for _, url in ipairs(linked(slug)) do
    jobs[#jobs + 1] = { "gh", "pr", "view", url, "--json", FIELDS }
  end
  left = #jobs
  if left == 0 then
    return done({})
  end
  for _, cmd in ipairs(jobs) do
    vim.system(cmd, { text = true, timeout = 30000 }, vim.schedule_wrap(function(result)
      local ok, decoded = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
      if ok and type(decoded) == "table" then
        if decoded.url then
          keep(decoded)
        else
          for _, pr in ipairs(decoded) do
            keep(pr)
          end
        end
      end
      finish()
    end))
  end
end

-- The task's PRs to done(prs): kept ones while they're fresh, else looked up (once, however many
-- ask meanwhile). force looks up again.
function M.get(slug, done, force)
  local kept = cache[slug]
  if kept and kept.prs and not force and os.time() - kept.at < FRESH then
    return done(kept.prs)
  end
  if kept and kept.waiting then
    table.insert(kept.waiting, done)
    return
  end
  cache[slug] = { at = os.time(), prs = kept and kept.prs, waiting = { done } }
  fetch(slug, function(prs)
    local waiting = cache[slug].waiting
    cache[slug] = { at = os.time(), prs = prs }
    for _, each in ipairs(waiting) do
      pcall(each, prs)
    end
  end)
end

-- What was last fetched for the task, without fetching.
function M.kept(slug)
  return cache[slug] and cache[slug].prs
end

-- The PRs as markdown lines, each a link to its PR and its tickets', and {row, from, to, group}
-- spans for the rest: what a buffer shows them as (the task's PR window, the board's preview).
---@return string[] lines, table[] spans
function M.lines(prs)
  if #prs == 0 then
    return { "no PRs found for this task" }, { { 0, 0, -1, "Comment" } }
  end
  local lines, spans = {}, {}
  for _, pr in ipairs(prs) do
    local line = ("[#%d %s](%s)"):format(pr.number, pr.title:gsub("[%[%]]", ""), pr.url)
    local check = ({ passing = "✓", failing = "✗", running = "…" })[pr.checks]
    local row = #lines
    if check then
      local from = #line + 2
      line = line .. "  " .. check
      spans[#spans + 1] = { row, from, #line, ({ ["✓"] = "DiagnosticOk", ["✗"] = "DiagnosticError", ["…"] = "DiagnosticWarn" })[check] }
    end
    local notes = {}
    if pr.state ~= "OPEN" then
      notes[#notes + 1] = pr.state:lower()
    elseif pr.draft then
      notes[#notes + 1] = "draft"
    end
    if pr.state == "OPEN" and pr.review ~= "" then
      notes[#notes + 1] = (pr.review:lower():gsub("_", " "))
    end
    if #notes > 0 then
      local from = #line + 2
      line = line .. "  " .. table.concat(notes, " · ")
      spans[#spans + 1] = { row, from, #line, "Comment" }
    end
    for _, ticket in ipairs(pr.tickets) do
      line = line .. "  " .. (ticket.url and ("[%s](%s)"):format(ticket.id, ticket.url) or ticket.id)
    end
    lines[#lines + 1] = line
  end
  return lines, spans
end

local STATE_HL = { OPEN = "DiagnosticInfo", MERGED = "IcarusGraphTitle", CLOSED = "Comment" }
local CHECK = { passing = { "✓", "DiagnosticOk" }, failing = { "✗", "DiagnosticError" }, running = { "…", "DiagnosticWarn" } }

-- The PRs as rows of {text, group} chunks, for a header's virtual lines or a buffer's lines.
---@param with_urls? boolean the PR's and tickets' links on rows of their own
function M.rows(prs, with_urls)
  local rows = {}
  if #prs == 0 then
    return { { { "no PRs found for this task", "Comment" } } }
  end
  for _, pr in ipairs(prs) do
    local row = { { ("#%d "):format(pr.number), STATE_HL[pr.state] or "Normal" } }
    local check = CHECK[pr.checks]
    if check then
      row[#row + 1] = { check[1] .. " ", check[2] }
    end
    local notes = {}
    if pr.state ~= "OPEN" then
      notes[#notes + 1] = pr.state:lower()
    elseif pr.draft then
      notes[#notes + 1] = "draft"
    end
    if pr.state == "OPEN" and pr.review ~= "" then
      notes[#notes + 1] = pr.review:lower():gsub("_", " ")
    end
    row[#row + 1] = { pr.title, "Normal" }
    if #notes > 0 then
      row[#row + 1] = { "  " .. table.concat(notes, " · "), "Comment" }
    end
    if #pr.tickets > 0 then
      row[#row + 1] = { "  " .. table.concat(vim.tbl_map(function(t)
        return t.id
      end, pr.tickets), " "), "IcarusLinkIcarus" }
    end
    rows[#rows + 1] = row
    if with_urls then
      rows[#rows + 1] = { { "    " .. pr.url, "IcarusLink" } }
      for _, ticket in ipairs(pr.tickets) do
        if ticket.url then
          rows[#rows + 1] = { { "    " .. ticket.url, "IcarusLink" } }
        end
      end
    end
  end
  return rows
end

return M
