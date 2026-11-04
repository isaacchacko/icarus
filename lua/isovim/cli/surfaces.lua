-- Surfaces on the command line (isovim.surfaces): iso router surface question|file|folder|chat puts
-- one in the router's repo's Inbox, iso <role> page comments|reply|resolve reads and answers the
-- comments on a page (isovim.pages), iso answer answers a question (also iso <root|repo-root>
-- answer), and iso __surfaces prints a repo's surfaces as JSON, scanning them first. In root mode
-- the root answers the Inbox's questions with you, the first answer winning (isovim.rootmode).
local store = require("isovim.store")
local surfaces = require("isovim.surfaces")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local option = c.option
local flag = c.flag

local M = {}

local function note(text)
  io.stderr:write("iso: " .. text .. "\n")
end

-- A repo key from what was typed: owner/repo, a pseudo-repo (root, general, or _ for general), or a
-- dir in the repo.
local function repo_key(text)
  local dir = vim.fs.normalize(text)
  if surfaces.pseudo[text] or text == "_" then
    return surfaces.key(text)
  elseif vim.fn.isdirectory(dir) == 1 then
    return require("isovim.repos").of(vim.uv.fs_realpath(dir) or dir) or fail(text .. " isn't in a repo with an origin")
  elseif store.valid_key(text) then
    return text:lower()
  end
  fail(("%s is neither a repo (owner/repo, root or general) nor a dir in one"):format(text))
end

-- The repo whose Inbox a surface goes in: the calling agent's (root for the host root, a new-layout
-- agent's key, a workspace agent's checkout's origin, general for no repo), else --repo, else the
-- cwd's.
local function my_repo(given)
  local ws, agent = require("isovim.root").caller()
  local mine
  if ws and require("isovim.scope").is_root(ws, vim.tbl_extend("force", store.agent(ws, agent) or {}, { id = agent })) then
    mine = "root"
  elseif ws and store.v2(ws) then
    mine = surfaces.key(ws)
  elseif ws then
    mine = require("isovim.repos").of(store.dir(ws)) or "general"
  end
  local named = given and repo_key(given)
  if mine and named and named ~= mine then
    fail(("a router's surfaces are its own repo's, %s, not %s"):format(mine, named))
  end
  return mine or named or require("isovim.repos").of(vim.uv.cwd())
    or fail("which repo? run it from the router's pane, or pass --repo owner/repo")
end

-- The question's JSON: a file, - for stdin, or the words themselves.
local function question_spec(args)
  local text = table.concat(args, " ")
  if text == "-" then
    text = io.stdin:read("*a")
  elseif #args == 1 and vim.fn.filereadable(vim.fs.normalize(args[1])) == 1 then
    text = table.concat(vim.fn.readfile(vim.fs.normalize(args[1])), "\n")
  end
  if vim.trim(text) == "" then
    fail("usage: iso router surface question <json|file|-> [--name n]: " .. surfaces.question_shape)
  end
  local ok, spec = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    fail("the question isn't JSON: " .. tostring(spec):gsub("^.-:%d+: ", "") .. "; it's " .. surfaces.question_shape)
  end
  return spec
end

-- Blocks until the question is answered (by the user or a root), prints the answer and removes
-- the question.
local function await(entry)
  local done = false
  local watcher = assert(vim.uv.new_fs_event())
  watcher:start(surfaces.dir(entry.repo), {}, function()
    done = true
  end)
  for _, name in ipairs({ "sigterm", "sigint", "sighup" }) do
    vim.uv.new_signal():start(name, function()
      os.exit(130)
    end)
  end
  local answer
  while true do
    answer = surfaces.collect(entry.repo, entry.name)
    if answer then
      break
    elseif not vim.uv.fs_stat(entry.file) then
      fail(("%s/%s was removed without an answer"):format(entry.repo, entry.name))
    end
    done = false
    -- The watcher wakes it; the poll covers a filesystem that doesn't say.
    vim.wait(5000, function()
      return done
    end, 5000)
  end
  watcher:close()
  out(surfaces.answer_text(answer))
