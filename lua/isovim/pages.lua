-- Pages: markdown a router writes for the user to read and comment on, as design docs are. A page
-- is iso/pages/<name>.md in a repo's iso/ (optional frontmatter as a markdown surface's: name,
-- icon, color), shown read-only as rendered markdown (isovim.surface_view, kind "page"), a plain
-- row under its repo with how many comments are open.
--
-- A page holds no state of its own: comments live beside it, in iso/pages/<name>.comments.jsonl, a
-- comment a line: {id (c1, c2...), quote (the lines it's on, as the page said then), from, to (their
-- lines in the file), heading (the headings above them, "A › B"), text, by, at, status (open or
-- resolved), replies: [{by, text, at, ask?}], resolved_by?, resolved_at?, note?}. A comment the user
-- writes goes to the repo's router as a prompt (iso send), which changes the page wherever the
-- comment asks and resolves it (iso <role> page resolve) with a note of what changed, or replies
-- (iso <role> page reply), --ask for a reply that asks the user something: that page waits on them
-- (needs_you, in the Inbox) until they reply. Their reply goes to the router too.
--
-- In the view an open comment shows where its quote is now, found again by its text after the page
-- changes (the closest match to where it was, then its first line alone, then its heading, else
-- the line it was on): a sign beside its lines and, under them, a dim line with its first line and
-- how many replies, or all of it and its replies once opened (<CR> on it). Keys: c comments on the
-- line, or on the lines selected (v, V; <CR> too), in the input box under the page; a replies to
-- the comment under the cursor; ]c [c go to the next and previous comment; r shows the resolved
-- ones too, dimmed, or hides them again.
--
-- Dives: a page leads to pages beneath it. [? question] anywhere in a page's file (not in a code
-- fence or span, so a page can talk about the syntax) asks for one: i writes it, or you edit it in, and
-- each is sent to the router once as a prompt ([page dive ...]); pages/<name>.dives.jsonl beside the
-- page keeps what's been sent: {id (d1, d2...), question, quote?, status (unsent, sent or answered),
-- child?, line, heading, by, at}. The router writes the child and runs iso <role> page dive, which
-- sets parent: in its frontmatter and puts a link to it in place of the blurb. [[ goes up to the
-- parent, ]] back down, and a breadcrumb sits over a page with a parent. isovim.surfaces works out
-- parents (one whose parent is gone is top-level) and how many are beneath each.
--
-- Signs of life: what the router is doing about a comment or dive shows on its line, live. It's in
-- run/<repo>/page-activity.json, {page = {id = {state, at, doing?, worker?, told_of?, told_at?}}}, written
-- only as a state changes: queued as the TUI sends it, turn as the router's supervisor delivers it
-- (doing, its current tool, as those start), ended as that turn ends, with no answer. worker while iso
-- <role> page waiting says it's with one. An answer (a reply, a resolve, the dive) takes it out.
local surfaces = require("isovim.surfaces")
local store = require("isovim.store")

local M = {}

M.dirname = "pages"

function M.dir(repo)
  return surfaces.dir(repo) .. "/" .. M.dirname
end

function M.file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".md"
end

function M.comments_file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".comments.jsonl"
end

function M.dives_file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".dives.jsonl"
end

---@class isovim.PageComment
---@field id string
---@field quote string
---@field from integer
---@field to integer
---@field heading string
---@field text string
---@field by string
---@field at number
---@field status "open"|"resolved"
---@field replies {by: string, text: string, at: number, ask?: boolean}[]
---@field resolved_by? string
---@field resolved_at? number
---@field note? string

