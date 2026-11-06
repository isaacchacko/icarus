-- ica's commands, run by bin/icarus with nvim -l when its first word is one of them.
--
--   ica comment|propose|buffer|comments|watch|unwatch ...
--     an agent answering in a file you're watching with it (icarus.watch has them).
--
--   ica fork <question...|->
--     an agent forking itself for a side question: a sibling on its task with its conversation so
--     far, asked the question; prints the fork's link.
--
--   ica show <file> [--title <title>] [--task <slug>]
--     an agent showing you a visual it wrote to file, on its task (icarus.visual).
--
--   ica bug [--image <file>]... <what happened...|->
--     files a report about icarus itself and prints its id, from an agent or a shell. It goes in
--     ~/.icarus/bugs/<id>.json, its images in <id>/, and icarus sends it to the agent that looks after
--     icarus (icarus.bugs).
--     A report: {id, text, reporter (the chat's id, or "user" from a shell), cwd, time, sha, images?}.
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
vim.opt.runtimepath:prepend(repo)

local bugs = require("icarus.tasks").ROOT .. "/bugs"
local IMAGES = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

local function fail(text)
  io.stderr:write(text .. "\n")
  os.exit(1)
end

local function bug(args)
  local usage = "usage: ica bug [--image <file>]... <what happened...|->"
  local id = vim.fn.sha256(table.concat(args, " ") .. vim.uv.hrtime()):sub(1, 6)
  local words, images = {}, {}
  local i = 1
  while i <= #args do
    if args[i] == "--image" then
      local path = vim.fn.fnamemodify(args[i + 1] or fail(usage), ":p")
      local ext = (path:match("%.(%w+)$") or ""):lower()
      if not IMAGES[ext] or vim.fn.filereadable(path) == 0 then
        io.stderr:write(("ica: %s is not a png, jpeg, gif or webp file; left out\n"):format(path))
      else
        vim.fn.mkdir(bugs .. "/" .. id, "p")
        local to = ("%s/%s/%d.%s"):format(bugs, id, #images + 1, ext)
        if vim.uv.fs_copyfile(path, to) then
          images[#images + 1] = to
        end
      end
      i = i + 2
    else
      words[#words + 1] = args[i]
      i = i + 1
    end
  end
  local text = table.concat(words, " ")
  if text == "-" then
    text = io.stdin:read("*a") or ""
  end
  text = vim.trim(text)
  if text == "" then
    vim.fn.delete(bugs .. "/" .. id, "rf")
    fail(usage)
  end
  local sha = vim.system({ "git", "-C", repo, "rev-parse", "--short", "HEAD" }, { text = true }):wait(2000)
  local report = {
    id = id,
    text = text,
    reporter = vim.env.ICARUS_CHAT or "user",
    cwd = vim.uv.cwd(),
    time = os.time(),
    sha = sha.code == 0 and vim.trim(sha.stdout) or "unknown",
    images = #images > 0 and images or nil,
  }
  vim.fn.mkdir(bugs, "p")
  -- Written whole and renamed into place, so a reader never sees half of it.
  local tmp = ("%s/.%s.tmp"):format(bugs, id)
  vim.fn.writefile({ vim.json.encode(report) }, tmp)
  assert(vim.uv.fs_rename(tmp, ("%s/%s.json"):format(bugs, id)))
  io.stdout:write(id .. "\n")
end

-- The icarus sockets to try: the agent's own icarus's (ICARUS_SERVER), else every icarus running.
local function servers()
  if vim.env.ICARUS_SERVER then
    return { vim.env.ICARUS_SERVER }
  end
  return vim.fn.glob(vim.fs.dirname(vim.fn.stdpath("run")) .. "/*/icarus.*.0", false, true)
end

local function stdin_or(text)
  return text == "-" and ((io.stdin:read("*a") or ""):gsub("\n$", "")) or text
end

-- ica comment|propose|buffer: asks the icarus that has the file open, or made the request
-- (icarus.watch), and prints its answer.
local function remote(cmd, args)
  local why = "no icarus is running"
  for _, server in ipairs(servers()) do
    local ok, channel = pcall(vim.fn.sockconnect, "pipe", server, { rpc = true })
    if ok and channel > 0 then
      local called, result = pcall(vim.rpcrequest, channel, "nvim_exec_lua",
        "return { require('icarus.watch').remote(...) }", { cmd, args })
      vim.fn.chanclose(channel)
      if called and result[1] then
        if result[2] ~= "" then
          io.stdout:write(result[2] .. "\n")
        end
        return
      end
      why = called and result[2] or tostring(result)
      if called and result[3] then
        break
      end
    end
  end
  fail("ica: " .. why)
end

-- What each command takes, for ica help.
local USAGE = {
  bug = "ica bug [--image <file>]... <what happened...|->\n  files a report about icarus itself; prints its id",
  comment = table.concat({
    "ica comment <file> <line|text of the line> <comment...|->   a comment on a line",
    "ica comment <file> --reply <id> <reply...|->                your reply in a comment's thread",
    "ica comment <file> --replaces <id> <comment...|->           a comment of yours rewritten",
    "ica comment <file> --resolve <id>                           a thread resolved (gone from the buffer)",
    "ica comment <file> --resolve-all-mine                       every thread you started, resolved",
  }, "\n"),
  comments = "ica comments <file>\n  lists the comments (id, line, thread) and proposals on a file open in icarus",
  propose = table.concat({
    "ica propose <file> <start> <end> [--note <text>] <replacement...|->   new text for lines start..end",
    "ica propose <request id> [--note <text>] <replacement...|->           an answer to a selection they asked about",
  }, "\n"),
  status = table.concat({
    "ica status                              your task's status and where it stands",
    "ica status <status> [<where it stands...>]   moves it (spec, building, review, merged, cancelled), with a line on where it stands",
    "ica status --now <where it stands...>   only the line",
  }, "\n"),
  claim = "ica claim [--trivial] <what...>\n  democracy: you take a deliverable on, one at a time; prints the others', to check overlap. --trivial needs no reviewer",
  claims = "ica claims\n  who on your task holds what",
  unclaim = "ica unclaim\n  your claim given up",
  done = "ica done\n  your claim is finished: it goes to your reviewers, and reaches the user once they approve",
  approve = "ica approve <agent>\n  the claim you review is good",
  reject = "ica reject <agent> <why...>\n  the claim you review goes back",
  spawn = "ica spawn <job...|specialty>\n  a new agent forked from you, which you need. Specialties: slack-watcher, eval-runner, skeptic, historian, decision-keeper, blast-radius, simplifier",
  edge = "ica edge reviews|needs|contests|talks <agent>\n  wires you to an agent, which you need to message it; a move that closes a deadlock is refused\nica edge --keep|--drop <type> <agent>\n  answers icarus's question on an unused edge",
  unedge = "ica unedge <type> <agent>\n  unwires it",
  topology = "ica topology ring|debate|mesh\n  wires the task's agents: ring, each reviews the next; debate, two contest and a third reviews both; mesh (up to 4), all review all",
  merge = "ica merge <agent>\n  a bid to absorb it: you say you're the parent and it's the child; talk it out\nica merge --accept <agent> <handoff...|->\n  you're the child: your work goes to it, and you end\nica merge --decline <agent> <why...>",
  retire = "ica retire\n  your claim has landed and nothing related is next: you leave the task, and your edges go to whoever needed you",
  post = "ica post <text...|->\n  adds to the task's shared channel",
  read = "ica read\n  what's new on the task's shared channel since you last read",
  ["propose-to-peers"] = "ica propose-to-peers <what...|->\n  a decision to the agents you've edges with (all, if none). Each must answer",
  vote = "ica vote agree <id> | ica vote object <id> <why...>\n  your answer on a decision: an objection sends it back for one revision, a second goes to the user",
  revise = "ica revise <id> <new text...|->\n  your objected decision, changed, and put to the vote again",
  withdraw = "ica withdraw <id>\n  a decision of yours taken back",
  decisions = "ica decisions\n  your task's decisions: open, agreed, disputed, decided by the user",
  name = "ica name <name>\n  renames you: a few words for what you're doing now, which is how the user tells agents apart",
  watch = "ica watch <file>\n  you watch the file: the user's edits reach you as diffs, and it's where you and they talk about it",
  unwatch = "ica unwatch <file>\n  stops your watch on a file, so other agents can comment there again",
  buffer = "ica buffer <file>\n  the file as it is in icarus, numbered, unsaved edits included",
  show = "ica show <file> [--title <title>] [--task <slug>]\n  a visual in your task's visual pane (<leader>v)",
  fork = "ica fork <question...|->\n  a fork of you, a sibling on your task, asked the question; prints its link. It runs at the task's workers_model and workers_effort (its task.md header), if set",
  link = "ica link [--remove] <url>...\n  adds links to your task (a GitHub PR's shows on the task with its Linear tickets); --remove takes them off",
  agents = "ica agents\n  the agents on your task: id, status, title; yours marked",
  log = "ica log <agent id> [n]\n  the last n (10) things said between that agent and the user",
  questions = "ica questions\n  what's open with the user on your task: comment threads in its files, and agents whose last word asked something",
  msg = "ica msg <agent id|icarus://agent/<id>> <message...|->\n  a message to another agent, queued for when its turn ends; it answers the same way",
}

local function help(command)
  if command and USAGE[command] then
    return io.stdout:write(USAGE[command] .. "\n")
  end
  local names = vim.tbl_keys(USAGE)
  table.sort(names)
  local out = { "ica: icarus's commands; ica with no command opens icarus.", "",
    "Files open in icarus are where you and the user talk about them: comment, reply and propose there,",
    "not in the chat. Any agent may, each marked with its name; the user's replies go to whoever started",
    "the thread. Watching a file (ica watch) brings you the user's edits to it with your next turn.", "" }
  for _, each in ipairs(names) do
    out[#out + 1] = USAGE[each]
    out[#out + 1] = ""
  end
  io.stdout:write(table.concat(out, "\n"))
end

local COMMANDS = {
  bug = bug,
  -- ica comment <file> <line|text of the line> <comment...|->
  -- ica comment <file> --replaces <comment id> <comment...|->
  -- ica comment <file> --reply <comment id> <reply...|->
  -- ica comment <file> --resolve <comment id> | --resolve-all-mine
  comment = function(args)
    local usage = "usage:\n" .. USAGE.comment
    local payload = { path = args[1] and vim.fn.fnamemodify(args[1], ":p"), chat = vim.env.ICARUS_CHAT }
    if args[2] == "--resolve" or args[2] == "--resolve-all-mine" then
      if args[2] == "--resolve" then
        payload.resolve = args[3] or fail(usage)
      elseif not payload.chat then
        fail("ica comment --resolve-all-mine: only an agent has comments of its own (no $ICARUS_CHAT)")
      else
        payload.resolve_all_mine = true
      end
      return remote("comment", payload)
    end
    local by_id = args[2] == "--replaces" or args[2] == "--reply"
    if by_id then
      payload[args[2]:sub(3)] = args[3]
    else
      payload.line = args[2]
    end
    payload.text = stdin_or(table.concat(vim.list_slice(args, 3 + (by_id and 1 or 0)), " "))
    if not (payload.path and (payload.line or payload.replaces or payload.reply)) or vim.trim(payload.text) == "" then
      fail(usage)
    end
    remote("comment", payload)
  end,
  -- ica propose <request id> [--note <text>] [<replacement...|->]
  -- ica propose <file> <start> <end> [--note <text>] [<replacement...|->]
  propose = function(args)
    local usage = "usage: ica propose <request id>|<file> <start> <end> [--note <text>] [<replacement...|->]"
    local first = table.remove(args, 1) or fail(usage)
    local payload = { chat = vim.env.ICARUS_CHAT }
    if first:match("^%d+$") then
      payload.id = first
    else
      payload.path = vim.fn.fnamemodify(first, ":p")
      payload.start, payload["end"] = table.remove(args, 1) or fail(usage), table.remove(args, 1) or fail(usage)
    end
    if args[1] == "--note" then
      table.remove(args, 1)
      payload.note = table.remove(args, 1)
    end
    payload.text = stdin_or(table.concat(args, " "))
    remote("propose", payload)
  end,
  -- ica show <file> [--title <title>] [--task <slug>]
  show = function(args)
    local usage = "usage: ica show <file> [--title <title>] [--task <slug>]"
    local payload = { chat = vim.env.ICARUS_CHAT, task = vim.env.ICARUS_CHAT == nil and vim.env.ICARUS_TASK or nil }
    local i = 1
    while i <= #args do
      if args[i] == "--title" or args[i] == "--task" then
        payload[args[i]:sub(3)] = args[i + 1] or fail(usage)
        i = i + 2
      else
        payload.path = payload.path and fail(usage) or vim.fn.fnamemodify(args[i], ":p")
        i = i + 1
      end
    end
    if not payload.path then
      fail(usage)
    end
    remote("show", payload)
  end,
  -- ica fork <question...|->
  fork = function(args)
    local text = stdin_or(table.concat(args, " "))
    if vim.trim(text) == "" or not vim.env.ICARUS_CHAT then
      fail(vim.env.ICARUS_CHAT and "usage: ica fork <question...|->" or "ica fork: only an agent forks itself (no $ICARUS_CHAT)")
    end
    remote("fork", { chat = vim.env.ICARUS_CHAT, text = text })
  end,
  -- ica agents
  agents = function()
    remote("agents", { chat = vim.env.ICARUS_CHAT or fail("ica agents: only an agent has a task (no $ICARUS_CHAT)") })
  end,
  -- ica log <agent id> [n]
  log = function(args)
    remote("log", { chat = vim.env.ICARUS_CHAT or fail("ica log: only an agent reads its siblings (no $ICARUS_CHAT)"),
      agent = (args[1] or fail("usage: " .. USAGE.log)):gsub("^icarus://agent/", ""), n = args[2] })
  end,
  -- ica questions
  questions = function()
    remote("questions", { chat = vim.env.ICARUS_CHAT or fail("ica questions: only an agent has a task (no $ICARUS_CHAT)") })
  end,
  -- ica msg <agent id> <message...|->
  msg = function(args)
    local to = (table.remove(args, 1) or fail("usage: " .. USAGE.msg)):gsub("^icarus://agent/", "")
    local text = stdin_or(table.concat(args, " "))
    if vim.trim(text) == "" then
      fail("usage: " .. USAGE.msg)
    end
    remote("msg", { chat = vim.env.ICARUS_CHAT or fail("ica msg: only an agent sends messages (no $ICARUS_CHAT)"), to = to, text = text })
  end,
  -- ica comments <file>
  comments = function(args)
    remote("comments", { path = vim.fn.fnamemodify(args[1] or fail("usage: ica comments <file>"), ":p") })
  end,
  -- ica link [--remove] <url>...
  link = function(args)
    local payload = { chat = vim.env.ICARUS_CHAT or fail("ica link: only an agent has a task (no $ICARUS_CHAT)") }
    if args[1] == "--remove" then
      payload.remove = true
      table.remove(args, 1)
    end
    payload.urls = #args > 0 and vim.list_slice(args, 1, #args) or fail("usage: " .. USAGE.link)
    remote("link", payload)
  end,
  -- ica status [<status>] [<where it stands...>] | --now <where it stands...>
  status = function(args)
    local payload = { chat = vim.env.ICARUS_CHAT or fail("ica status: only an agent has a task (no $ICARUS_CHAT)") }
    if args[1] == "--now" then
      table.remove(args, 1)
      payload.now = #args > 0 and table.concat(args, " ") or fail("usage:\n" .. USAGE.status)
    elseif args[1] then
      payload.status = table.remove(args, 1)
      payload.now = #args > 0 and table.concat(args, " ") or nil
    end
    remote("status", payload)
  end,
  -- ica name <name>
  name = function(args)
    remote("name", { chat = vim.env.ICARUS_CHAT or fail("ica name: only an agent has a name (no $ICARUS_CHAT)"),
      name = #args > 0 and table.concat(args, " ") or fail("usage: " .. USAGE.name) })
  end,
  -- ica watch <file>
  watch = function(args)
    remote("watch", { path = vim.fn.fnamemodify(args[1] or fail("usage: " .. USAGE.watch), ":p"),
      chat = vim.env.ICARUS_CHAT or fail("ica watch: only an agent watches files (no $ICARUS_CHAT)") })
  end,
  -- ica unwatch <file>
  unwatch = function(args)
    remote("unwatch", { path = vim.fn.fnamemodify(args[1] or fail("usage: " .. USAGE.unwatch), ":p"),
      chat = vim.env.ICARUS_CHAT or fail("ica unwatch: only an agent watches files (no $ICARUS_CHAT)") })
  end,
  -- ica buffer <file>
  buffer = function(args)
    remote("buffer", { path = vim.fn.fnamemodify(args[1] or fail("usage: ica buffer <file>"), ":p") })
  end,
}

-- A democracy's commands (icarus.democracy), which reads their arguments itself; a last - is stdin.
for _, each in ipairs({ "claim", "claims", "unclaim", "done", "approve", "reject", "spawn", "edge", "unedge", "topology", "merge",
  "retire", "post", "read", "propose-to-peers", "vote", "revise", "withdraw", "decisions" }) do
  COMMANDS[each] = function(args)
    local argv = vim.list_slice(args)
    argv[#argv] = argv[#argv] and stdin_or(argv[#argv]) or nil
    remote(each, { chat = vim.env.ICARUS_CHAT or fail("ica " .. each .. ": only an agent can (no $ICARUS_CHAT)"), argv = argv })
  end
end

local name = table.remove(_G.arg, 1)
if name == "help" or name == "--help" or name == "-h" then
  return help(_G.arg[1])
end
if _G.arg[1] == "--help" or _G.arg[1] == "-h" then
  return help(name)
end
local command = COMMANDS[name] or fail("ica: no command " .. tostring(name) .. " (ica help lists them)")
command(_G.arg)