end

local function question(args)
  local name = option(args, "--name")
  local repo = my_repo(option(args, "--repo"))
  local spec = question_spec(args)
  local q, err = surfaces.validate_question(spec)
  if not q then
    fail(err)
  end
  local ws, agent = require("isovim.root").caller()
  local from = ws and (ws .. "/" .. agent) or nil
  local entry, how = surfaces.ask(repo, spec, name, from)
  if not entry then
    fail(how)
  end
  local id = entry.repo .. "/" .. entry.name
  local root = require("isovim.rootmode").root_for(entry)
  if root and how == "asked" then
    note(("root mode: %s, the root, decides %s first; it reaches the user if it raises it"):format(root, id))
  end
  if how == "kept" then
    note(id .. " was answered before it was asked this way; its answer stands")
  elseif entry.answer then
    note(id .. " is answered already")
  elseif how == "asked" then
    note(("asked %s; waiting for the answer (iso answer %s <answer>)"):format(id, entry.name))
  else
    note(("%s %s; waiting for the answer"):format(how == "reworded" and "reworded" or "reattached to", id))
  end
  await(entry)
end

local function show(kind, args)
  local name = option(args, "--name")
  local repo = my_repo(option(args, "--repo"))
  local path = args[1] or fail(("usage: iso router surface %s <path> [--name n]"):format(kind))
  local entry, err = surfaces.show(repo, kind, path, name)
  if not entry then
    fail(err)
  end
  if entry.error then
    note(("%s; %s says so until it's fixed"):format(entry.error, store.home_relative(entry.error_file)))
  end
  out(entry.file)
end

local function chat(args)
  local name = option(args, "--name")
  local repo = my_repo(option(args, "--repo"))
  local ws, agent = c.resolve_agent(args[1] or fail("usage: iso router surface chat <agent> [--name n]"))
  local entry, err = surfaces.chat(repo, ws.id .. "/" .. agent.id, name)
  if not entry then
    fail(err)
  end
  out(entry.file)
end

-- iso router surface question|file|folder|chat ...
function M.surface(args)
  local sub = table.remove(args, 1)
  if sub == "question" then
    question(args)
  elseif sub == "file" or sub == "folder" then
    show(sub, args)
  elseif sub == "chat" then
    chat(args)
  elseif sub == "link" then
    local name = option(args, "--name")
    local note = option(args, "--note")
    local title = option(args, "--title")
    local repo = my_repo(option(args, "--repo"))
    local address = table.remove(args, 1)
      or fail('usage: iso router surface link <url|iso:...|thing> [label] [--note "one line"] [--name n]')
    if not address:match("^iso:") then
      local made, why = require("isovim.links").address(address, repo)
      address = made or fail(why)
    end
    local label = title or vim.trim(table.concat(args, " "))
    local entry, err = surfaces.link(repo, address, label ~= "" and label or nil, name, note)
    if not entry then
      fail(err)
    end
    out(entry.file)
  else
    fail("usage: iso router surface question|file|folder|chat|link ...; iso router help says more")
  end
end

-- A question by name, or <repo>/<name>, pending in any repo here.
local function find_question(query)
  local repo, name = query:match("^(.*)/([^/]+)$")
  local found = {}
  for _, key in ipairs(repo and { surfaces.key(repo:lower()) or repo:lower() } or surfaces.repos()) do
    for _, entry in ipairs(surfaces.scan(key)) do
      if entry.type == "question" and entry.name == (name or query) then
        found[#found + 1] = entry
      end
    end
  end
  if #found > 1 then
    fail(("%s names a question in %d repos: %s"):format(query, #found, table.concat(vim.tbl_map(function(entry)
      return entry.repo .. "/" .. entry.name
    end, found), ", ")))
  end
  return found[1] or fail("no question " .. query .. " is waiting")
end