-- A page's comments, oldest first, and the file's text (the page's signature takes it in).
---@return isovim.PageComment[] comments, string text
function M.comments(repo, name)
  local file = io.open(M.comments_file(repo, name), "rb")
  local text = file and file:read("*a") or ""
  if file then
    file:close()
  end
  local list = {}
  for line in text:gmatch("[^\n]+") do
    local ok, comment = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(comment) == "table" and type(comment.id) == "string" then
      comment.replies = type(comment.replies) == "table" and comment.replies or {}
      list[#list + 1] = comment
    end
  end
  return list, text
end

-- Whether the comment waits on the user: its last reply asked them something.
function M.waiting(comment)
  local last = comment.replies[#comment.replies]
  return comment.status == "open" and last ~= nil and last.ask == true and last.by ~= "user"
end

-- What the page's row and the Inbox go by: how many comments are open, how many wait on the user.
function M.summary(comments)
  local open, waiting = 0, 0
  for _, comment in ipairs(comments) do
    if comment.status == "open" then
      open = open + 1
      waiting = waiting + (M.waiting(comment) and 1 or 0)
    end
  end
  return open, waiting
end

-- Writes text to path whole (a temp file renamed over).
local function write_whole(path, text)
  local tmp = ("%s/.%s.%d.tmp"):format(vim.fs.dirname(path), vim.fs.basename(path), vim.uv.os_getpid())
  local file = assert(io.open(tmp, "wb"))
  file:write(text)
  file:close()
  assert(vim.uv.fs_rename(tmp, path))
end

local function write_lines(path, list)
  local lines = vim.tbl_map(vim.json.encode, list)
  write_whole(path, #lines > 0 and table.concat(lines, "\n") .. "\n" or "")
end

-- Changes the page's comments with fn(comments) under the repo's surface lock, written whole; returns
-- what fn returns.
local function update(repo, name, fn)
  return surfaces.locked(repo, function()
    local list = M.comments(repo, name)
    local result, err = fn(list)
    if result == nil then
      return nil, err
    end
    write_lines(M.comments_file(repo, name), list)
    return result
  end)
end

local function find(list, id)
  for _, comment in ipairs(list) do
    if comment.id == id then
      return comment
    end
  end
end

-- A new comment on the page; returns it.
---@param spec {quote: string, from: integer, to: integer, heading: string, text: string}
---@return isovim.PageComment
function M.add(repo, name, spec, by)
  return update(repo, name, function(list)
    local n = 0
    for _, comment in ipairs(list) do
      n = math.max(n, tonumber(comment.id:match("^c(%d+)$")) or 0)
    end
    local comment = { id = "c" .. (n + 1), quote = spec.quote, from = spec.from, to = spec.to, heading = spec.heading,
      text = spec.text, by = by or "user", at = os.time(), status = "open", replies = {} }
    list[#list + 1] = comment
    return comment
  end)
end

-- A reply under comment id; ask: it asks the user something, so the page waits on them.
---@return isovim.PageComment? comment, string? err
function M.reply(repo, name, id, by, text, ask)
  local result, err = update(repo, name, function(list)
    local comment = find(list, id)
    if not comment then
      return nil, ("%s has no comment %s"):format(name, id)
    end
    comment.replies[#comment.replies + 1] = { by = by, text = text, at = os.time(), ask = ask or nil }
    return comment
  end)
  if result and by ~= "user" then
    M.set_activity(repo, name, id, nil)
  end
  return result, err
end

-- Resolves comment id, with a note of what changed; it leaves the page (r shows it again).
---@return isovim.PageComment? comment, string? err
function M.resolve(repo, name, id, by, note)
  local result, err = update(repo, name, function(list)
    local comment = find(list, id)
    if not comment then
      return nil, ("%s has no comment %s"):format(name, id)
    elseif comment.status == "resolved" then
      return nil, ("%s's %s is resolved already"):format(name, id)
    end
    comment.status, comment.resolved_by, comment.resolved_at, comment.note = "resolved", by, os.time(), note
    return comment
  end)
  if result then
    M.set_activity(repo, name, id, nil)
  end
  return result, err
end

-- Activity.

local function activity_file(repo)
  return store.run_dir(repo) .. "/page-activity.json"
end
M.ACTIVITY_NAME = "page-activity.json"

-- Every page's activity in the repo.
function M.activity(repo)
  local file = io.open(activity_file(repo), "rb")
  local ok, value = pcall(vim.json.decode, file and file:read("*a") or "")
  if file then
    file:close()
  end
  return ok and type(value) == "table" and value or {}
end

-- Changes what's known of item id on the page with fn(item), which returns what it is now (nil: gone).
local function change_activity(repo, name, id, fn)
  surfaces.locked(repo, function()
    local all = M.activity(repo)
    local page = all[name] or {}
    local before = page[id]
    page[id] = fn(before)
    if vim.deep_equal(before, page[id]) then
      return
    end
    all[name] = next(page) and page or nil
    vim.fn.mkdir(store.run_dir(repo), "p")
    local path = activity_file(repo)
    if next(all) then
      write_whole(path, vim.json.encode(all))
    else
      os.remove(path)
    end
  end)
end

-- The item is in state now (queued, ended), or gone with nil.
function M.set_activity(repo, name, id, state, fields)
  change_activity(repo, name, id, function(item)
    return state and vim.tbl_extend("force", { state = state, at = os.time(), told_of = item and item.told_of,
      told_at = item and item.told_at }, fields or {}) or nil
  end)
end

-- The tagged prompt's item, as a supervisor delivers it: repo, page, id.
function M.tagged(text)
  local repo, name, id = (text or ""):match("^[^\n]-%[page %a+ ([^%s#]+)/([^/%s#]+)#(%w+)%]")
  return repo, name, id
end

-- The router's turn on the item started: forward from queued, or from a turn that failed and goes
-- again. One answered meanwhile, or handed to a worker, stays as it is.
function M.turn_started(repo, name, id)
  change_activity(repo, name, id, function(item)
    return item and item.state ~= "worker" and { state = "turn", at = os.time() } or item
  end)
end

-- What that turn is doing now, as a tool call starts.
function M.turn_doing(repo, name, id, doing)
  change_activity(repo, name, id, function(item)
    return item and item.state == "turn" and vim.tbl_extend("force", item, { doing = doing }) or item
  end)
end

-- That turn ended: if it's still marked as the turn's, it ended with no answer and nobody marked.
function M.turn_ended(repo, name, id)
  change_activity(repo, name, id, function(item)
    return item and item.state == "turn" and { state = "ended", at = os.time() } or item
  end)
end

-- iso <role> page waiting: the item is with a worker, or (none) with nobody.
---@return boolean? ok, string? err
function M.wait_on(repo, name, id, worker)
  local known = vim.iter(M.comments(repo, name)):any(function(each)
    return each.id == id
  end) or vim.iter(M.dives(repo, name)):any(function(each)
    return each.id == id
  end)
  if not known then
    return nil, ("%s has no comment or dive %s"):format(name, id)
  end
  change_activity(repo, name, id, function(item)
    if worker == "none" then
      return nil
    end
    return { state = "worker", worker = worker, at = os.time(), told_of = item and item.told_of, told_at = item and item.told_at }
  end)
  return true
end

-- A removed page's activity goes with it.
function M.forget_activity(repo, name)
  surfaces.locked(repo, function()
    local all = M.activity(repo)
    if all[name] then
      all[name] = nil
      write_whole(activity_file(repo), vim.json.encode(all))
    end
  end)
end

-- The items' states that are moving.
local MOVING = { queued = true, turn = true, worker = true }

-- How many of a page's items are moving.
function M.moving(page)
  local n = 0
  for _, item in pairs(page or {}) do
    n = n + (MOVING[item.state] and 1 or 0)
  end
  return n
end

-- From the router's supervisor: an item with a worker that has finished or gone says so, as a thread's
-- wait does (isovim.threads.sweep), once; then it has no answer yet.
function M.sweep(repo, say, busy, finished)
  for name, page in pairs(M.activity(repo)) do
    for id, item in pairs(page) do
      if item.state == "worker" and not busy() then
        local how = finished(item.worker, item.at, item.told_of == item.worker and item.told_at or nil)
        if how then
          change_activity(repo, name, id, function()
            return { state = "ended", at = os.time(), told_of = item.worker, told_at = os.time() }
          end)
          say(("[isovim] %s/%s#%s was with %s, which %s. Answer it, or mark it again with `iso router page waiting %s %s "
            .. "<agent>`, which then waits quietly until that worker does more."):format(repo, name, id, item.worker, how, name, id))
        end
      end
    end
  end
end

-- From the TUI: a prompt or a turn nothing will finish: a router dead mid-turn, or a queued prompt
-- dropped. It has no answer yet, as nothing's on it.
function M.end_stale(repo)
  local router = store.router(repo)
  local alive
  local ended = false
  for name, page in pairs(M.activity(repo)) do
    for id, item in pairs(page) do
      local age = os.time() - (item.at or 0)
      if (item.state == "turn" and age >= 15) or (item.state == "queued" and age >= 30) then
        if alive == nil then
          alive = router ~= nil and require("isovim.status").owner_state(router) == "working"
        end
        if not alive then
          M.set_activity(repo, name, id, "ended")
          ended = true
        end
      end
    end
  end
  return ended
end

-- Dives.

-- The page's dives, oldest first.
function M.dives(repo, name)
  local file = io.open(M.dives_file(repo, name), "rb")
  local text = file and file:read("*a") or ""
  if file then
    file:close()
  end
  local list = {}
  for line in text:gmatch("[^\n]+") do
    local ok, dive = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(dive) == "table" and type(dive.id) == "string" then
      list[#list + 1] = dive
    end
  end
  return list
end

-- Changes the page's dives with fn(dives), written only if it returns true.
local function update_dives(repo, name, fn)
  return surfaces.locked(repo, function()
    local list = M.dives(repo, name)
    if fn(list) then
      write_lines(M.dives_file(repo, name), list)
    end
  end)
end

local function next_dive(list)
  local n = 0
  for _, dive in ipairs(list) do
    n = math.max(n, tonumber(dive.id:match("^d(%d+)$")) or 0)
  end
  return "d" .. (n + 1)
end

-- The [? question]s in lines, outside code fences and spans and not a markdown link's text: {row
-- (1-based), from, to (byte columns, to exclusive), question}, in order.
function M.blurbs(lines)
  local found, fenced = {}, false
  for row, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced then
      local at = 1
      while true do
        local from = line:find("[?", at, true)
        if not from then
          break
        end
        local whole = line:match("^%b[]", from)
        local question = whole and whole:match("^%[%?%s+(.-)%s*%]$")
        local _, ticks = line:sub(1, from - 1):gsub("`", "")
        if question and question ~= "" and ticks % 2 == 0 and line:sub(from + #whole, from + #whole) ~= "(" then
          found[#found + 1] = { row = row, from = from - 1, to = from - 1 + #whole, question = question }
          at = from + #whole
        else
          at = from + 2
        end
      end
    end
  end
  return found
end

-- What the router is sent for a blurb, worded as a comment's is: the answer is a page.
function M.dive_prompt(repo, name, dive, lines, row)
  local around = {}
  for i = math.max(1, row - 2), math.min(#lines, row + 2) do
    around[#around + 1] = "> " .. lines[i]
  end
  local quote = dive.quote and ("\n\nAbout these lines:\n%s"):format(table.concat(vim.tbl_map(function(line)
    return "> " .. line
  end, vim.split(dive.quote, "\n", { plain = true })), "\n")) or ""
  return ("[page dive %s/%s#%s] on %sline %d of %s:\n%s%s\n\n%s\n\n(The user asks this inside the page, and the answer is a new "
    .. "page, not a chat reply: write it to %s/<child>.md, as deep as the question needs, then run iso <role> page dive %s %s "
    .. "<child>, which makes it this page's child and puts a link to it in place of their question. Nothing else need be said. "
    .. "Handing it to a worker? iso <role> page waiting %s %s <agent>|none shows them who has it.)")
    :format(repo, name, dive.id, dive.heading ~= "" and ('"' .. dive.heading .. '" ') or "", dive.line, M.file(repo, name),
      table.concat(around, "\n"), quote, dive.question, M.dir(repo), name, dive.id, name, dive.id)
end

-- Sends text to the repo's router with iso send; on failure, done(false, why).
local function send(repo, text, done)
  local reader = require("isovim.surface_view").reader(repo)
  if not reader then
    return done(false, repo .. " has no router to send to")
  end
  vim.system({ require("isovim.panes").bin, "send", reader, text }, { text = true }, vim.schedule_wrap(function(result)
    done(result.code == 0, vim.trim(result.stderr or ""))
  end))
end

-- Sends each blurb on the repo's pages not sent yet, the key's and a hand edit's alike. A rescan or a
-- restart finds it in the page's dives and leaves it. One written twice is two; one answered and
-- written again is new. A blurb taken out by hand has nothing left to show on.
function M.sync(repo, entries)
  if not require("isovim.surface_view").reader(repo) then
    return
  end
  local activity = M.activity(repo)
  for _, entry in ipairs(entries) do
    for id in pairs(entry.type == "page" and activity[entry.name] or {}) do
      local dive = id:match("^d%d+$") and vim.iter(M.dives(repo, entry.name)):find(function(each)
        return each.id == id
      end)
      if dive and not vim.iter(M.blurbs(vim.split(entry.body or "", "\n", { plain = true }))):any(function(each)
        return each.question == dive.question
      end) then
        M.set_activity(repo, entry.name, id, nil)
      end
    end
    if entry.type == "page" and entry.body and entry.body:find("[?", 1, true) then
      local lines = vim.split(entry.body, "\n", { plain = true })
      local blurbs = M.blurbs(lines)
      local sends = {}
      update_dives(repo, entry.name, function(list)
        local taken = {}
        for _, blurb in ipairs(blurbs) do
          local dive = vim.iter(list):find(function(each)
            return not taken[each.id] and each.status ~= "answered" and each.question == blurb.question
          end)
          if not dive then
            dive = { id = next_dive(list), question = blurb.question, status = "unsent", by = "user", at = os.time() }
            list[#list + 1] = dive
          end
          taken[dive.id] = true
          if dive.status == "unsent" then
            dive.status, dive.line = "sent", blurb.row + (entry.body_line or 1) - 1
            dive.heading = M.heading_at(lines, blurb.row)
            sends[#sends + 1] = { dive = dive, row = blurb.row }
          end
        end
        return #sends > 0
      end)
      for _, each in ipairs(sends) do
        M.set_activity(repo, entry.name, each.dive.id, "queued")
        send(repo, M.dive_prompt(repo, entry.name, each.dive, lines, each.row), function(ok, why)
          if not ok then
            M.set_activity(repo, entry.name, each.dive.id, nil)
            update_dives(repo, entry.name, function(list)
              for _, dive in ipairs(list) do
                if dive.id == each.dive.id then
                  dive.status = "unsent"
                  return true
                end
              end
            end)
            vim.notify(("isovim: %s's question is kept, but its router wasn't told: %s"):format(entry.name, why), vim.log.levels.WARN)
          end
        end)
      end
    end
  end
end

-- A page's parent, as its file says.
local function parent_of(repo, name)
  local file = io.open(M.file(repo, name), "rb")
  local text = file and file:read("*a") or ""
  if file then
    file:close()
  end
  if not text:match("^%-%-%-%s*\r?\n") then
    return nil
  end
  local block = text:match("^%-%-%-%s*\r?\n(.-)\n%-%-%-") or ""
  local parent = ("\n" .. block .. "\n"):match("\nparent:%s*([^\r\n]-)%s*\r?\n")
  return parent and parent ~= "" and parent:gsub('^"(.*)"$', "%1") or nil
end

-- A file's text with its frontmatter's parent set, and its name if it has none.
local function with_parent(text, parent, name)
  local lines = vim.split(text, "\n", { plain = true })
  local fields = { "parent: " .. parent }
  local close
  if lines[1] and lines[1]:match("^%-%-%-%s*\r?$") then
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*\r?$") then
        close = i
        break
      end
    end
  end
  if not close then
    fields[#fields + 1] = "name: " .. vim.json.encode(name)
    return "---\n" .. table.concat(fields, "\n") .. "\n---\n" .. text
  end
  local named = false
  for i = close - 1, 2, -1 do
    if lines[i]:match("^parent:") then
      table.remove(lines, i)
      close = close - 1
    elseif lines[i]:match("^name:") then
      named = true
    end
  end
  if not named then
    fields[#fields + 1] = "name: " .. vim.json.encode(name)
  end
  for i, field in ipairs(fields) do
    table.insert(lines, close + i - 1, field)
  end
  return table.concat(lines, "\n")
end

-- iso <role> page dive: child answers dive id of the page. It records the parent in the child and swaps
-- the blurb for a link. A note says if the blurb has gone from the page.
---@return string? address, string? err_or_note
function M.dive(repo, name, id, child)
  local dive = vim.iter(M.dives(repo, name)):find(function(each)
    return each.id == id
  end)
  if not dive then
    return nil, ("%s has no dive %s"):format(name, id)
  elseif dive.status == "answered" then
    return nil, ("%s's %s is answered already, by %s"):format(name, id, dive.child or "?")
  elseif child == name then
    return nil, "a page can't be its own child"
  elseif not vim.uv.fs_stat(M.file(repo, child)) then
    return nil, ("%s has no page %s: write %s first"):format(repo, child, M.file(repo, child))
  end
  local at, seen = name, {}
  while at and not seen[at] do
    if at == child then
      return nil, ("%s is above %s already: that would be a cycle"):format(child, name)
    end
    seen[at] = true
    at = parent_of(repo, at)
  end
  local address = ("iso:page/%s/%s"):format(repo, child)
  local note
  surfaces.locked(repo, function()
    local file = assert(io.open(M.file(repo, child), "rb"))
    local text = file:read("*a")
    file:close()
    write_whole(M.file(repo, child), with_parent(text, name, dive.question))
    file = assert(io.open(M.file(repo, name), "rb"))
    local lines = vim.split(file:read("*a"), "\n", { plain = true })
    file:close()
    local blurb = vim.iter(M.blurbs(lines)):find(function(each)
      return each.question == dive.question
    end)
    if blurb then
      local line = lines[blurb.row]
      lines[blurb.row] = line:sub(1, blurb.from) .. address .. line:sub(blurb.to + 1)
      write_whole(M.file(repo, name), table.concat(lines, "\n"))
    else
      note = ("its question isn't on %s any more, so nothing was replaced: link %s there yourself"):format(name, address)
    end
  end)
  update_dives(repo, name, function(list)
    for _, each in ipairs(list) do
      if each.id == id then
        each.status, each.child = "answered", child
        return true
      end
    end
  end)
  M.set_activity(repo, name, id, nil)
  return address, note
end

-- Anchoring: where a comment is on the page as it is now.

-- The headings above line n of lines (outside ``` fences), as "A › B".
function M.heading_at(lines, n)
  local stack, fenced = {}, false
  for i = 1, math.min(n, #lines) do
    local line = lines[i]
    if line:match("^%s*```") then
      fenced = not fenced
    elseif not fenced then
      local hashes, title = line:match("^(#+)%s+(.-)%s*#*%s*$")
      if hashes then
        for level = #hashes, #stack do
          stack[level] = nil
        end
        stack[#hashes] = title
      end
    end
  end
  local path = {}
  for level = 1, 6 do
    if stack[level] then
      path[#path + 1] = stack[level]
    end
  end
  return table.concat(path, " › ")
end

-- The lines (first, last; 1-based in lines) a comment is on now, and how it was found: "exact"
-- (its quote, the match closest to where it was), "moved" (its quote's first line alone), "heading"
-- (its heading, the quote gone), "lost" (none of them: the line it was on, kept in the page).
---@return integer first, integer last, string how
function M.anchor(lines, comment, offset)
  local quote = vim.split(comment.quote or "", "\n", { plain = true })
  local was = (comment.from or 1) - (offset or 0)
  local best
  for i = 1, #lines - #quote + 1 do
    local all = true
    for j, line in ipairs(quote) do
      if lines[i + j - 1] ~= line then
        all = false
        break
      end
    end
    if all and (not best or math.abs(i - was) < math.abs(best - was)) then
      best = i
    end
  end
  if best then
    return best, best + #quote - 1, "exact"
  end
  local first = vim.trim(quote[1] or "")
  if first ~= "" then
    for i, line in ipairs(lines) do
      if vim.trim(line) == first and (not best or math.abs(i - was) < math.abs(best - was)) then
        best = i
      end
    end
    if best then
      return best, best, "moved"
    end
  end
  local heading = (comment.heading or ""):match("([^›]+)$")
  heading = heading and vim.trim(heading)
  if heading and heading ~= "" then
    for i, line in ipairs(lines) do
      if line:match("^#+%s+(.-)%s*#*%s*$") == heading then
        return i, i, "heading"
      end
    end
  end
  local at = math.max(1, math.min(was, #lines))
  return at, at, "lost"
end

-- What the router is sent for a new comment, or a reply of the user's.
function M.prompt(repo, name, comment, reply)
  local where = ("%s/%s#%s"):format(repo, name, comment.id)
  if reply then
    return ("[page reply %s] %s\n\n(on your page %s; reply with iso <role> page reply %s %s \"...\" [--ask], resolve with iso <role> page resolve %s %s \"what changed\"; handing it to a worker? iso <role> page waiting %s %s <agent>|none shows them who has it)")
      :format(where, reply, M.file(repo, name), name, comment.id, name, comment.id, name, comment.id)
  end
  local quoted = vim.tbl_map(function(line)
    return "> " .. line
  end, vim.split(comment.quote, "\n", { plain = true }))
  local lines = comment.from == comment.to and ("line %d"):format(comment.from) or ("lines %d-%d"):format(comment.from, comment.to)
  return ("[page comment %s] on %s%s of %s:\n%s\n\n%s\n\n(change the page wherever this asks, then iso <role> page resolve %s %s \"what changed\"; or iso <role> page reply %s %s \"...\" [--ask] to answer or ask the user; handing it to a worker? iso <role> page waiting %s %s <agent>|none shows them who has it)")
    :format(where, comment.heading ~= "" and ('"' .. comment.heading .. '" ') or "", lines, M.file(repo, name),
      table.concat(quoted, "\n"), comment.text, name, comment.id, name, comment.id, name, comment.id)
end

-- The view (the TUI's): comments drawn on a page's buffer, their keys, the input box's modes.

local NS = vim.api.nvim_create_namespace("isovim_page_comments")
local DIVES = vim.api.nvim_create_namespace("isovim_page_dives")
local CRUMBS = vim.api.nvim_create_namespace("isovim_page_crumbs")
local ACTIVITY = vim.api.nvim_create_namespace("isovim_page_activity")
local ICON = "\u{f075}" -- fa-comment
vim.api.nvim_set_hl(0, "IsovimPageDive", { default = true, link = "DiagnosticVirtualTextInfo" })

local function short(time)
  return os.date("%b %d %H:%M", time)
end

-- The lines a comment shows under its quote: its first line and how many replies, or (opened) all
-- of it and every reply.
local function note_lines(comment, opened)
  local resolved = comment.status == "resolved"
  local hl = resolved and "Comment" or M.waiting(comment) and "DiagnosticWarn" or "DiagnosticInfo"
  local text = vim.split(comment.text, "\n", { plain = true })
  local tail = #comment.replies > 0 and (" · %d %s"):format(#comment.replies, #comment.replies == 1 and "reply" or "replies") or ""
  if resolved then
    tail = tail .. " · resolved" .. (comment.note and (": " .. comment.note) or "")
  elseif M.waiting(comment) then
    tail = tail .. " · waiting on you (a replies)"
  end
  if not opened then
    return { { { "  " .. ICON .. " " .. comment.id .. " ", hl }, { text[1] .. (#text > 1 and " …" or ""), "Comment" }, { tail, hl } } }
  end
  local lines = { { { "  " .. ICON .. " " .. comment.id .. " ", hl }, { comment.by .. " · " .. short(comment.at), "Comment" }, { tail, hl } } }
  for _, line in ipairs(text) do
    lines[#lines + 1] = { { "    " .. line, "Normal" } }
  end
  for _, reply in ipairs(comment.replies) do
    local say = vim.split(reply.text, "\n", { plain = true })
    lines[#lines + 1] = { { "    ↳ " .. reply.by .. (reply.ask and " asks" or "") .. " · " .. short(reply.at) .. ": ", reply.ask and "DiagnosticWarn" or "Comment" }, { say[1], "Normal" } }
    for i = 2, #say do
      lines[#lines + 1] = { { "      " .. say[i], "Normal" } }
    end
  end
  return lines
end

-- Draws the page's comments on its view (after the page's lines are drawn): each open one (and the
-- resolved, while r shows them) at its anchor. view.placed keeps where each one is, for the keys.
function M.draw(view, entry)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- The page's own lines, as surface_view drew them before its links became chips: what comments
  -- quote and are found again by.
  local lines = view.source_lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local comments = M.comments(view.repo, view.name)
  view.page_offset = entry and entry.body_line and entry.body_line - 1 or view.page_offset or 0
  view.opened_comments = view.opened_comments or {}
  view.placed = {}
  for _, comment in ipairs(comments) do
    if comment.status == "open" or view.show_resolved then
      local first, last = M.anchor(lines, comment, view.page_offset)
      view.placed[#view.placed + 1] = { comment = comment, first = first, last = last }
      local hl = comment.status == "resolved" and "Comment" or M.waiting(comment) and "DiagnosticWarn" or "DiagnosticInfo"
      for row = first, last do
        vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { sign_text = row == first and ICON or "▎", sign_hl_group = hl })
      end
      vim.api.nvim_buf_set_extmark(buf, NS, last - 1, 0, { virt_lines = note_lines(comment, view.opened_comments[comment.id]) })
    end
  end
  table.sort(view.placed, function(a, b)
    return a.first < b.first
  end)
  M.draw_crumbs(view)
  M.draw_dives(view)
end

-- The page's blurbs, highlighted as pending dives, on the buffer's lines as they are (chips in them).
function M.draw_dives(view)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, DIVES, 0, -1)
  for _, blurb in ipairs(M.blurbs(vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
    vim.api.nvim_buf_set_extmark(buf, DIVES, blurb.row - 1, blurb.from, { end_col = blurb.to, hl_group = "IsovimPageDive",
      priority = 300 })
  end
  -- Its lines were just written, which takes the window's fill with them.
  view.activity, view.shown_fill = nil, nil
  M.draw_activity(view)
end

-- What an item's line says of it now, as virtual text chunks.
local function item_chunks(item)
  if item.state == "ended" then
    return { { "  no answer yet", "DiagnosticWarn" } }
  end
  local glyph, hl = require("isovim.status").icon("working")
  local what = item.state == "queued" and "queued" or item.state == "worker"
    and ("with " .. (item.worker or "?"):match("([^/]+)$")) or "router on it"
  if item.state == "turn" and item.doing then
    what = what .. " · " .. item.doing
  end
  return { { "  " .. glyph .. " ", hl or "DiagnosticInfo" }, { what, "Comment" } }
end

-- Signs of life: each moving or stuck item's line says so, and the top how many are moving. Reads
-- the file only as it changes (view.activity, cleared then); the spinner's tick just draws again.
function M.draw_activity(view)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ACTIVITY, 0, -1)
  view.activity = view.activity or M.activity(view.repo)[view.name] or {}
  local page = view.activity
  view.moving = M.moving(page)
  if next(page) then
    local taken = {}
    local dives = M.dives(view.repo, view.name)
    for _, blurb in ipairs(M.blurbs(vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
      local dive = vim.iter(dives):find(function(each)
        return not taken[each.id] and each.status ~= "answered" and each.question == blurb.question
      end)
      if dive then
        taken[dive.id] = true
        if page[dive.id] then
          vim.api.nvim_buf_set_extmark(buf, ACTIVITY, blurb.row - 1, 0, { virt_text = item_chunks(page[dive.id]), virt_text_pos = "eol" })
        end
      end
    end
    for _, placed in ipairs(view.placed or {}) do
      local item = page[placed.comment.id]
      if item then
        vim.api.nvim_buf_set_extmark(buf, ACTIVITY, placed.last - 1, 0, { virt_text = item_chunks(item), virt_text_pos = "eol" })
      end
    end
  end
  if view.moving > 0 then
    local glyph, hl = require("isovim.status").icon("working")
    vim.api.nvim_buf_set_extmark(buf, ACTIVITY, 0, 0, { virt_lines = { { { glyph .. " ", hl or "DiagnosticInfo" },
      { ("%d being answered"):format(view.moving), "Comment" } } }, virt_lines_above = true })
  end
  M.show_crumbs(view)
end

-- The activity file changed: the repo's page views read it again.
function M.activity_changed(repo)
  for _, view in pairs(require("isovim.surface_view").views) do
    if view.kind == "page" and view.repo == repo then
      view.activity = nil
      M.draw_activity(view)
    end
  end
end

-- The spinner's tick: a page on screen with something moving draws its spinners again.
function M.tick()
  for _, view in pairs(package.loaded["isovim.surface_view"] and require("isovim.surface_view").views or {}) do
    if view.kind == "page" and (view.moving or 0) > 0 and vim.fn.bufwinid(view.buf) ~= -1 then
      M.draw_activity(view)
    end
  end
end

-- The page entry named name in view's repo.
local function page_entry(view, name)
  return vim.iter(surfaces.list(view.repo)):find(function(each)
    return each.type == "page" and each.name == name
  end)
end

-- The breadcrumb over a page with a parent, root > ... > this: virtual lines, so its lines stay the
-- file's lines and comments still map. Each is drawn as a link; virtual lines can't hold the cursor, so
-- it's [[ (with a count for further up) that goes there.
function M.draw_crumbs(view)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, CRUMBS, 0, -1)
  local here = page_entry(view, view.name)
  if not (here and here.parent) then
    return
  end
  local chain, at = {}, page_entry(view, here.parent)
  while at do
    table.insert(chain, 1, at)
    at = at.parent and page_entry(view, at.parent)
  end
  local chunks = {}
  for _, each in ipairs(chain) do
    vim.list_extend(chunks, require("isovim.links").parts(("iso:page/%s/%s"):format(view.repo, each.name)))
    chunks[#chunks + 1] = { " › ", "Comment" }
  end
  chunks[#chunks + 1] = { here.title or here.name, "Title" }
  vim.api.nvim_buf_set_extmark(buf, CRUMBS, 0, 0, { virt_lines = { chunks, { { "", "Comment" } } }, virt_lines_above = true })
  M.show_crumbs(view)
end

-- Virtual lines over a buffer's first line show only once the window is told to fill them.
function M.show_crumbs(view)
  local crumbs = #vim.api.nvim_buf_get_extmarks(view.buf, CRUMBS, 0, -1, {}) > 0
  local fill = (crumbs and 2 or 0) + ((view.moving or 0) > 0 and 1 or 0)
  if fill == view.shown_fill then
    return
  end
  view.shown_fill = fill
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    vim.api.nvim_win_call(win, function()
      if vim.fn.line("w0") == 1 then
        vim.fn.winrestview({ topfill = fill })
      end
    end)
  end
end

-- The comment under the cursor (on one of its lines), if any.
local function under(view)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, placed in ipairs(view.placed or {}) do
    if row >= placed.first and row <= placed.last then
      return placed.comment
    end
  end
end

-- The input box, typing, in a mode: commenting on lines, or replying to a comment.
local function to_input(view, mode)
  view.page_mode = mode
  local win = vim.fn.bufwinid(view.input)
  if win == -1 then
    return
  end
  vim.wo[win][0].winbar = M.winbar(view)
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert()
end

-- The input box's title in a mode; nil out of one (surface_view's says where it goes).
function M.winbar(view)
  local mode = view.page_mode
  if not mode then
    return nil
  end
  if mode.reply then
    return (" ↳ reply to %s · <CR> sends · <C-c> cancels"):format(mode.reply)
  elseif mode.dive then
    return (" [?] a question to dive into, after line %d · <CR> keeps · <C-c> cancels"):format(mode.last + (view.page_offset or 0))
  end
  local where = mode.from == mode.to and ("line %d"):format(mode.from) or ("lines %d-%d"):format(mode.from, mode.to)
  return (" " .. ICON .. " comment on %s%s · <CR> sends · <C-c> cancels"):format(where,
    mode.heading ~= "" and (" (" .. mode.heading:gsub("%%", "%%%%") .. ")") or "")
end

-- Comments on the lines first..last of the view (1-based rows).
local function comment_on(view, first, last)
  local lines = view.source_lines or vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  local offset = view.page_offset or 0
  to_input(view, { quote = table.concat(vim.list_slice(lines, first, last), "\n"), from = first + offset,
    to = last + offset, heading = M.heading_at(lines, first) })
end

-- i: a question to dive into, after the lines first..last.
local function dive_on(view, first, last)
  local lines = view.source_lines or vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  to_input(view, { dive = true, last = last, quote = first ~= last and table.concat(vim.list_slice(lines, first, last), "\n") or nil })
end

-- Writes [? question] into the page's file, after view row last: at the end of its line, or on a line
-- of its own past the fence or table it's in, where it would count as code or break the table. The
-- scan sends it, as it does a hand edit; what a selection quoted goes with it.
local function write_dive(view, mode, text)
  local question = vim.trim(text:gsub("%s+", " "))
  if not ("[? " .. question .. "]"):match("^%b[]$") then
    question = question:gsub("%[", "("):gsub("%]", ")")
  end
  if question == "" then
    return nil, "a question needs words"
  end
  local path = M.file(view.repo, view.name)
  local file = io.open(path, "rb")
  if not file then
    return nil, path .. " is gone"
  end
  local lines = vim.split(file:read("*a"), "\n", { plain = true })
  file:close()
  local at = math.min(mode.last + (view.page_offset or 0), #lines)
  local fenced = false
  for i = 1, at do
    if lines[i]:match("^%s*```") or lines[i]:match("^%s*~~~") then
      fenced = not fenced
    end
  end
  local blurb = "[? " .. question .. "]"
  if fenced or lines[at]:match("^%s*|") or lines[at]:match("^%s*```") then
    while fenced and lines[at + 1] do
      at = at + 1
      fenced = not (lines[at]:match("^%s*```") or lines[at]:match("^%s*~~~"))
    end
    while lines[at + 1] and lines[at + 1]:match("^%s*|") do
      at = at + 1
    end
    table.insert(lines, at + 1, blurb)
  else
    lines[at] = lines[at] .. (lines[at]:match("%S") and " " or "") .. blurb
  end
  update_dives(view.repo, view.name, function(list)
    list[#list + 1] = { id = next_dive(list), question = question, quote = mode.quote, status = "unsent", by = "user", at = os.time() }
    return true
  end)
  write_whole(path, table.concat(lines, "\n"))
  return true
end

-- <CR> in the input box while it's in a mode: the comment (or reply) is kept and sent to the
-- router, or the question written in. True when it took the text.
function M.submit(view, text)
  local mode = view.page_mode
  if not mode then
    return false
  end
  if mode.dive then
    local ok, why = write_dive(view, mode, text)
    if not ok then
      vim.notify("isovim: " .. tostring(why), vim.log.levels.WARN)
      return true
    end
    view.page_mode = nil
    vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(view.input)
    if win ~= -1 then
      vim.wo[win][0].winbar = require("isovim.surface_view").winbar(view)
    end
    local page = vim.fn.bufwinid(view.buf)
    if page ~= -1 then
      vim.api.nvim_set_current_win(page)
    end
    return true
  end
  local comment, err
  if mode.reply then
    comment, err = M.reply(view.repo, view.name, mode.reply, "user", text)
  else
    comment = M.add(view.repo, view.name, vim.tbl_extend("force", mode, { text = text }), "user")
  end
  if not comment then
    vim.notify("isovim: " .. tostring(err), vim.log.levels.ERROR)
    return true
  end
  view.page_mode = nil
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  M.set_activity(view.repo, view.name, comment.id, "queued")
  M.draw(view)
  local win = vim.fn.bufwinid(view.input)
  if win ~= -1 then
    vim.wo[win][0].winbar = require("isovim.surface_view").winbar(view)
  end
  send(view.repo, M.prompt(view.repo, view.name, comment, mode.reply and text or nil), function(ok, why)
    if not ok then
      M.set_activity(view.repo, view.name, comment.id, nil)
      vim.notify(("isovim: %s %s is kept, but its router wasn't told: %s"):format(view.name, comment.id, why), vim.log.levels.WARN)
    end
  end)
  return true
end

-- The page view's keys (surface_view's bind calls this for a page), and the input box's <C-c>.
function M.bind(view)
  require("isovim.links").attach(view.buf)
  local function on(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
  end
  on("n", "c", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    comment_on(view, row, row)
  end, "comment on this line")
  for _, lhs in ipairs({ "c", "<CR>" }) do
    on("x", lhs, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      comment_on(view, math.min(a, b), math.max(a, b))
    end, "comment on the lines selected")
  end
  on("n", "<CR>", function()
    local comment = under(view)
    if not comment then
      return to_input(view, nil)
    end
    view.opened_comments[comment.id] = not view.opened_comments[comment.id] or nil
    M.draw(view)
  end, "open or close the comment here (else type to the router)")
  on("n", "a", function()
    local comment = under(view)
    if comment then
      view.opened_comments[comment.id] = true
      M.draw(view)
      return to_input(view, { reply = comment.id })
    end
    to_input(view, nil)
  end, "reply to the comment here (else type to the router)")
  on("n", "o", function()
    if not require("isovim.links").secondary() then
      to_input(view, nil)
    end
  end, "a PR's link: its view here (else type to the repo's router)")
  on("n", "i", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    dive_on(view, row, row)
  end, "ask a question to dive into, after this line")
  on("x", "i", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    dive_on(view, math.min(a, b), math.max(a, b))
  end, "ask a question to dive into about the lines selected")
  -- The markdown ftplugin maps these to jump by heading, each time the filetype is set, as opening a
  -- rendered view does again.
  local function surfacing()
    on("n", "[[", function()
      M.surface(view, vim.v.count1)
    end, "up to this page's parent (a count for further up)")
    on("n", "]]", function()
      M.descend(view)
    end, "back down to the child you came up from, else the first child linked here")
  end
  surfacing()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("isovim_page_keys_" .. view.buf, { clear = true }),
    buffer = view.buf,
    callback = surfacing,
  })
  for lhs, dir in pairs({ ["]c"] = 1, ["[c"] = -1 }) do
    on("n", lhs, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target
      for _, placed in ipairs(view.placed or {}) do
        if (dir > 0 and placed.first > row and (not target or placed.first < target))
          or (dir < 0 and placed.first < row and (not target or placed.first > target)) then
          target = placed.first
        end
      end
      if target then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { target, 0 })
      end
    end, dir > 0 and "the next comment" or "the previous comment")
  end
  on("n", "r", function()
    view.show_resolved = not view.show_resolved or nil
    M.draw(view)
  end, "show or hide the resolved comments")
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    view.page_mode = nil
    vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(view.input)
    if win ~= -1 then
      vim.wo[win][0].winbar = require("isovim.surface_view").winbar(view)
    end
    local page = vim.fn.bufwinid(view.buf)
    if page ~= -1 then
      vim.api.nvim_set_current_win(page)
    end
  end, { buffer = view.input, nowait = true, desc = "isovim: cancel the comment or reply" })
end

_G.isovim_page_came_from = _G.isovim_page_came_from or {}
local came_from = _G.isovim_page_came_from

local function toast(text)
  vim.notify("isovim: " .. text, vim.log.levels.INFO)
end

-- Opens a page of the view's repo; on the line linking to child, if given.
local function go(view, entry, child)
  surfaces.open(entry)
  if child then
    vim.schedule(function()
      local there = require("isovim.surface_view").views[view.repo .. "/" .. entry.name]
      for row, line in ipairs(there and there.source_lines or {}) do
        for _, link in ipairs(require("isovim.links").find(line)) do
          local p = require("isovim.links").parse(link[3])
          if p and p.kind == "page" and p.name == child then
            return pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
          end
        end
      end
    end)
  end
end

-- [[: up count pages, remembering the way back down.
function M.surface(view, count)
  local at = page_entry(view, view.name)
  local child
  for _ = 1, count do
    local up = at and at.parent and page_entry(view, at.parent)
    if not up then
      break
    end
    came_from[view.repo .. "/" .. up.name] = at.name
    child, at = at.name, up
  end
  if not child then
    return toast("this page is at the top: it has no parent")
  end
  go(view, at, child)
end

-- ]]: to the child you came up from, else the first child linked on the page, else any child.
function M.descend(view)
  local key = view.repo .. "/" .. view.name
  local function child_named(name)
    local entry = name and page_entry(view, name)
    return entry and entry.parent == view.name and entry or nil
  end
  local entry = child_named(came_from[key])
  for _, line in ipairs(not entry and view.source_lines or {}) do
    for _, link in ipairs(require("isovim.links").find(line)) do
      local p = require("isovim.links").parse(link[3])
      entry = entry or (p and p.kind == "page" and child_named(p.name)) or nil
    end
  end
  if not entry then
    entry = vim.iter(surfaces.list(view.repo)):find(function(each)
      return each.type == "page" and each.parent == view.name
    end)
  end
  if not entry then
    return toast("nothing is beneath this page")
  end
  go(view, entry)
end

-- The page's keys, for the help (`?` in the sidebar).
M.help_keys = {
  { "c (or V/v then c, <CR>)", "comment on the line, or the lines selected, in the box under the page" },
  { "<CR>", "open or close the comment under the cursor: all of it and its replies" },
  { "a", "reply to the comment under the cursor" },
  { "]c / [c", "the next / previous comment" },
  { "r", "show or hide the resolved comments" },
  { "u", "mark the page unread: back in the Inbox until you open it again" },
  { "i (or V/v then i)", "ask a question to dive into: [? it] goes at the end of the line, or after the lines selected, and the router answers with a page in its place" },
  { "[[ / ]]", "up to this page's parent (a count for further up) / back down to the child you came up from, else the first child linked here" },
  { "o", "type to the repo's router; on a PR's link, its view here (<Tab> is its page in the browser)" },
  { "<C-c>", "in the box: cancel the comment or reply" },
}

-- A page's window: room for the comments' signs, its breadcrumb showing.
function M.dress(win, view)
  vim.wo[win][0].signcolumn = "yes:1"
  if view then
    view.shown_fill = nil
    M.show_crumbs(view)
  end
end

return M
