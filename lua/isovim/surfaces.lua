-- Surfaces: the files in a repo's iso/ (~/.iso/<owner>/<repo>/iso/, or a pseudo-repo's: root/iso/ for
-- the host root, general/iso/ for no repo) that show the user something, written only by the repo's router. Only the top level of iso/ counts, so
-- agents/, journal/ and transcripts/ never do:
--   <name>.md       a markdown surface, every *.md. Optional YAML frontmatter, plain
--                   key: value lines between --- lines: name (the row's title; else the file's),
--                   icon (up to two cells), color (a palette name or #rrggbb), consumable (true:
--                   gone from the Inbox once opened, until the router rewrites it)
--   <name>.surface  JSON with a type, made by iso router surface:
--                   question  {question, options: [{label, description?}], multi?, other?, created,
--                             by? (who asked), raised?, raised_by?, why? (the user's alone: a root
--                             raised it, with its one-line recommendation, or it's a permission
--                             request, raised_by "isovim"), answer?: {labels, other?, by, at}}:
--                             answered with iso answer or M.answer (by the user, or in root mode a
--                             root, isovim.rootmode), then removed when its asker collects it
--                   file      {path}, folder {path}: opens it; its target missing is an error
--                   chat      {agent}: an agent's chat to look at; removed once opened (M.consume)
--                   link      {address, label?, note?}: a link to anything in isovim or a web page
--                             (isovim.links), opened by <CR>: in the Inbox until you open it
--                             (consumed, as consumable markdown is), then with the files
--   pages/<name>.md a page (isovim.pages): markdown the user reads and comments on, its comments in
--                   pages/<name>.comments.jsonl beside it, what it's asked to dive into in
--                   pages/<name>.dives.jsonl; frontmatter as a markdown surface's, and parent
--   threads/<id>.jsonl a thread (isovim.threads): one idea's conversation with the router; an open
--                   one lists, waiting on you while a router post is unread, then those an agent
--                   resolved that you haven't read, and the last few resolved
-- The PRs surface is isovim's own, no file: M.list adds it for a repo with PRs registered (M.prs_entry).
-- So is the decision log, M.list adding it for a scope whose root has decided something: decisions.jsonl
-- in iso/, a line a decision (M.decisions), which no scan reads. It's never in an Inbox.
-- A surface's name is its file's stem; no .md and .surface share one. One that's broken gets a
-- <file>.surface.error beside it (foo.surface's is foo.surface.error) saying why, rewritten as
-- the reason changes and deleted once it's fixed or gone.
--
-- M.read parses a repo's surfaces and changes nothing. M.scan does that and reconciles: it
-- writes the error files and publishes surface.<repo>.<name>.created|changed|removed against what
-- the last scan saw (run/<repo>/surfaces.json), so whoever scans first, a CLI command or the
-- TUI's watcher (M.watch), publishes each change once. answered and consumed come from M.answer
-- and M.consume.
--
-- For the sidebar: M.watch(on_change) once at startup (on_change(repo, entries) after each
-- rescan that changed something), M.repos() for the repos that have an iso/, M.list(repo) for an
-- Inbox's rows (isovim.Surface below, sorted by file name; needs_you marks what waits on the user),
-- M.open(entry) on Enter (consumes a chat or consumable markdown, opens a question as a buffer
-- that answers it), M.answer(entry, {labels, other?} or words) and M.consume(entry) directly.
local store = require("isovim.store")
local events = require("isovim.events")

local M = {}

---@class isovim.Surface
---@field repo string the repo key it's in
---@field name string its file's stem: the topic part, and what iso answer takes
---@field type "markdown"|"prs"|"decisions"|"page"|"thread"|"question"|"file"|"folder"|"chat"|"link"|"broken"
---@field address? string link: what it points at, an iso: address or a web page's URL
---@field note? string link: the router's one line about it
---@field marked_unread? boolean you marked it unread (M.toggle_read): it waits on you until you open it
---@field title string what its row says
---@field file string the surface's own file
---@field created number when it was first seen (or made), epoch seconds
---@field needs_you boolean waiting on the user: a pending question no root is deciding, a chat, an
--- unopened consumable; what the host Inbox, its counts, notifications and <leader>in go by
---@field error? string why it's broken, as its error_file says
---@field error_file string where that goes
---@field icon? string markdown and tasks: from the frontmatter
---@field color? string
---@field consumable? boolean
---@field consumed? boolean consumable and opened since it last changed
---@field body? string markdown, tasks and page: the text after the frontmatter
---@field body_line? integer page: the file's line its body starts on
---@field comments_open? integer page: how many of its comments are open
---@field posts? integer thread: how many posts it has
---@field working? boolean thread: the router's turn on it runs
---@field new_reply? boolean thread: a router post past what you've read
---@field waiting_on? string thread: whose turn it is, "user" or a worker's address
---@field waiting_name? string thread: the name of the worker it waits on
---@field resolved? boolean thread: a resolved one, listed under the open ones
---@field outcome? string thread: what it was resolved with
---@field waiting? integer page: how many of them wait on the user (an agent's reply asked them); prs: PRs
---@field tasks? {status: string, text: string, line: integer}[] tasks
---@field question? string question
---@field options? {label: string, description?: string}[]
---@field multi? boolean
---@field other? boolean
---@field answer? {labels: string[], other?: string, by: string, at: number}
---@field asker? string question: who asked it, <ws>/<agent>; nil from a shell
---@field raised? boolean question: yours alone (a root raised it, or it's a permission request)
---@field raised_by? string question: the root that raised it, or "isovim" for a permission request
---@field why? string question: the root's one line on why it raised it, its recommendation
---@field deciding? string question: the root deciding it (root mode), while it's pending and not raised
---@field path? string file, folder: the target
---@field exists? boolean
---@field agent? string chat: the agent's address

-- The pseudo-repos, keys beside owner/repo: root (the host root's) and general (no repo's), the same
-- keys store gives agents. "_" (general's old key) is still read as general, even while an old _/
-- waits on its move (store.old_live): nothing new is written there.
M.pseudo = store.pseudo
local canon = store.canon_new

-- The surface key for a repo key (owner/repo, root, general or _); nil when it's none of those.
---@return string?
function M.key(key)
  key = canon(key)
  if store.valid_key(key) then
    return key
  end
end

-- A repo's iso/.
function M.dir(repo)
  return store.path(canon(repo))
end

-- Where a broken surface's reason goes.
function M.error_file(file)
  return file:match("%.surface$") and file .. ".error" or file .. ".surface.error"
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

-- Written to a hidden temp file and renamed over, so no reader (or watcher) sees half of it.
local function write_file(path, text)
  local tmp = ("%s/.%s.%d.tmp"):format(vim.fs.dirname(path), vim.fs.basename(path), vim.uv.os_getpid())
  local file = assert(io.open(tmp, "wb"))
  file:write(text)
  file:close()
  assert(vim.uv.fs_rename(tmp, path))
end

local function write_json(path, value)
  write_file(path, vim.json.encode(value) .. "\n")
end

-- The repo keys with an iso/ under the work root, the pseudo-repos among them; nothing below one is
-- looked in. An old _/ is isovim.migrate's to move into general/.
---@return string[]
function M.repos()
  local found = {}
  for name in pairs(M.pseudo) do
    if vim.fn.isdirectory(M.dir(name)) == 1 then
      found[#found + 1] = name
    end
  end
  local function walk(dir, folder, depth)
    local key = folder and store.folder_key(folder)
    if depth == 1 and (M.pseudo[folder] or folder == "_") then
      return
    elseif key and store.valid_key(key) and vim.fn.isdirectory(dir .. "/iso") == 1 then
      found[#found + 1] = key
      return
    end
    if depth == 4 then
      return
    end
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" and not vim.startswith(name, ".") then
        walk(dir .. "/" .. name, folder and folder .. "/" .. name or name, depth + 1)
      end
    end
  end
  walk(store.work, nil, 0)
  table.sort(found)
  return found
end

-- frontmatter

local function scalar(value)
  local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
  if quoted then
    return quoted
  end
  value = value:gsub("%s+#.*$", "")
  local lower = value:lower()
  if lower == "true" or lower == "yes" then
    return true
  elseif lower == "false" or lower == "no" then
    return false
  end
  return value
end

-- The fields between a first line of --- and the next ---, the text after, and the line the text
-- starts on; or nil and why.
---@return table? fields, string? body, integer|string start_or_error
local function frontmatter(text)
  local lines = vim.split(text, "\n", { plain = true })
  if not (lines[1] or ""):match("^%-%-%-%s*\r?$") then
    return {}, text, 1
  end
  local fields = {}
  for i = 2, #lines do
    local line = lines[i]:gsub("\r$", "")
    if line:match("^%-%-%-%s*$") then
      return fields, table.concat(vim.list_slice(lines, i + 1), "\n"), i + 1
    elseif not line:match("^%s*$") and not line:match("^%s*#") then
      local key, value = line:match("^([%w_-]+):%s*(.-)%s*$")
      if not key then
        return nil, nil, ("line %d of the frontmatter isn't key: value: %s"):format(i, line)
      end
      fields[key] = scalar(value)
    end
  end
  return nil, nil, "the frontmatter opened by --- on line 1 is never closed by a --- line"
end

-- The frontmatter fields a markdown surface takes, onto the entry; nil, or what's wrong.
local function apply_fields(entry, fields)
  if entry.type == "page" and type(fields.parent) == "string" and fields.parent ~= "" then
    entry.parent = fields.parent
  end
  if fields.name ~= nil then
    if type(fields.name) ~= "string" or fields.name == "" then
      return "name is the row's title, a string"
    end
    entry.title = fields.name
  end
  if fields.icon ~= nil then
    local icon = type(fields.icon) == "string" and (require("isovim.icons").words[fields.icon:lower()] or fields.icon)
    if not icon or vim.fn.strdisplaywidth(icon) > 2 then
      local words = vim.tbl_keys(require("isovim.icons").words)
      table.sort(words)
      return "icon is a glyph up to two cells wide or one of " .. table.concat(words, ", ")
    end
    entry.icon = icon
  end
  if fields.color ~= nil then
    local palette = require("isovim.repos").palette
    local color = type(fields.color) == "string" and fields.color:lower() or ""
    if not (palette[color] or color:match("^#%x%x%x%x%x%x$")) then
      local names = vim.tbl_keys(palette)
      table.sort(names)
      return ("color is #rrggbb or one of %s, not %s"):format(table.concat(names, ", "), tostring(fields.color))
    end
    entry.color = color
  end
  if fields.consumable ~= nil then
    if type(fields.consumable) ~= "boolean" then
      return "consumable is true or false"
    end
    entry.consumable = fields.consumable
  end
end

-- questions

local QUESTION_KEYS = { question = true, options = true, multi = true, other = true, name = true }
local OPTION_KEYS = { label = true, description = true }

M.question_shape = "{question, options: [{label, description?}], multi?, other?, name?}"

-- A question as iso router surface question takes it, checked: its question, options, multi and
-- other, and the name it asked for; or nil and what's wrong.
---@return table? question, string? err
function M.validate_question(spec)
  if type(spec) ~= "table" or (vim.islist(spec) and next(spec)) then
    return nil, "a question is a JSON object " .. M.question_shape
  end
  for key in pairs(spec) do
    if not QUESTION_KEYS[key] then
      return nil, ("unknown key %q: a question is %s"):format(tostring(key), M.question_shape)
    end
  end
  if type(spec.question) ~= "string" or vim.trim(spec.question) == "" then
    return nil, "question is the text to ask, a string"
  end
  for _, key in ipairs({ "multi", "other" }) do
    if spec[key] ~= nil and type(spec[key]) ~= "boolean" then
      return nil, key .. " is true or false"
    end
  end
  if spec.name ~= nil and (type(spec.name) ~= "string" or not spec.name:match("^[%w_-]+$")) then
    return nil, "name is letters, digits, _ and -"
  end
  if type(spec.options) ~= "table" or not vim.islist(spec.options) or (#spec.options == 0 and not spec.other) then
    return nil, "options is a list of {label, description?}, at least one unless other is true"
  end
  local options, seen = {}, {}
  for i, option in ipairs(spec.options) do
    if type(option) ~= "table" or vim.islist(option) then
      return nil, ("option %d is an object {label, description?}"):format(i)
    end
    for key in pairs(option) do
      if not OPTION_KEYS[key] then
        return nil, ("option %d has an unknown key %q: an option is {label, description?}"):format(i, tostring(key))
      end
    end
    if type(option.label) ~= "string" or vim.trim(option.label) == "" then
      return nil, ("option %d's label is a string"):format(i)
    elseif option.description ~= nil and type(option.description) ~= "string" then
      return nil, ("option %d's description is a string"):format(i)
    end
    local label = vim.trim(option.label)
    if seen[label:lower()] then
      return nil, ("two options are labelled %q"):format(label)
    end
    seen[label:lower()] = true
    options[i] = { label = label, description = option.description }
  end
  return {
    question = vim.trim(spec.question),
    options = options,
    multi = spec.multi or false,
    other = spec.other or false,
  }, nil, spec.name
end

-- What makes two questions the same one: their text, options, multi and other.
local function question_key(q)
  local parts = { q.question, tostring(q.multi), tostring(q.other) }
  for _, option in ipairs(q.options) do
    parts[#parts + 1] = option.label .. "\31" .. (option.description or "")
  end
  return vim.fn.sha256(table.concat(parts, "\30"))
end

-- parsing

local TYPES = { question = true, file = true, folder = true, chat = true, link = true }

local function parse_surface(entry, text)
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    entry.type = "broken"
    return "isn't JSON: " .. (ok and "not an object" or tostring(data):gsub("^.-:%d+: ", ""))
  elseif not TYPES[data.type] then
    entry.type = "broken"
    return ("its type is one of question, file, folder, chat, link, not %s"):format(tostring(data.type))
  end
  entry.type = data.type
  entry.created = tonumber(data.created)
  if data.type == "question" then
    local q, err = M.validate_question({ question = data.question, options = data.options, multi = data.multi, other = data.other })
    if not q then
      return err
    end
    entry.title, entry.question, entry.options, entry.multi, entry.other = q.question, q.question, q.options, q.multi, q.other
    entry.key = question_key(q)
    if type(data.answer) == "table" then
      entry.answer = data.answer
    end
    entry.raised = data.raised == true or nil
    entry.raised_by = entry.raised and type(data.raised_by) == "string" and data.raised_by or nil
    entry.why = entry.raised and type(data.why) == "string" and data.why ~= "" and data.why or nil
    entry.asker = type(data.by) == "string" and data.by or nil
    -- In root mode its root decides it first: it waits on you once raised, or with no root in
    -- charge (root mode off). You may answer it either way.
    entry.deciding = require("isovim.rootmode").root_for(entry)
    entry.needs_you = not entry.answer and not entry.deciding
  elseif data.type == "file" or data.type == "folder" then
    if type(data.path) ~= "string" or data.path == "" then
      return "path is the " .. data.type .. "'s path, a string"
    end
    entry.path = vim.fs.normalize(data.path)
    entry.title = vim.fs.basename(entry.path)
    local stat = vim.uv.fs_stat(entry.path)
    entry.exists = stat ~= nil
    if not stat then
      return entry.path .. " doesn't exist"
    elseif data.type == "file" and stat.type == "directory" then
      return entry.path .. " is a folder: make it a folder surface"
    elseif data.type == "folder" and stat.type ~= "directory" then
      return entry.path .. " isn't a folder: make it a file surface"
    end
  elseif data.type == "link" then
    if type(data.address) ~= "string" or not require("isovim.links").parse(data.address) then
      return "address is an iso: address (iso:agent/..., iso:thread/..., iso:pr/..., iso:page/..., iso:file/...) or an http(s) URL"
    end
    entry.address = data.address
    entry.title = type(data.label) == "string" and data.label ~= "" and data.label or data.address:gsub("^iso:", "")
    entry.note = type(data.note) == "string" and data.note ~= "" and data.note or nil
  elseif data.type == "chat" then
    if type(data.agent) ~= "string" then
      return "agent is the agent's address, a string"
    end
    entry.agent = data.agent
    entry.title = "chat · " .. data.agent
    local ws, id = data.agent:match("^(.*)/([^/]+)$")
    if not (ws and store.agent(ws, id)) then
      return "there's no agent " .. data.agent
    end
    entry.needs_you = true
  end
end

local function parse_markdown(entry, text)
  local fields, body, start = frontmatter(text)
  if not fields then
    return start
  end
  entry.body, entry.body_line = body, start
  local err = apply_fields(entry, fields)
  if err then
    return err
  end
end

local function state_file(repo)
  return store.run_dir(canon(repo)) .. "/surfaces.json"
end

local function read_state(repo)
  local ok, value = pcall(vim.json.decode, read_file(state_file(repo)) or "")
  return ok and type(value) == "table" and value or {}
end

-- The surface in iso/<base>, parsed; state is what the last scan saw.
---@return isovim.Surface
local function parse(repo, base, state, taken)
  local file = M.dir(repo) .. "/" .. base
  local text = read_file(file) or ""
  local markdown = base:match("%.md$") ~= nil
  local page = vim.startswith(base, "pages/")
  local entry = {
    repo = repo,
    name = M.name_of(base),
    file = file,
    base = base,
    type = page and "page" or "markdown",
    needs_you = false,
    error_file = M.error_file(file),
  }
  entry.title = entry.name
  local err
  if page and taken[entry.name] ~= base then
    err = ("%s already has the name %s"):format(taken[entry.name], entry.name)
  elseif markdown then
    err = parse_markdown(entry, text)
  elseif taken[entry.name] then
    entry.type = "broken"
    err = ("%s already has the name %s"):format(taken[entry.name], entry.name)
  else
    err = parse_surface(entry, text)
  end
  entry.error = err
  if page then
    -- Its comments are part of it: a new one, a reply or a resolve changes the page's row.
    local comments, raw = require("isovim.pages").comments(repo, entry.name)
    entry.comments_open, entry.waiting = require("isovim.pages").summary(comments)
    entry.needs_you = entry.waiting > 0
    text = text .. "\0" .. raw
  end
  entry.sig = vim.fn.sha256(text .. "\0" .. (err or ""))
  local seen = state[base] or {}
  -- A file, folder or link an agent surfaced is unread until you open it, as consumable markdown is.
  local pointer = entry.type == "file" or entry.type == "folder" or entry.type == "link"
  entry.consumed = (entry.consumable or pointer) and seen.consumed == entry.sig or nil
  if (entry.type == "markdown" and entry.consumable or pointer) and not entry.consumed and not err then
    entry.needs_you = true
  end
  local stat = vim.uv.fs_stat(file)
  entry.created = entry.created or seen.first or (stat and stat.mtime.sec) or os.time()
  return entry
end

-- What you marked unread (M.toggle_read), by base: run/<repo>/unread.json. Apart from the scan's
-- state, which drops what's no file (the PRs surface), and from what was read (consumed, a thread's
-- last line seen), which it leaves alone.
local function unread_file(repo)
  return store.run_dir(canon(repo)) .. "/unread.json"
end

local function read_unread(repo)
  local ok, value = pcall(vim.json.decode, read_file(unread_file(repo)) or "")
  return ok and type(value) == "table" and value or {}
end

-- A surface's name from its file under iso/: its stem.
function M.name_of(base)
  base = base:gsub("^pages/", "")
  return base:match("^(.*)%.md$") or base:match("^(.*)%.surface$") or base
end

-- How the repo's pages stand to each other: a parent that's gone, or a cycle, makes a page top-level,
-- and each knows how many are beneath it.
function M.relate_pages(list)
  local pages = {}
  for _, entry in ipairs(list) do
    if entry.type == "page" then
      pages[entry.name] = entry
    end
  end
  local cut = {}
  for name, entry in pairs(pages) do
    local at, seen = entry.parent, { [name] = true }
    while at and pages[at] and not seen[at] do
      seen[at] = true
      at = pages[at].parent
    end
    if at then
      cut[#cut + 1] = entry
    end
  end
  for _, entry in ipairs(cut) do
    entry.parent = nil
  end
  for _, entry in pairs(pages) do
    local at = entry.parent
    while at do
      pages[at].beneath = (pages[at].beneath or 0) + 1
      at = pages[at].parent
    end
  end
  for _, entry in pairs(pages) do
    entry.sig = vim.fn.sha256(("%s|%s|%d"):format(entry.sig, tostring(entry.parent), entry.beneath or 0))
  end
  -- What's moving on it and beneath it: M.watch sets this again as the activity changes.
  M.relate_activity(list, pages)
end

-- Each page's count of what's being answered, on it or beneath it.
function M.relate_activity(list, pages)
  if not pages then
    pages = {}
    for _, entry in ipairs(list) do
      if entry.type == "page" then
        pages[entry.name] = entry
      end
    end
  end
  local any = next(pages)
  local activity = any and require("isovim.pages").activity(pages[any].repo) or {}
  for _, entry in pairs(pages) do
    entry.moving = nil
  end
  for name, page in pairs(activity) do
    local n = require("isovim.pages").moving(page)
    local at = n > 0 and pages[name] or nil
    while at do
      at.moving = (at.moving or 0) + n
      at = at.parent and pages[at.parent] or nil
    end
  end
end

-- A repo's surfaces, parsed, by name; nothing is written.
---@return isovim.Surface[]
function M.read(repo, state)
  repo = canon(repo)
  state = state or read_state(repo)
  local dir = M.dir(repo)
  local bases, taken = {}, {}
  for base, kind in vim.fs.dir(dir) do
    if kind ~= "directory" and not vim.startswith(base, ".") then
      if base:match("%.md$") then
        bases[#bases + 1] = base
        taken[base:sub(1, -4)] = base
      elseif base:match("%.surface$") then
        bases[#bases + 1] = base
      end
    end
  end
  -- Pages, after the rest: a name another surface has already makes the page broken.
  local pages = {}
  if vim.fn.isdirectory(dir .. "/pages") == 1 then
    for base, kind in vim.fs.dir(dir .. "/pages") do
      if kind ~= "directory" and not vim.startswith(base, ".") and base:match("%.md$") then
        pages[#pages + 1] = "pages/" .. base
      end
    end
  end
  table.sort(pages)
  for _, base in ipairs(pages) do
    taken[M.name_of(base)] = taken[M.name_of(base)] or base
  end
  table.sort(bases)
  vim.list_extend(bases, pages)
  local list = vim.tbl_map(function(base)
    return parse(repo, base, state, taken)
  end, bases)
  M.relate_pages(list)
  vim.list_extend(list, M.threads(repo))
  local unread = read_unread(repo)
  for _, entry in ipairs(next(unread) and list or {}) do
    if unread[entry.base] and entry.type ~= "question" and not entry.resolved then
      entry.needs_you, entry.marked_unread = true, true
    end
  end
  return list
end

-- How many resolved threads the sidebar lists, under the open ones.
local RESOLVED_LISTED = 5

-- What a thread's row calls the worker it waits on: its name, else its id.
local function worker_name(address)
  local ws, id = address:match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, id)
  return record and record.name or id or address
end

-- The glyph of who posted last in a thread: yours, or the agent's by its role and kind ({glyph, hl}).
-- Read as the row is made, not as it's drawn, as the sidebar draws it on every spinner frame.
local function poster_glyph(by)
  if not by then
    return nil
  end
  local icons = require("isovim.icons")
  if by == "user" then
    return { icons.get("user") }
  end
  local ws, id = by:match("^(.*)/([^/]+)$")
  return { icons.agent(ws and store.agent(ws, id) or { kind = "claude" }) }
end

-- The repo's threads as surfaces (isovim.threads): named by id, titled, the open ones newest first,
-- waiting on you while a router post is past what you've read or it's your turn, then those an agent
-- resolved that you haven't read, unread until you open them, then the last few other resolved, the
-- latest first.
---@param all? boolean every resolved one, not only the last few
---@return isovim.Surface[]
function M.threads(repo, all)
  local threads = require("isovim.threads")
  local seen = threads.seen(repo)
  local list = {}
  local every = threads.list(repo, true)
  -- A thread's task, as the board has it (isovim.board_tasks): its column decides if it's parked.
  local tasks = require("isovim.board_tasks").read(repo)
  local function task_of(info)
    return info.task and tasks[info.task] or nil
  end
  local function is_parked(info)
    local task = task_of(info)
    return task ~= nil and task.column == "backburner"
  end
  local function task_sig(info)
    local task = task_of(info)
    return task and (task.id .. task.title .. task.column) or ""
  end
  local resolved = vim.tbl_filter(function(info)
    return info.status == "resolved"
  end, every)
  for _, info in ipairs(vim.tbl_filter(function(info)
    return info.status == "open"
  end, every)) do
    local file = threads.file(repo, info.id)
    -- A reply you haven't read, or your turn, which outlasts your reading it; a question waiting is in
    -- the Inbox as itself (below), the thread's row saying so. While the router's turn on it runs, it
    -- isn't yours.
    -- On the backburner it stops nagging: out of the Inbox, a new post only marking its card.
    local parked = is_parked(info)
    local new_reply = not parked and not info.working and info.last_reply > (seen[info.id] or 0)
    local on_you = not parked and info.waiting_on == "user" and not info.working
    local needs_you = new_reply or on_you
    local worker = info.waiting_on ~= "user" and info.waiting_on or nil
    -- Its questions still waiting, each a question surface: the Inbox, root mode and iso answer
    -- take them as any question, and their answers go back into the thread (M.answer).
    for _, q in ipairs(info.questions) do
      if not q.answer then
        local entry = {
          repo = repo,
          name = info.id .. "-" .. q.qid,
          base = "threads/" .. info.id .. ".jsonl#" .. q.qid,
          type = "question",
          file = file,
          error_file = "",
          title = q.question,
          question = q.question,
          options = q.options,
          multi = q.multi,
          other = q.other,
          asker = q.by,
          raised = q.raised or nil,
          raised_by = q.raised and q.raised_by or nil,
          why = q.raised and q.why or nil,
          key = question_key(q),
          created = q.at or 0,
          thread = { id = info.id, title = info.title, qid = q.qid },
        }
        entry.deciding = require("isovim.rootmode").root_for(entry)
        entry.needs_you = not entry.deciding
        entry.sig = vim.fn.sha256(vim.json.encode({ q.question, q.options, q.raised or false, info.title }))
        list[#list + 1] = entry
      end
    end
    list[#list + 1] = {
      repo = repo,
      name = info.id,
      base = "threads/" .. info.id .. ".jsonl",
      type = "thread",
      title = info.title,
      file = file,
      error_file = "",
      created = info.at or 0,
      posts = info.posts,
      last_glyph = poster_glyph(info.last_by),
      working = info.working,
      needs_you = needs_you,
      new_reply = new_reply,
      waiting_on = on_you and "user" or worker,
      waiting_name = worker and worker_name(worker),
      bypass_name = info.bypass and worker_name(info.bypass),
      pending = info.pending,
      task = task_of(info) and info.task or nil,
      task_title = task_of(info) and task_of(info).title or nil,
      last_at = info.last_at,
      parked = parked or nil,
      parked_unread = parked and info.last_reply > (seen[info.id] or 0) or nil,
      sig = vim.fn.sha256(("%s|%d|%s|%s|%s|%d|%s"):format(info.title, info.posts, tostring(info.working), info.status,
        tostring(needs_you), info.pending, tostring(info.waiting_on))
        .. tostring(info.bypass) .. task_sig(info)),
    }
  end
  table.sort(resolved, function(a, b)
    return (a.resolved_at or 0) > (b.resolved_at or 0)
  end)
  local function unread(info)
    return info.resolved_seq ~= nil and info.resolved_seq > (seen[info.id] or 0)
  end
  local listed = vim.tbl_filter(unread, resolved)
  vim.list_extend(listed, vim.list_slice(vim.tbl_filter(function(info)
    return not unread(info)
  end, resolved), 1, all and #resolved or RESOLVED_LISTED))
  for _, info in ipairs(listed) do
    list[#list + 1] = {
      repo = repo,
      name = info.id,
      base = "threads/" .. info.id .. ".jsonl",
      type = "thread",
      title = info.title,
      file = threads.file(repo, info.id),
      error_file = "",
      created = info.at or 0,
      posts = info.posts,
      last_glyph = poster_glyph(info.last_by),
      -- Unread till opened, unless it's on the backburner: that's left the Inbox for good.
      needs_you = unread(info) and not is_parked(info),
      parked = is_parked(info) or nil,
      parked_unread = is_parked(info) and unread(info) or nil,
      resolved = true,
      outcome = info.outcome,
      pending = 0,
      task = task_of(info) and info.task or nil,
      task_title = task_of(info) and task_of(info).title or nil,
      last_at = info.last_at,
      sig = vim.fn.sha256(("%s|%d|resolved|%s|%s"):format(info.title, info.posts, tostring(info.outcome), task_sig(info))),
    }
  end
  return list
end

-- The board (isovim.thread_board), a view of isovim's own: nil for a repo with no threads, unless empty.
function M.threads_entry(key, empty)
  local repo = canon(key)
  local threads = require("isovim.threads")
  if threads.refusal(repo) or not (empty or #threads.list(repo, true) > 0 or next(require("isovim.board_tasks").read(repo))) then
    return nil
  end
  return { repo = repo, name = "Threads", base = "Threads", type = "threads", title = "Board", needs_you = false,
    sig = "", error_file = "", file = threads.dir(repo) }
end

-- A task, as the jump, its chip and its sidebar row open it: in the board's buffer (isovim.task_view). Nil
-- with no such task.
function M.task_entry(key, id)
  local repo = canon(key)
  local tasks = require("isovim.board_tasks")
  local task = tasks.read(repo)[id]
  if not task then
    return nil
  end
  return { repo = repo, name = id, base = "tasks/" .. id, type = "task", title = task.title, column = task.column, needs_you = false,
    sig = "", error_file = "", file = tasks.file(repo) }
end

-- Every thread of the repo as a row, marked unread as the sidebar's rows are, by id.
function M.thread_rows(repo)
  repo = canon(repo)
  local unread = read_unread(repo)
  local rows = {}
  for _, entry in ipairs(M.threads(repo, true)) do
    if entry.type == "thread" then
      if unread[entry.base] and not entry.resolved then
        entry.needs_you, entry.marked_unread = true, true
      end
      rows[entry.name] = entry
    end
  end
  return rows
end

-- One surface by name; nil when it has none.
---@return isovim.Surface?
function M.get(repo, name)
  repo = canon(repo)
  return vim.iter(M.read(repo)):find(function(entry)
    return entry.name == name
  end)
end

-- Runs fn under the repo's surface lock, a dir only one process can make.
local function locked(repo, fn)
  local run = store.run_dir(canon(repo))
  vim.fn.mkdir(run, "p")
  local lock = run .. "/surfaces.lock"
  local deadline = vim.uv.hrtime() + 5e9
  while not vim.uv.fs_mkdir(lock, 448) do
    local stat = vim.uv.fs_stat(lock)
    -- A holder that died: a scan takes milliseconds.
    if (stat and os.time() - stat.mtime.sec > 30) or vim.uv.hrtime() > deadline then
      vim.uv.fs_rmdir(lock)
    else
      vim.uv.sleep(10)
    end
  end
  local ok, result, err = pcall(fn)
  vim.uv.fs_rmdir(lock)
  if not ok then
    error(result, 0)
  end
  return result, err
end
M.locked = locked

local function publish(entry, what, details)
  events.publish(events.topic("surface", entry.repo, entry.name, what), vim.tbl_extend("force", {
    repo = entry.repo,
    name = entry.name,
    type = entry.type,
    file = entry.file,
    error = entry.error,
  }, details or {}))
end

local function sync_error_files(repo, entries)
  local sources = {}
  for _, entry in ipairs(entries) do
    sources[entry.error_file] = true
    if entry.error then
      local text = ("%s: %s\n"):format(entry.base, entry.error)
      if read_file(entry.error_file) ~= text then
        write_file(entry.error_file, text)
      end
    elseif vim.uv.fs_stat(entry.error_file) then
      os.remove(entry.error_file)
    end
  end
  local dir = M.dir(repo)
  for base in vim.fs.dir(dir) do
    if base:match("%.surface%.error$") and not sources[dir .. "/" .. base] then
      os.remove(dir .. "/" .. base)
    end
  end
end

-- A repo's surfaces, as M.read gives them, after bringing its error files and events up to date.
-- Changes to the surfaces named in quiet are taken in without a changed event (their writer
-- published what happened).
---@param quiet? table<string, true> base file names
---@return isovim.Surface[]
-- The Task Board is gone, as threads and the thread board track work: a repo's old iso/tasks.md moves
-- to iso/archive/tasks-<date>.md, out of what's scanned, once. Nothing is lost, and a tasks.md written
-- after that is a markdown surface like any other.
local function archive_task_board(repo)
  local mark = store.run_dir(repo) .. "/task-board-archived"
  if vim.uv.fs_stat(mark) then
    return
  end
  local from = M.dir(repo) .. "/tasks.md"
  if vim.uv.fs_stat(from) then
    local dir = M.dir(repo) .. "/archive"
    vim.fn.mkdir(dir, "p")
    local to, n = ("%s/tasks-%s.md"):format(dir, os.date("%Y-%m-%d")), 1
    while vim.uv.fs_stat(to) do
      n = n + 1
      to = ("%s/tasks-%s-%d.md"):format(dir, os.date("%Y-%m-%d"), n)
    end
    if not vim.uv.fs_rename(from, to) then
      return
    end
  end
  vim.fn.mkdir(store.run_dir(repo), "p")
  local file = io.open(mark, "w")
  if file then
    file:close()
  end
end

function M.scan(repo, quiet)
  repo = canon(repo)
  if vim.fn.isdirectory(M.dir(repo)) == 0 then
    return {}
  end
  archive_task_board(repo)
  return locked(repo, function()
    local state = read_state(repo)
    local entries = M.read(repo, state)
    sync_error_files(repo, entries)
    local dirty, now, present = false, os.time(), {}
    for _, entry in ipairs(entries) do
      present[entry.base] = true
      local seen = state[entry.base]
      if not seen then
        state[entry.base] = { sig = entry.sig, first = entry.created or now }
        publish(entry, "created", { title = entry.title })
        dirty = true
      elseif seen.sig ~= entry.sig then
        seen.sig = entry.sig
        if not (quiet and quiet[entry.base]) then
          publish(entry, "changed", { title = entry.title })
        end
        dirty = true
      end
      if state[entry.base].type ~= entry.type then
        state[entry.base].type = entry.type
        dirty = true
      end
    end
    for base, seen in pairs(state) do
      if not present[base] then
        publish({ repo = repo, name = M.name_of(base), file = M.dir(repo) .. "/" .. base,
          type = seen.type }, "removed")
        state[base] = nil
        dirty = true
      end
    end
    if dirty then
      write_json(state_file(repo), state)
    end
    return entries
  end)
end

-- making them

-- One surface by name, after a scan publishes what making it changed.
local function scanned(repo, name)
  return vim.iter(M.scan(repo)):find(function(entry)
    return entry.name == name
  end)
end

-- A name no surface in the repo has, from text: its words, lowercased, joined by -.
local function free_name(repo, text)
  local base = text:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):sub(1, 40):gsub("%-+$", "")
  base = base ~= "" and base or "surface"
  local dir = M.dir(repo)
  local name, n = base, 1
  while vim.uv.fs_stat(dir .. "/" .. name .. ".surface") or vim.uv.fs_stat(dir .. "/" .. name .. ".md") do
    n = n + 1
    name = ("%s-%d"):format(base, n)
  end
  return name
end

local function surface_file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".surface"
end

-- Writes a .surface for the repo, refusing a name a markdown surface or another type has.
local function put(repo, name, data)
  local dir = M.dir(repo)
  if vim.uv.fs_stat(dir .. "/" .. name .. ".md") then
    return nil, ("%s.md already has the name %s"):format(name, name)
  end
  vim.fn.mkdir(dir, "p")
  write_json(surface_file(repo, name), data)
  return true
end

-- Asks a question in the repo, or finds it asked already: by name (spec.name, or name), else by
-- the same question, options, multi and other. A pending question of that name asked differently
-- is reworded in place; an answered one keeps its answer. by is who asks (<ws>/<agent>), which its
-- view shows; yours makes it the user's alone from the start (raised by isovim: a permission request).
---@param spec table as M.validate_question takes it
---@return isovim.Surface? entry, string how_or_err "asked", "reattached", "reworded", "kept" (answered
--- before it was asked differently), or what's wrong
function M.ask(repo, spec, name, by, yours)
  repo = canon(repo)
  local q, err, asked_name = M.validate_question(spec)
  if not q then
    return nil, err
  end
  name = name or asked_name
  local key = question_key(q)
  local existing = vim.tbl_filter(function(entry)
    return entry.type == "question" and (name and entry.name == name or (not name and entry.key == key))
  end, M.read(repo))[1]
  if name and not existing and vim.uv.fs_stat(surface_file(repo, name)) then
    return nil, ("%s/%s is already a surface, and not a question"):format(repo, name)
  end
  local how = existing and existing.key ~= key and "kept" or "reattached"
  if existing and existing.key ~= key and not existing.answer then
    how = "reworded"
    put(repo, existing.name, { type = "question", question = q.question, options = q.options, multi = q.multi,
      other = q.other, created = existing.created, raised = existing.raised, raised_by = existing.raised_by,
      why = existing.why, by = existing.asker or by })
  elseif not existing then
    how = "asked"
    name = name or free_name(repo, q.question)
    local ok, why = put(repo, name, { type = "question", question = q.question, options = q.options, multi = q.multi,
      other = q.other, created = os.time(), by = by, raised = yours or nil, raised_by = yours and "isovim" or nil })
    if not ok then
      return nil, why
    end
  end
  return scanned(repo, existing and existing.name or name), how
end

-- Makes a pending question the user's alone, from the root by (its raise), with why, its one-line
-- recommendation: it's in the host Inbox from then on, and no root answers it.
---@return isovim.Surface? entry, string? err
function M.raise(entry, by, why)
  local current = M.get(entry.repo, entry.name)
  if not current or current.type ~= "question" or current.answer then
    return nil, ("%s/%s isn't a pending question"):format(entry.repo, entry.name)
  end
  locked(entry.repo, function()
    if current.thread then
      require("isovim.threads").raise(entry.repo, current.thread.id, current.thread.qid, by, why)
      return
    end
    local data = vim.json.decode(read_file(current.file))
    data.raised, data.raised_by, data.why = true, by, why
    write_json(current.file, data)
  end)
  return scanned(entry.repo, entry.name)
end

-- The repo's pending questions open to a root that keep picks (the ones a root is in charge of)
-- and nobody told it of yet, marked told now (in the scan's state, not the surface), so each is
-- handed out once whoever asks. all returns them told before or not (root mode turning on lists
-- what waits).
---@param keep fun(entry: isovim.Surface): boolean
---@return isovim.Surface[]
function M.take_untold(repo, keep, all)
  repo = canon(repo)
  return locked(repo, function()
    local state = read_state(repo)
    local taken = {}
    for _, entry in ipairs(M.read(repo, state)) do
      local seen = state[entry.base]
      if entry.type == "question" and not entry.answer and not entry.raised and seen and (all or not seen.told)
        and keep(entry) then
        seen.told = true
        taken[#taken + 1] = entry
      end
    end
    if #taken > 0 then
      write_json(state_file(repo), state)
    end
    return taken
  end)
end

-- Points the repo's Inbox at a file or folder; its name defaults to the path's last part.
---@param kind "file"|"folder"
---@return isovim.Surface? entry, string? err
function M.show(repo, kind, path, name)
  repo = canon(repo)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("(.)/$", "%1")
  name = name or vim.fs.basename(path):gsub("[^%w._-]+", "-")
  local current = M.get(repo, name)
  -- A broken one of its name (its target was missing) is put right by surfacing it again.
  local fixable = current and current.type == "broken" and current.base:match("%.surface$")
  if current and current.type ~= kind and not fixable then
    return nil, ("%s/%s is already a %s surface"):format(repo, name, current.type)
  end
  -- Again, even at the same path, brings it back unread: a surfaced file means look at this.
  local ok, err = put(repo, name, { type = kind, path = path, created = os.time() })
  if not ok then
    return nil, err
  end
  return scanned(repo, name)
end

-- Puts an agent's chat (its address) in the repo's Inbox; again brings it back if it was opened.
---@return isovim.Surface? entry, string? err
function M.chat(repo, address, name)
  repo = canon(repo)
  local ws, id = address:match("^(.*)/([^/]+)$")
  name = name or ("chat-" .. (ws == repo and id or address):gsub("[^%w._-]+", "-"))
  local current = M.get(repo, name)
  if current and current.type ~= "chat" then
    return nil, ("%s/%s is already a %s surface"):format(repo, name, current.type)
  end
  local ok, err = put(repo, name, { type = "chat", agent = address, created = os.time() })
  if not ok then
    return nil, err
  end
  return scanned(repo, name)
end

-- Puts a link to address (an iso: address, isovim.links) in the repo, labelled label; its name
-- defaults to the label's words or the address's last part.
---@return isovim.Surface? entry, string? err
function M.link(repo, address, label, name, note)
  repo = canon(repo)
  if not require("isovim.links").parse(address) then
    return nil, address .. " isn't an iso: address or an http(s) URL (iso <role> link <thing> prints one)"
  end
  name = name or free_name(repo, label or address:match("([^/#]+)[^/]*$") or "link")
  local current = M.get(repo, name)
  if current and current.type ~= "link" then
    return nil, ("%s/%s is already a %s surface"):format(repo, name, current.type)
  end
  local ok, err = put(repo, name, { type = "link", address = address, label = label, note = note, created = os.time() })
  if not ok then
    return nil, err
  end
  return scanned(repo, name)
end

-- answering

local function match_option(entry, word)
  word = vim.trim(word)
  local n = tonumber(word)
  if n and entry.options[n] then
    return entry.options[n].label
  end
  for _, option in ipairs(entry.options) do
    if option.label:lower() == word:lower() then
      return option.label
    end
  end
end

-- An answer to the question from what the user gave: one string (an option's label or number, or
-- other text), or a list of them (several options for a multi question). For a multi question a
-- list is first tried as one label, so unquoted words work.
---@param value string|string[]
---@return {labels: string[], other?: string}? answer, string? err
function M.parse_answer(entry, value)
  local words = type(value) == "table" and vim.list_slice(value, 1) or { value }
  local joined = vim.trim(table.concat(words, " "))
  if joined == "" then
    return nil, "no answer given"
  end
  local whole = match_option(entry, joined)
  if whole then
    return { labels = { whole } }
  elseif not entry.multi then
    if entry.other then
      return { labels = {}, other = joined }
    end
  else
    local labels, rest = {}, {}
    for _, word in ipairs(words) do
      local label = match_option(entry, word)
      if label and not vim.tbl_contains(labels, label) then
        labels[#labels + 1] = label
      elseif not label then
        rest[#rest + 1] = word
      end
    end
    if #rest == 0 then
      return { labels = labels }
    elseif entry.other then
      return { labels = labels, other = table.concat(rest, " ") }
    end
  end
  local listed = {}
  for i, option in ipairs(entry.options) do
    listed[#listed + 1] = ("%d. %s"):format(i, option.label)
  end
  return nil, ("%q isn't one of its options (%s)%s"):format(joined, table.concat(listed, ", "),
    entry.multi and "; give several for a multi question" or "")
end

-- The decision log of a scope: a repo-root's repo, or "root" for the host root's. Append-only and
-- its own file, as the event log ages out and an asker removes its question once answered.
local function decisions_file(key)
  return M.dir(key) .. "/decisions.jsonl"
end

-- The scope's decisions, newest first: {at, by, repo, name, question, labels?, other?, why?}.
---@return table[]
function M.decisions(key)
  local list = {}
  for line in (read_file(decisions_file(key)) or ""):gmatch("[^\n]+") do
    local ok, decision = pcall(vim.json.decode, line)
    if ok and type(decision) == "table" then
      table.insert(list, 1, decision)
    end
  end
  table.sort(list, function(a, b)
    return (a.at or 0) > (b.at or 0)
  end)
  return list
end

-- Only the active root answers as an agent (isovim.rootmode.may_answer), so by is a root: its
-- decision goes in its own scope's log, whichever repo's question it was.
local function log_decision(question, answer, why)
  local ws, id = answer.by:match("^(.*)/([^/]+)$")
  local key = ws and require("isovim.scope").of_agent(ws, id) or question.repo
  vim.fn.mkdir(M.dir(key), "p")
  local file = io.open(decisions_file(key), "a")
  if file then
    file:write(vim.json.encode({ at = answer.at, by = answer.by, repo = question.repo, name = question.name,
      question = question.question or question.title, labels = answer.labels, other = answer.other, why = why }), "\n")
    file:close()
  end
end

-- The decision log as a surface: nil for a scope with no decisions, unless empty (the sidebar's row
-- under a root that hasn't decided anything yet).
---@param empty? boolean
---@return isovim.Surface?
function M.decisions_entry(key, empty)
  local file = decisions_file(key)
  local _, count = (read_file(file) or ""):gsub("\n", "")
  if count == 0 and not empty then
    return nil
  end
  return { repo = canon(key), name = "Decisions", base = "Decisions", type = "decisions", title = "Decisions", file = file,
    error_file = "", created = 0, needs_you = false, count = count, sig = tostring(count) }
end

-- Answers a pending question: value as M.parse_answer takes it, or {labels, other?}. by is who
-- answered ("user" by default, or an agent's address). A root's answer goes in its decision log, with
-- why if it gave one. Publishes surface.<repo>.<name>.answered.
---@param why? string
---@return {labels: string[], other?: string, by: string, at: number}? answer, string? err
function M.answer(entry, value, by, why)
  local current = M.get(entry.repo, entry.name)
  if not current or current.type ~= "question" then
    return nil, ("%s/%s isn't a question any more"):format(entry.repo, entry.name)
  elseif current.answer then
    return nil, ("%s/%s is already answered"):format(entry.repo, entry.name)
  end
  local answer, err
  if type(value) == "table" and (value.labels or value.other) then
    answer = { labels = {}, other = value.other ~= "" and value.other or nil }
    for _, word in ipairs(value.labels or {}) do
      local label = match_option(current, word)
      if not label then
        return nil, ("%q isn't one of its options"):format(word)
      elseif not vim.tbl_contains(answer.labels, label) then
        answer.labels[#answer.labels + 1] = label
      end
    end
    if answer.other and not current.other then
      return nil, "it takes only its options, not your own words"
    elseif #answer.labels == 0 and not answer.other then
      return nil, "no answer given"
    elseif #answer.labels > 1 and not current.multi then
      return nil, "it takes one option"
    end
  else
    answer, err = M.parse_answer(current, value)
  end
  if not answer then
    return nil, err
  end
  answer.by, answer.at = by or "user", os.time()
  if answer.by ~= "user" then
    log_decision(current, answer, why)
  end
  if current.thread then
    -- Asked in a thread: its answer goes there, where the asker's thread ask waits for it.
    locked(entry.repo, function()
      require("isovim.threads").answer(entry.repo, current.thread.id, current.thread.qid, answer)
      publish(current, "answered", { title = current.title, answer = answer })
    end)
    M.scan(entry.repo)
    return answer
  end
  local data = vim.json.decode(read_file(current.file))
  data.answer = answer
  -- Written and published under the scan lock: the asker can collect the answer (removing the
  -- file) the moment it lands, and a scan that sees it gone (the asker's, the TUI's watcher's)
  -- must publish removed after answered.
  locked(entry.repo, function()
    write_json(current.file, data)
    publish(current, "answered", { title = current.title, answer = answer })
  end)
  M.scan(entry.repo, { [current.base] = true })
  return answer
end

-- The answer as its asker prints it: one chosen label a line, then any other text.
function M.answer_text(answer)
  local lines = vim.deepcopy(answer.labels or {})
  if answer.other and answer.other ~= "" then
    lines[#lines + 1] = answer.other
  end
  return table.concat(lines, "\n")
end

-- Takes an answered question's answer and removes it; nil while it's pending.
---@return table? answer
function M.collect(repo, name)
  repo = canon(repo)
  local entry = M.get(repo, name)
  if not (entry and entry.type == "question" and entry.answer) then
    return nil
  end
  os.remove(entry.file)
  M.scan(repo)
  return entry.answer
end

local notify ---@type fun(repo: string, entries: isovim.Surface[])? M.watch's on_change

-- Takes a surface out of the Inbox because the user opened it: a chat is removed, a consumable
-- markdown surface hidden until the router changes it. Publishes surface.<repo>.<name>.consumed.
---@return boolean consumed
function M.consume(entry)
  if entry.type == "chat" then
    os.remove(entry.file)
    publish(entry, "consumed", { agent = entry.agent })
    M.scan(entry.repo)
    return true
  elseif (entry.type == "markdown" and entry.consumable or entry.type == "file" or entry.type == "folder" or entry.type == "link")
    and not entry.consumed then
    locked(entry.repo, function()
      local state = read_state(entry.repo)
      state[entry.base] = vim.tbl_extend("force", state[entry.base] or { first = entry.created }, { consumed = entry.sig })
      write_json(state_file(entry.repo), state)
    end)
    publish(entry, "consumed")
    if M.cache[entry.repo] then
      M.cache[entry.repo] = M.read(entry.repo)
      if notify then
        notify(entry.repo, M.cache[entry.repo])
      end
    end
    return true
  end
  return false
end

-- the TUI

M.cache = {} ---@type table<string, isovim.Surface[]> per repo, while watching

-- The user's d in the sidebar, his own action, so the rule that only the router writes iso/ isn't
-- his to keep.

-- isovim's own view of a repo's PRs, if the user hid it: by base, with the sig it had then, hidden
-- until it changes (a new PR).
local function hidden_file(repo)
  return store.run_dir(canon(repo)) .. "/hidden.json"
end

local function read_hidden(repo)
  local ok, value = pcall(vim.json.decode, read_file(hidden_file(repo)) or "")
  return ok and type(value) == "table" and value or {}
end

local function changed(repo)
  if M.cache[repo] then
    M.cache[repo] = M.read(repo)
    if notify then
      notify(repo, M.cache[repo])
    end
  end
end

-- Why the key can't mark entry either way, or nil: someone is blocked on it, or it holds no read
-- state.
local function unmarkable(entry)
  if entry.type == "question" then
    return entry.answer and "it's answered: nothing to mark"
      or entry.deciding and "a root is deciding it first"
      or "it waits on you until it's answered: its asker is blocked on it"
  elseif entry.type == "decisions" then
    return "it's a log: nothing in it waits on you"
  elseif entry.type == "thread" and entry.resolved and not entry.needs_you then
    return "it's resolved: r in it opens it again"
  elseif entry.type == "page" and (entry.waiting or 0) > 0 then
    return entry.waiting == 1 and "a comment here waits on your reply" or ("%d comments here wait on your reply"):format(entry.waiting)
  elseif entry.type == "prs" and (entry.waiting or 0) > 0 then
    return entry.waiting == 1 and "a PR waits on you" or ("%d PRs wait on you"):format(entry.waiting)
  end
end

-- Back in the Inbox, needs_you, staying there after you leave it even though it's open now, until you
-- next open it (M.opened).
local function mark_unread(entry)
  local repo = canon(entry.repo)
  locked(repo, function()
    local unread = read_unread(repo)
    unread[entry.base] = true
    write_json(unread_file(repo), unread)
  end)
  changed(repo)
end

-- Out of the Inbox, with everything that holds it there: what you marked unread, what you haven't
-- opened, and on a thread your turn (isovim.threads.dismiss), till the agent's next post.
function M.mark_read(entry)
  if entry.type == "thread" then
    require("isovim.threads").dismiss(entry.repo, entry.name)
    M.opened(entry.repo, entry.base)
    M.scan(entry.repo)
    M.recheck()
  else
    M.opened(entry.repo, entry.base)
    M.consume(entry)
  end
  local still = entry.type == "thread" and (entry.pending or 0) > 0
  vim.api.nvim_echo({ { still and "marked read; its question still waits on you" or "marked read", "Comment" } }, false, {})
end

-- u in a view, U on a row: if it's holding your attention it goes read, else it goes unread. What
-- someone's blocked on stays, and it says so. Says what it did, in one quiet line.
function M.toggle_read(entry)
  local why = unmarkable(entry)
  if why then
    return vim.api.nvim_echo({ { why, "Comment" } }, false, {})
  elseif entry.needs_you then
    return M.mark_read(entry)
  end
  mark_unread(entry)
  vim.api.nvim_echo({ { "marked unread", "Comment" } }, false, {})
end

-- You opened it: what you marked unread is read again.
function M.opened(repo, base)
  repo = canon(repo)
  if not read_unread(repo)[base] then
    return
  end
  locked(repo, function()
    local unread = read_unread(repo)
    unread[base] = nil
    write_json(unread_file(repo), unread)
  end)
  changed(repo)
end

-- Removes a surface: its file, its error file, a page's comments. A file or folder surface only
-- points, so what it names stays. The scan publishes surface.<repo>.<name>.removed.
function M.remove(entry)
  M.opened(entry.repo, entry.base)
  os.remove(entry.file)
  if entry.error_file and entry.error_file ~= "" then
    os.remove(entry.error_file)
  end
  if entry.type == "page" then
    os.remove(require("isovim.pages").comments_file(entry.repo, entry.name))
    os.remove(require("isovim.pages").dives_file(entry.repo, entry.name))
    require("isovim.pages").forget_activity(entry.repo, entry.name)
  end
  M.scan(entry.repo)
  changed(entry.repo)
end

-- Hides the PRs surface until it changes. Publishes surface.<repo>.<name>.removed.
function M.hide(entry)
  locked(entry.repo, function()
    local hidden = read_hidden(entry.repo)
    hidden[entry.base] = entry.sig
    write_json(hidden_file(entry.repo), hidden)
  end)
  publish(entry, "removed", { hidden = true })
  changed(entry.repo)
end

local DAY = 24 * 3600

-- The PRs surface: isovim's own, not a router's file, for a repo (or the root) with PRs registered
-- (iso <role> pr). Each PR as isovim.prs last fetched it, never waiting on the network, with who
-- registered it, grouped open, draft, merged and closed; one merged or closed over a day ago drops
-- off. It waits on you while a PR does (isovim.prs.needs_you), with how many.
---@return isovim.Surface?
---@param empty? boolean an entry even with no PRs registered (P and <leader>io open it, saying so)
function M.prs_entry(repo, empty)
  local urls = store.prs(repo)
  if #urls == 0 and not empty then
    return nil
  end
  local prs = require("isovim.prs")
  local cached, info, now = prs.cached(repo), store.pr_info(repo), os.time()
  local groups, waiting, shown = { open = {}, draft = {}, merged = {}, closed = {} }, 0, 0
  local visible, order = {}, {}
  for i = #urls, 1, -1 do
    local pr = vim.tbl_extend("force", { url = urls[i] }, cached[urls[i]] or {})
    pr.by, pr.registered = (info[urls[i]] or {}).by, (info[urls[i]] or {}).at
    local group = pr.state == "MERGED" and "merged" or pr.state == "CLOSED" and "closed" or pr.isDraft and "draft" or "open"
    local ended = prs.time(pr.mergedAt or pr.closedAt)
    if not ((group == "merged" or group == "closed") and ended and now - ended > DAY) then
      table.insert(groups[group], pr)
      visible[urls[i]], order[#order + 1] = pr, urls[i]
      shown = shown + 1
      waiting = waiting + (prs.needs_you(pr) and 1 or 0)
    end
  end
  return {
    repo = repo,
    name = "PRs",
    base = "PRs",
    type = "prs",
    title = "PRs",
    file = M.dir(repo) .. "/.isovim.json",
    error_file = "",
    created = 0,
    needs_you = waiting > 0,
    waiting = waiting,
    count = shown,
    registered = #urls,
    groups = groups,
    sections = M.prs_sections(repo, visible, order),
    sig = vim.fn.sha256(vim.json.encode({ groups, waiting, prs.groups(repo) })),
  }
end

-- The router's groups of the PRs shown, in its order, each {name, note?, prs} with its PRs in the
-- order it gave them; a group left empty (its PRs merged or closed a day ago, or gone) is left out,
-- and the PRs in none go last, in Other. nil when no group holds any: the state sections instead.
function M.prs_sections(repo, visible, order)
  local sections, grouped = {}, {}
  for _, group in ipairs(require("isovim.prs").groups(repo)) do
    local list = {}
    for _, url in ipairs(group.prs or {}) do
      if visible[url] and not grouped[url] then
        list[#list + 1], grouped[url] = visible[url], true
      end
    end
    if #list > 0 then
      sections[#sections + 1] = { name = group.name, note = group.note, prs = list }
    end
  end
  if #sections == 0 then
    return nil
  end
  local other = {}
  for _, url in ipairs(order) do
    if not grouped[url] then
      other[#other + 1] = visible[url]
    end
  end
  if #other > 0 then
    sections[#sections + 1] = { name = "Other", prs = other }
  end
  return sections
end

-- A repo's surfaces: the watcher's while M.watch runs, else scanned now; and its PRs surface, made
-- each time from the PRs' cache.
---@return isovim.Surface[]
function M.list(repo)
  repo = canon(repo)
  local list = M.cache[repo] or M.scan(repo)
  local board = M.prs_entry(repo)
  if board and read_unread(repo)[board.base] then
    board.needs_you, board.marked_unread = true, true
  end
  for _, own in ipairs({ board or false, M.decisions_entry(repo) or false }) do
    if own and not vim.iter(list):any(function(entry)
      return entry.name == own.name
    end) then
      list = vim.list_extend(vim.list_slice(list), { own })
    end
  end
  local hidden = read_hidden(repo)
  if next(hidden) then
    list = vim.tbl_filter(function(entry)
      return hidden[entry.base] ~= entry.sig
    end, list)
  end
  return list
end

-- Opens a surface in the TUI: a markdown surface rendered with an input box
-- under it, a question as a buffer that answers it (both isovim.surface_view), a broken one's
-- file, a file as a tab in the main window, a folder as the explorer's root; a chat in the chat
-- window. Opening consumes what's
-- consumable.
function M.open(entry)
  local isovim = require("isovim")
  M.opened(entry.repo, entry.base)
  local function reveal(path)
    if not pcall(isovim.reveal, entry.repo, path) then
      isovim.show(path)
    end
  end
  if entry.error then
    vim.notify(("%s: %s"):format(entry.base, entry.error), vim.log.levels.WARN)
  end
  if entry.type == "task" then
    -- In the board's own buffer.
    require("isovim.thread_board").open_task(entry.repo, entry.name)
  elseif entry.type == "threads" then
    require("isovim.thread_board").open(entry)
  elseif entry.type == "prs" or entry.type == "decisions" then
    -- Drawn by isovim: its PRs or its decisions.
    require("isovim.surface_view").open(entry)
  elseif entry.type == "markdown" then
    -- Rendered, with an input box to the repo's router under it.
    require("isovim.surface_view").open(entry)
    M.consume(entry)
  elseif entry.type == "page" then
    -- Rendered, its comments drawn on it, commented on in the input box under it.
    require("isovim.surface_view").open(entry)
  elseif entry.type == "thread" then
    -- The thread's view: the chat's look, its composer posting to the router.
    require("isovim.acp.chat").open_thread(entry.repo, entry.name)
  elseif entry.type == "broken" then
    reveal(entry.file)
    M.consume(entry)
  elseif entry.type == "file" or entry.type == "folder" then
    if entry.exists then
      -- Its tab is its repo's, wherever the file is: opening it doesn't leave the project.
      vim.b[vim.fn.bufadd(entry.path)].isovim_scope = entry.repo
      reveal(entry.path)
      M.consume(entry)
    end
  elseif entry.type == "chat" then
    M.consume(entry)
    local ws, id = entry.agent:match("^(.*)/([^/]+)$")
    if ws then
      isovim.open(ws, id)
    end
  elseif entry.type == "link" then
    require("isovim.links").open(entry.address)
    M.consume(entry)
  elseif entry.type == "question" and entry.thread then
    -- Asked in a thread: the thread, at the question, answered there.
    require("isovim.acp.chat").open_thread(entry.repo, entry.thread.id, entry.thread.qid)
  elseif entry.type == "question" then
    -- A buffer of its own that answers it, then shows the answer.
    require("isovim.surface_view").open(entry)
  end
end

local handles = {}

-- Watches again from the work root as it is now, if watching (the work root moved: isovim.migrate).
function M.rewatch()
  if next(handles) then
    M.watch(notify)
  end
end

-- Set by M.watch; nothing to do while nothing watches.
function M.recheck() end

function M.unwatch()
  for key, handle in pairs(handles) do
    if not handle:is_closing() then
      handle:close()
    end
    handles[key] = nil
  end
  M.cache = {}
end

-- Watches every repo's iso/ (and the work root, its owners and repos, for new ones) and rescans a
-- repo when its iso/ changes; every 5s it also looks for new repos and for file, folder and chat
-- targets that came or went. on_change(repo, entries) runs after each rescan that saw a change.
---@param on_change? fun(repo: string, entries: isovim.Surface[])
function M.watch(on_change)
  M.unwatch()
  notify = on_change
  local timers = {}
  -- needs_you too: root mode turning on or off changes it without touching the file.
  local function signature(entries)
    return table.concat(vim.tbl_map(function(entry)
      return entry.base .. entry.sig .. tostring(entry.needs_you)
    end, entries), "\n")
  end
  local function rescan(repo)
    local before = signature(M.cache[repo] or {})
    M.cache[repo] = M.scan(repo)
    require("isovim.safe").wrap("a page's dives", require("isovim.pages").sync)(repo, M.cache[repo])
    if package.loaded["isovim.surface_view"] then
      require("isovim.surface_view").threads_changed(repo)
    end
    if signature(M.cache[repo]) ~= before then
      if on_change then
        on_change(repo, M.cache[repo])
      end
      -- Open rendered views follow their file.
      local view = package.loaded["isovim.surface_view"]
      if view then
        view.changed(repo, M.cache[repo])
      end
    end
  end
  -- Taken now: an fs_event's callback runs in a fast event, where a require can't load anything,
  -- and in a hot reload it can land with every module unloaded. A reload's new watch rescans what
  -- a skipped scan would have.
  local safe = require("isovim.safe")
  local activity_name = require("isovim.pages").ACTIVITY_NAME
  local discover
  -- True when it starts watching dir.
  local function watch_dir(dir, on_event)
    if handles[dir] then
      return false
    end
    local handle = assert(vim.uv.new_fs_event())
    if handle:start(dir, {}, function(err)
      if not err then
        on_event()
      end
    end) then
      handles[dir] = handle
      return true
    end
    handle:close()
    return false
  end
  local function soon(key, fn)
    local timer = timers[key] or assert(vim.uv.new_timer())
    timers[key] = timer
    handles["timer:" .. key] = timer
    timer:stop()
    timer:start(100, 0, safe.ticker("the surfaces' scan", fn))
  end
  discover = function()
    -- Never an old work root again, once isovim.migrate has moved it from under this process.
    if store.work == store.new_work then
      vim.fn.mkdir(store.work, "p")
    elseif not vim.uv.fs_stat(store.work) then
      return
    end
    watch_dir(store.work, function()
      soon("discover", discover)
    end)
    for owner, kind in vim.fs.dir(store.work) do
      if kind == "directory" and not vim.startswith(owner, ".") then
        watch_dir(store.work .. "/" .. owner, function()
          soon("discover", discover)
        end)
        for repo, repo_kind in vim.fs.dir(store.work .. "/" .. owner) do
          if repo_kind == "directory" and repo ~= "iso" and not vim.startswith(repo, ".") then
            watch_dir(store.work .. "/" .. owner .. "/" .. repo, function()
              soon("discover", discover)
            end)
          end
        end
      end
    end
    for _, repo in ipairs(M.repos()) do
      local function changed()
        soon(repo, function()
          rescan(repo)
        end)
      end
      if not M.cache[repo] then
        watch_dir(M.dir(repo), changed)
        rescan(repo)
      end
      -- What the router's doing about its pages: told at once, as nothing in iso/ changes for it.
      local run = store.run_dir(repo)
      local key = "activity:" .. repo
      if not handles[key] and vim.fn.isdirectory(run) == 1 then
        local handle = assert(vim.uv.new_fs_event())
        if handle:start(run, {}, function(err, name)
          if not err and name == activity_name then
            soon(key, function()
              if M.cache[repo] then
                M.relate_activity(M.cache[repo])
                if notify then
                  notify(repo, M.cache[repo])
                end
              end
              require("isovim.pages").activity_changed(repo)
            end)
          end
        end) then
          handles[key] = handle
        else
          handle:close()
        end
      end
      -- Its pages and their comments, once it has any (made later: within 5s, and scanned then).
      for _, sub in ipairs({ "pages", "threads" }) do
        if vim.fn.isdirectory(M.dir(repo) .. "/" .. sub) == 1 and watch_dir(M.dir(repo) .. "/" .. sub, changed) then
          rescan(repo)
        end
      end
    end
  end
  discover()
  -- Every repo again, as root mode turning on or off (iso rootmode calls it) changes which
  -- questions wait on you.
  M.recheck = function()
    for repo in pairs(M.cache) do
      rescan(repo)
    end
  end
  local function rootmode_stamp()
    local stat = vim.uv.fs_stat(require("isovim.rootmode").file)
    return stat and ("%d.%d"):format(stat.mtime.sec, stat.mtime.nsec) or ""
  end
  local mode = rootmode_stamp()
  local tick = assert(vim.uv.new_timer())
  handles["timer:tick"] = tick
  tick:start(5000, 5000, safe.ticker("the surfaces' check", function()
    discover()
    if rootmode_stamp() ~= mode then
      mode = rootmode_stamp()
      M.recheck()
    end
    for repo, entries in pairs(M.cache) do
      local stale = vim.iter(entries):any(function(entry)
        if entry.type == "file" or entry.type == "folder" then
          return (vim.uv.fs_stat(entry.path) ~= nil) ~= entry.exists
        elseif entry.type == "chat" then
          local ws, id = entry.agent:match("^(.*)/([^/]+)$")
          return (ws and store.agent(ws, id) ~= nil) ~= (entry.error == nil)
        end
      end)
      -- A page's item whose turn or prompt nothing will finish.
      if vim.iter(entries):any(function(entry)
        return entry.type == "page" and (entry.moving or 0) > 0
      end) then
        require("isovim.pages").end_stale(repo)
      end
      -- A thread still working, whose router's supervisor may have died mid-turn.
      if vim.iter(entries):any(function(entry)
        return entry.type == "thread" and entry.working
      end) and require("isovim.threads").end_dead_turns(repo) then
        stale = true
      end
      if stale then
        rescan(repo)
      end
    end
  end))
end

return M