local function print_question(entry)
  out(entry.question .. (entry.multi and " (pick any)" or ""))
  for i, option in ipairs(entry.options) do
    out(("  %d. %s%s"):format(i, option.label, option.description and (" · " .. option.description) or ""))
  end
  if entry.other then
    out("  or your own words")
  end
end

-- The root-mode scope a root answers for: "host" for the host root, else the repo key of the repo
-- root (rootmode's entry first, then its record).
local function root_scope(me, entry)
  local rootmode = require("isovim.rootmode")
  if rootmode.active("host") == me then
    return "host"
  elseif rootmode.active(entry.repo) == me then
    return entry.repo
  end
  local ws, id = me:match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, id)
  if record and store.role(record) == "root" then
    return "host"
  end
  return store.v2(ws) and ws or entry.repo
end

-- root.<scope>.raised|decided: a root gave a question to the user, or answered it itself.
local function publish_root(what, me, entry, details)
  local events = require("isovim.events")
  local scope = root_scope(me, entry)
  events.publish(events.topic("root", scope, what), vim.tbl_extend("force", {
    scope = scope, root = me, question = entry.repo .. "/" .. entry.name, repo = entry.repo, name = entry.name,
    text = entry.question,
  }, details or {}))
end

-- iso answer <question> <answer...>, and a root's iso <root|repo-root> answer, which takes any
-- question in the Inbox root mode has it clear (isovim.rootmode.may_answer), and --raise [why...]
-- to give one to the user, in the host Inbox. A root's answer and its raise are published as
-- root.<scope>.decided and root.<scope>.raised.
function M.answer(args)
  local raise = flag(args, "--raise")
  local why = option(args, "--why")
  local query = table.remove(args, 1) or fail("usage: iso answer <question> <answer...>")
  local entry = find_question(query)
  local id = entry.repo .. "/" .. entry.name
  -- The agent answering; nil for the user, in a shell or one of isovim's terminals.
  local me = require("isovim.cli.roles").caller()
  if me and not entry.answer and not require("isovim.rootmode").may_answer(me, entry) then
    fail(("%s isn't yours to answer: %s"):format(id, entry.raised and "it's the user's"
      or entry.asker == me and "you asked it"
      or "only the user, and a root while root mode is on for its repo or the host, answer it"))
  end
  if raise then
    if not me then
      fail("raising is a root's, to give a question to you")
    elseif entry.answer then
      fail(("%s is already answered: %s"):format(id, surfaces.answer_text(entry.answer)))
    end
    local raised_why = vim.trim(table.concat(args, " "))
    raised_why = raised_why ~= "" and raised_why:gsub("%s+", " ") or nil
    local raised, err = surfaces.raise(entry, me, raised_why)
    if not raised then
      fail(err)
    end
    publish_root("raised", me, entry, { why = raised_why })
    out(id .. " is in the user's host Inbox now" .. (raised_why and "" or "; a one-line why helps them: iso <role> raise <question> <why>"))
    c.tui("require('isovim.surfaces').recheck()")
    return
  end
  if #args == 0 then
    print_question(entry)
    fail(("usage: iso answer %s <answer...>"):format(query))
  elseif entry.answer then
    fail(("%s/%s is already answered: %s"):format(entry.repo, entry.name, surfaces.answer_text(entry.answer)))
  end
  local answer, err = surfaces.answer(entry, args, me or "user", why)
  if not answer then
    fail(err)
  end
  if me then
    publish_root("decided", me, entry, { answer = answer })
  end
  out(surfaces.answer_text(answer))
end

-- A root's iso <root|repo-root> raise <question> [why...]: gives the question to the user, in the
-- host Inbox, with a one-line why (its recommendation); iso <role> answer <question> --raise [why].
function M.raise(args)
  table.insert(args, "--raise")
  M.answer(args)
end

-- A page from what was typed: <repo>/<name>, or a name in the caller's repo.
local function page_ref(text)
  local pages = require("isovim.pages")
  local repo, name = text:match("^(.*)/([^/]+)$")
  repo = repo and surfaces.key(repo:lower())
  if not repo then
    repo, name = my_repo(nil), text
  end
  name = name:gsub("%.md$", "")
  if not vim.uv.fs_stat(pages.file(repo, name)) then
    fail(("%s has no page %s (%s)"):format(repo, name, pages.file(repo, name)))
  end
  return repo, name
