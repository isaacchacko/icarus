-- Surfaces on the command line (isovim.surfaces): iso router surface question|file|folder|chat puts
-- one in the router's repo's Inbox, iso answer answers a question (also iso <root|repo-root>
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
  else
    fail("usage: iso router surface question|file|folder|chat ...; iso router help says more")
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
    local why = vim.trim(table.concat(args, " "))
    why = why ~= "" and why:gsub("%s+", " ") or nil
    local raised, err = surfaces.raise(entry, me, why)
    if not raised then
      fail(err)
    end
    publish_root("raised", me, entry, { why = why })
    out(id .. " is in the user's host Inbox now" .. (why and "" or "; a one-line why helps them: iso <role> raise <question> <why>"))
    c.tui("require('isovim.surfaces').recheck()")
    return
  end
  if #args == 0 then
    print_question(entry)
    fail(("usage: iso answer %s <answer...>"):format(query))
  elseif entry.answer then
    fail(("%s/%s is already answered: %s"):format(entry.repo, entry.name, surfaces.answer_text(entry.answer)))
  end
  local answer, err = surfaces.answer(entry, args, me or "user")
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

-- iso __surfaces [<repo>...]: the repos' surfaces (default every repo's), scanned, as JSON.
M.__surfaces = function(args)
  local list = {}
  for _, repo in ipairs(#args > 0 and vim.tbl_map(repo_key, vim.list_slice(args, 1)) or surfaces.repos()) do
    vim.list_extend(list, surfaces.scan(repo))
  end
  out(vim.json.encode(list))
end

return M