end

local function print_comment(pages, comment)
  local lines = comment.from == comment.to and ("line %d"):format(comment.from) or ("lines %d-%d"):format(comment.from, comment.to)
  out(("%s [%s] %s%s, %s:"):format(comment.id, comment.status, lines, comment.heading ~= "" and (' "' .. comment.heading .. '"') or "",
    os.date("%Y-%m-%d %H:%M", comment.at)))
  for _, line in ipairs(vim.split(comment.quote, "\n", { plain = true })) do
    out("  > " .. line)
  end
  for _, line in ipairs(vim.split(comment.text, "\n", { plain = true })) do
    out("  " .. line)
  end
  for _, reply in ipairs(comment.replies) do
    out(("  ↳ %s%s: %s"):format(reply.by, reply.ask and " asks" or "", reply.text))
  end
  if comment.status == "resolved" then
    out(("  resolved by %s%s"):format(comment.resolved_by or "?", comment.note and (": " .. comment.note) or ""))
  elseif pages.waiting(comment) then
    out("  (waiting on the user)")
  end
end

-- iso <role> page comments|reply|resolve ...: a page's comments, read, answered and resolved.
function M.page(args)
  local pages = require("isovim.pages")
  local sub = table.remove(args, 1)
  local usage = "usage: iso <role> page comments <page> [--all] | dive <page> <id> <child> | waiting <page> <id> <agent>|none | reply <page> <id> <text...> [--ask] | resolve <page> <id> [<note...>]"
  if sub == "comments" then
    local all = flag(args, "--all")
    local repo, name = page_ref(args[1] or fail(usage))
    local shown = 0
    for _, comment in ipairs((pages.comments(repo, name))) do
      if all or comment.status == "open" then
        print_comment(pages, comment)
        shown = shown + 1
      end
    end
    if shown == 0 then
      out(("%s/%s has no %scomments"):format(repo, name, all and "" or "open "))
    end
    return
  elseif sub == "dive" then
    local repo, name = page_ref(args[1] or fail(usage))
    local id, child = args[2] or fail(usage), (args[3] or fail(usage)):gsub("%.md$", "")
    local address, said = pages.dive(repo, name, id, child)
    if not address then
      fail(said)
    end
    if said then
      note(said)
    end
    surfaces.scan(repo)
    return out(address)
  elseif sub == "waiting" then
    local repo, name = page_ref(args[1] or fail(usage))
    local id, on = args[2] or fail(usage), args[3] or fail(usage)
    if on ~= "none" then
      local ws, agent = c.resolve_agent(on:find("/", 1, true) and on or (repo .. "/" .. on))
      on = ws.id .. "/" .. agent.id
    end
    local marked, err = pages.wait_on(repo, name, id, on)
    if not marked then
      fail(err)
    end
    return out(("%s/%s %s %s"):format(repo, name, id, on == "none" and "is with nobody" or ("is with " .. on)))
  elseif sub ~= "reply" and sub ~= "resolve" then
    fail(usage)
  end
  local ask = flag(args, "--ask")
  local repo, name = page_ref(args[1] or fail(usage))
  local id = args[2] or fail(usage)
  local text = vim.trim(table.concat(vim.list_slice(args, 3), " "))
  local me = require("isovim.cli.roles").caller() or "user"
  local comment, err
  if sub == "reply" then
    if text == "" then
      fail(usage)
    end
    comment, err = pages.reply(repo, name, id, me, text, ask)
  else
    comment, err = pages.resolve(repo, name, id, me, text ~= "" and text or nil)
  end
  if not comment then
    fail(err)
  end
  surfaces.scan(repo)
  out(("%s/%s %s %s"):format(repo, name, id, sub == "reply" and (ask and "asks the user now" or "has your reply") or "is resolved"))
end

-- iso <role> thread new|post|waiting|parent|resolve|ls|show ...: a repo's threads (isovim.threads), the caller's
-- repo's. Any role may make, post and resolve them, workers posting what they found as they do; only
-- the bypass rules are enforced: a router alone moves one, and a worker can't resolve a bypassed thread.
function M.thread(args)
  local threads = require("isovim.threads")
  local sub = table.remove(args, 1)
  local usage = 'usage: iso <role> thread new "<title>" ["first post"] [--no-reply] [--parent <id>|none] | parent <id> <parent>|none | bypass <id> [<worker>|none] | release <reason...> | post <id> <text...> [--image f] [--no-reply] | waiting <id> user|<agent>|none | resolve <id> [<outcome...>] | rename <id> <title...> | ask <id> <json|file|-> | ls [--all|--tree] | show <id>'
  local repo = my_repo(nil)
  local me = require("isovim.cli.roles").caller()
  local no_reply = flag(args, "--no-reply")
  local parent = option(args, "--parent")
  if sub ~= "ls" and sub ~= "show" then
    local ws, id = (me or ""):match("^(.*)/([^/]+)$")
    local record = ws and store.agent(ws, id)
    local role = record and store.role(record)
    local holds = role == "worker" and threads.holder(repo, me)
    if sub == "bypass" and role ~= "router" then
      fail("only a router makes, moves or ends a bypass" .. (role == "worker" and "; iso worker thread release <reason> asks it to" or ""))
    elseif sub == "release" and not holds then
      fail(role == "worker" and "you hold no thread's bypass, so there's nothing to release"
        or "iso worker thread release is a bypassed worker's, to ask its router to end it")
    elseif sub == "resolve" and role == "worker" and args[1] and threads.summary(threads.read(repo, args[1]) or {}).bypass then
      fail("a worker can't resolve a bypassed thread; iso worker thread release <reason> asks the router, and can carry the outcome you'd propose")
    end
  end
  me = me or "user"
  local images = {}
  while true do
    local path = option(args, "--image")
    if not path then
      break
    end
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    images[#images + 1] = { path = path, mimeType = require("isovim.acp.images").mime(path) or fail(path .. " isn't a png, jpeg, gif or webp") }
  end
  if sub == "new" then
    -- A router's turn on a thread: what it splits off goes under that thread, unless it says not.
    local under = parent ~= "none" and parent or nil
    if not parent and me ~= "user" then
      under = threads.turn_thread(repo, me)
      if under then
        note(("it goes under %s, the thread of this turn (--parent none opts out)"):format(under))
      end
    end
    local id, err = threads.new(repo, args[1] or fail(usage), me, under)
    if not id then
      fail(err)
    end
    local first = vim.trim(table.concat(vim.list_slice(args, 2), " "))
    if first ~= "" then
      threads.post(repo, id, me, first, images[1] and images or nil, no_reply)
    end
    out(id)
  elseif sub == "post" then
    local id = args[1] or fail(usage)
    local post, err = threads.post(repo, id, me, table.concat(vim.list_slice(args, 2), " "), images[1] and images or nil, no_reply)
    if not post then
      fail(err)
    end
    out(("posted to %s#%s%s"):format(repo, id, no_reply and ", needing no reply" or ": it's the user's turn"))
  elseif sub == "waiting" then
    local id = args[1] or fail(usage)
    local on = args[2] or fail(usage)
    if on ~= "user" and on ~= "none" then
      local ws, agent = c.resolve_agent(on:find("/", 1, true) and on or (repo .. "/" .. on))
      on = ws.id .. "/" .. agent.id
      if on == me then
        fail("a thread waits on the user or a worker, not on you: `none` says it waits on nobody")
      end
    end
    local marked, err = threads.wait_on(repo, id, on, me)
    if not marked then
      fail(err)
    end
    out(("%s#%s %s"):format(repo, id, on == "none" and "waits on nobody" or ("waits on " .. on)))
  elseif sub == "bypass" then
    local id = args[1] or fail(usage)
    local on = args[2]
    if not on then
      local entries = threads.read(repo, id) or fail(("%s has no thread %s"):format(repo, id))
      local info = threads.summary(entries)
      return out(info.bypass and ("%s goes to %s"):format(id, info.bypass) or ("%s has no bypass: it goes to the router"):format(id))
    end
    if on ~= "none" then
      local ws, agent = c.resolve_agent(on:find("/", 1, true) and on or (repo .. "/" .. on))
      on = ws.id .. "/" .. agent.id
    end
    local why = threads.bypass_refusal(repo, id, on)
    if why then
      fail(why)
    end
    if on ~= "none" then
      local info = threads.summary(threads.read(repo, id))
      require("isovim.cli.messaging").send({ on, threads.bypass_prompt(repo, id, info.title, me) })
    end
    threads.set_bypass(repo, id, on, me)
    out(on == "none" and ("%s goes to the router again"):format(id) or ("%s goes to %s"):format(id, on))
  elseif sub == "release" then
    local reason = vim.trim(table.concat(args, " "))
    if reason == "" then
      fail(usage)
    end
    local id = threads.holder(repo, me)
    local info = threads.summary(threads.read(repo, id))
    require("isovim.cli.messaging").send({ store.router(repo) or fail(repo .. " has no router here"),
      ("[bypass release] %s asks to be let off thread %s %q: %s\n\n(Nothing has changed. iso router thread bypass %s none ends it, "
        .. "and the user's next post comes to you; if it carries an outcome you agree with, iso router thread resolve %s \"...\" ends it too.)")
        :format(me, id, info.title, reason, id, id) })
    out(("asked the router to end %s's bypass; nothing changes until it does"):format(id))
  elseif sub == "parent" then
    local id = args[1] or fail(usage)
    local above = args[2] or fail(usage)
    local set, err = threads.set_parent(repo, id, above, me)
    if not set then
      fail(err)
    end
    out(("%s#%s %s"):format(repo, id, above == "none" and "has no parent" or ("is under " .. above)))
  elseif sub == "resolve" then
    local id = args[1] or fail(usage)
    local status, err = threads.resolve(repo, id, me, table.concat(vim.list_slice(args, 2), " "))
    if not status then
      fail(err)
    end
    out(("%s#%s is resolved"):format(repo, id))
  elseif sub == "ask" then
    local id = table.remove(args, 1) or fail(usage)
    local qid, how = threads.ask(repo, id, question_spec(args), me)
    if not qid then
      fail(how)
    end
    surfaces.scan(repo)
    c.tui("require('isovim.surfaces').recheck()")
    if how == "reattached" then
      note(("reattached to %s#%s's %s"):format(repo, id, qid))
    end
    -- Blocks until it's answered (the user, or a root in root mode), then prints the answer.
    while true do
      local q = vim.iter(threads.questions(threads.read(repo, id) or {})):find(function(each)
        return each.qid == qid
      end)
      if not q then
        fail(("%s#%s's %s is gone"):format(repo, id, qid))
      elseif q.answer then
        surfaces.scan(repo)
        return out(surfaces.answer_text(q.answer))
      end
      vim.uv.sleep(500)
    end
  elseif sub == "rename" then
    local id = args[1] or fail(usage)
    local title, err = threads.rename(repo, id, me, table.concat(vim.list_slice(args, 2), " "))
    if not title then
      fail(err)
    end
    out(("%s#%s is %q now"):format(repo, id, title))
  elseif sub == "ls" and flag(args, "--tree") then
    local tree = threads.tree(repo)
    if #tree == 0 then
      out(repo .. " has no threads")
    end
    for _, row in ipairs(tree) do
      local info = row.info
      out(("%s%s  %s  %d posts%s%s%s"):format(row.guide, info.id, info.title, info.posts,
        info.status == "resolved" and ("  resolved" .. (info.outcome and (": " .. info.outcome:match("^[^\n]*")) or "")) or "",
        (info.bypass and ("  goes to " .. info.bypass) or "") .. (info.working and "  (working)" or ""),
        info.waiting_on and ("  waiting on " .. info.waiting_on) or ""))
    end
  elseif sub == "ls" then
    local list = threads.list(repo, flag(args, "--all"))
    if #list == 0 then
      out(repo .. " has no " .. (flag(args, "--all") and "" or "open ") .. "threads")
    end
    for _, info in ipairs(list) do
      out(("%s  %s  %d posts%s%s"):format(info.id, info.title, info.posts, info.status == "resolved" and ("  resolved" .. (info.outcome and (": " .. info.outcome) or "")) or "",
        (info.parent and ("  under " .. info.parent) or "") .. (info.bypass and ("  goes to " .. info.bypass) or "") .. (info.working and "  (working)" or "") .. (info.waiting_on and ("  waiting on " .. info.waiting_on) or "")))
    end
  elseif sub == "show" then
    local id = args[1] or fail(usage)
    local entries = threads.read(repo, id) or fail(("%s has no thread %s"):format(repo, id))
    local titled
    for _, entry in ipairs(entries) do
      if entry.kind == "thread" then
        titled = entry.title
        out(("%s: %s (started by %s, %s%s)"):format(entry.id, entry.title, entry.created_by or "?", os.date("%Y-%m-%d %H:%M", entry.at or 0),
          entry.parent and (", under " .. entry.parent) or ""))
      elseif entry.kind == "bypass" then
        out(("\n[%s by %s%s]"):format(entry.on == "none" and "bypass ended" or ("bypass to " .. tostring(entry.on)), entry.by or "?",
          entry.why and (": " .. entry.why) or ""))
      elseif entry.kind == "parent" then
        out(("\n[%s by %s]"):format(entry.on == "none" and "no parent" or ("under " .. tostring(entry.on)), entry.by or "?"))
      elseif entry.kind == "post" then
        out(("\n%s, %s:"):format(entry.by, os.date("%H:%M", entry.at or 0)))
        out(entry.text)
      elseif entry.kind == "ask" then
        out(("\n%s asks (%s): %s"):format(entry.by or "?", entry.qid, entry.question or ""))
        for n, option in ipairs(entry.options or {}) do
          out(("  %d. %s%s"):format(n, option.label, option.description and (" · " .. option.description) or ""))
        end
      elseif entry.kind == "answered" then
        out(("[%s answered by %s: %s]"):format(entry.qid, entry.by or "?", table.concat(entry.labels or {}, ", ")
          .. (entry.other and (" " .. entry.other) or "")))
      elseif entry.kind == "waiting" then
        out(("\n[%s by %s]"):format(entry.on == "none" and "waiting on nobody" or ("waiting on " .. tostring(entry.on)), entry.by or "?"))
      elseif entry.kind == "renamed" then
        out(("\n[renamed from %q to %q by %s]"):format(entry.from or titled or "?", entry.title or "", entry.by or "?"))
        titled = entry.title or titled
      elseif entry.kind == "resolved" or entry.kind == "reopened" then
        out(("\n[%s by %s%s]"):format(entry.kind, entry.by or "?", entry.outcome and (": " .. entry.outcome) or ""))
      end
    end
  else
    fail(usage)
  end
  surfaces.scan(repo)
end

-- iso <role> link <thing>: the iso: address of an agent, a PR, a thread, a page or surface, or a
-- path, to write in a post, a page or a surface link (isovim.links).
function M.link(args)
  local thing = table.concat(args, " ")
  if vim.trim(thing) == "" then
    fail("usage: iso <role> link <agent|aN|#12|owner/repo#12|t3|page or surface name|path>")
  end
  local ok, repo = pcall(my_repo, nil)
  local address, err = require("isovim.links").address(thing, ok and repo or nil)
  if not address then
    fail(err)
  end
  out(address)
end

-- iso __surfaces [<repo>...]: the repos' surfaces (default every repo's), scanned, as JSON.
M.__surfaces = function(args)
  local list = {}
  for _, repo in ipairs(#args > 0 and vim.tbl_map(repo_key, vim.list_slice(args, 1)) or surfaces.repos()) do
    vim.list_extend(list, surfaces.scan(repo))
  end
  out(vim.json.encode(list))
end


-- A PR as a router names it: a URL, owner/repo#n, or #n / n in its own repo.
local function pr_url(repo, ref)
  local prs = require("isovim.prs")
  local number = ref:match("^#?(%d+)$")
  if number and repo:find("/", 1, true) then
    return ("https://github.com/%s/pull/%s"):format(repo, number)
  end
  return prs.normalize(ref) or fail(("%s isn't a PR: a URL, owner/repo#n, or #n in %s"):format(ref, repo))
end

-- iso <role> pr group|ungroup|groups: the router's groups of its repo's PRs, in iso/prs.groups.json,
-- which the PRs surface draws in their order (isovim.prs.groups). A PR is in one group at most:
-- grouping it again moves it. A PR grouped that isn't registered yet is registered too.
function M.pr_grouping(args)
  local prs = require("isovim.prs")
  local sub = table.remove(args, 1)
  local repo = my_repo(option(args, "--repo"))
  local groups = prs.groups(repo)
  local usage = 'usage: iso <role> pr group "<name>" <pr>... [--note "<one line>"] | group --rm "<name>" | group --order "<name>"... | ungroup <pr>... | groups'
  local function find(name)
    for i, group in ipairs(groups) do
      if group.name == name then
        return group, i
      end
    end
  end
  local function take_out(urls)
    for _, group in ipairs(groups) do
      group.prs = vim.tbl_filter(function(url)
        return not vim.tbl_contains(urls, url)
      end, group.prs or {})
    end
  end
  if sub == "groups" then
    local cached = prs.cached(repo)
    if #groups == 0 then
      return out("no groups: the PRs surface shows them by state")
    end
    for _, group in ipairs(groups) do
      out(group.name .. (group.note and ("  · " .. group.note) or ""))
      for _, url in ipairs(group.prs or {}) do
        local pr = cached[url] or {}
        out(("  %s %s%s"):format(pr.number and "#" .. pr.number or url, pr.title or "", pr.state and pr.state ~= "OPEN" and ("  (" .. pr.state:lower() .. ")") or ""))
      end
    end
    return
  elseif sub == "ungroup" then
    if #args == 0 then
      fail(usage)
    end
    local urls = {}
    for _, ref in ipairs(args) do
      urls[#urls + 1] = pr_url(repo, ref)
    end
    take_out(urls)
  elseif sub == "group" then
    if flag(args, "--rm") then
      local _, i = find(args[1] or fail(usage))
      if not i then
        fail(("no group %q in %s"):format(args[1], repo))
      end
      table.remove(groups, i)
    elseif flag(args, "--order") then
      local ordered = {}
      for _, name in ipairs(args) do
        ordered[#ordered + 1] = find(name) or fail(("no group %q in %s"):format(name, repo))
      end
      for _, group in ipairs(groups) do
        if not vim.tbl_contains(args, group.name) then
          ordered[#ordered + 1] = group
        end
      end
      groups = ordered
    else
      local note = option(args, "--note")
      local name = table.remove(args, 1) or fail(usage)
      -- ipairs: the CLI's args carry the script at [0].
      local urls = {}
      for _, ref in ipairs(args) do
        urls[#urls + 1] = pr_url(repo, ref)
      end
      take_out(urls)
      local group = find(name)
      if not group then
        group = { name = name, prs = {} }
        groups[#groups + 1] = group
      end
      group.note = note or group.note
      vim.list_extend(group.prs, urls)
      local by = c.caller_address()
      for _, url in ipairs(urls) do
        store.add_pr(repo, url, by)
      end
    end
  else
    fail(usage)
  end
  prs.save_groups(repo, groups)
  c.tui("require('isovim').refresh()")
end

return M
