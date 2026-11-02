-- Every iso command, in the order `iso help` lists them. This one table drives cli.lua's dispatch,
-- `iso help`, Tab completion (isovim.cli.complete) and bin/iso, which finds a command by the
-- `{ name = "<command>",` that starts its entry here, so keep each entry starting that way.
--   name      the word after iso
--   module    isovim.cli.<module> runs it, as the function of the same name; none means bin/iso does
--   args      its words in order, as usage writes them: <kind>, literal|literal|<kind>, and a last
--             one ending in ... repeats. Kinds are what Tab offers: ws, archived, agent (this host's),
--             address (an agent here or <host>:<agent>), host, kind, role, command, topic (an
--             event pattern), action (the caller's repo's), repo, question (one waiting on an
--             answer), option (the options of the question before it), path, dir, and text and n,
--             which offer nothing
--   flags     flag -> the kind of its value, or false for a flag without one
--   subs      subcommand -> { args, flags }, for a command whose first word picks what it does
--   help      its lines in `iso help`, verbatim; summary is its one line in completion, when the
--             help doesn't give one
--   hidden    not offered by completion
--   shared    an action every role has too (iso <role> <name>), as are those M.shared lists
--   audience  who runs it: "anyone" is the user and agents alike, bare or under a role (iso bug);
--             "user" is the user's own (bare) commands, which an agent is warned off
--             (and later refused); nil is a command agents still run until what replaces it
--             lands (task, pin, ask, pr, ...), left alone; "plumbing" is isovim's own hooks,
--             hosts and shell completion, which any refusal of agents or users lets through
--   role_form the action an agent runs instead, as iso <role> <action>, when it isn't the same word
--   retired   what replaced a command v0 drops: once enforcement is on (iso cutover), running it
--             fails with this, and help and completion leave it out
-- Agents run their commands as iso <role> <action>: M.roles and M.shared below say which.
local M = {}

-- The roles, lowest first. An agent spawns roles up to its own.
M.roles = { "worker", "router", "repo-root", "root" }
M.rank = {}
for i, role in ipairs(M.roles) do
  M.rank[role] = i
end

-- What every role runs as iso <role> <action>: the bare command of that name (one without an entry
-- is left out, so `listen` appears when it lands), or the entry in M.role_actions.
M.shared = { "msg", "ls", "status", "peek", "wait", "find", "transcript", "browser", "listen", "checkhealth",
  "version", "update", "pilot", "fork", "spawn", "promote", "restart", "bug", "link", "queue" }
M.only = {
  worker = { "wt", "setup", "teardown", "run", "page", "thread" },
  router = { "surface", "page", "thread", "pr", "rm", "wt", "setup", "teardown", "run" },
  ["repo-root"] = { "answer", "raise", "rm", "page", "thread" },
  root = { "answer", "raise", "rm", "page", "thread" },
}

M.header = [=[
usage: iso                           open the TUI (iso --takeover to steal it from another terminal)]=]

M.footer = [=[
<ws> is a workspace id, name, or unique prefix of either. <agent> is <ws>/<agent id or name>,
or just <ws> for the workspace's first visible agent. send, msg, status, wait and peek also take
<host>:<agent> for an agent on another host (hosts in ~/.isovim/config.json).
A router's, repo-root's or root's session is compacted when a turn leaves it past compact_at tokens
in ~/.isovim/config.json (default 250000; 0 turns it off), so its next call after a pause isn't a
rewrite of all of it; the chat says "compacted 212k → 18k", and ~/.isovim/compactions.log has a line
for each.]=]

M.list = {
  { name = "ls", module = "inspect",
    flags = { ["--json"] = false },
    audience = "user",
    help = [=[
       iso ls [--json]               list agents: ws/agent, status, role, workspace · agent, parent]=],
  },
  { name = "worker", module = "roles",
    summary = "a worker's actions (iso worker help)",
    help = [=[
       iso worker|router|repo-root|root <action> ...
                                     what an agent runs, under its role: iso <role> help lists
                                     a role's actions. isovim checks the role against the
                                     agent's record and, for now, warns on a mismatch; an
                                     agent running a bare iso <command> is warned too. A
                                     worker's and a router's own work: iso <role> wt makes
                                     its worktree, iso <role> setup|teardown|run [<action>]
                                     runs its repo's scripts there]=],
  },
  { name = "router", module = "roles",
    summary = "a router's actions (iso router help)",
  },
  { name = "repo-root", module = "roles",
    summary = "a repo-root's actions (iso repo-root help)",
  },
  { name = "spawn", module = "roles",
    args = { "<text>..." },
    flags = { ["--repo"] = "<dir>", ["--role"] = "<role>", ["--read-only"] = false, ["--name"] = "<text>",
      ["--kind"] = "claude|codex", ["--shown"] = false },
    audience = "user",
    summary = "start an agent over ACP (claude, or codex), the repo's next aN",
    help = [=[
       iso spawn [--repo owner/repo|dir] [--role r] [--read-only] [--name n] [--kind claude|codex]
                 [<prompt...>]       start an agent over ACP on the prompt (claude unless
                                     --kind says codex, which runs codex-acp), as the
                                     repo's next <owner>/<repo>/aN (from an agent, in its own
                                     repo; from a shell, the clone it's in; else general/aN),
                                     and print its address. It starts in aN/ and gets its
                                     worktree, aN/<repo>-aN (aN/w links to it), on its first
                                     edit (or iso <role> wt).
                                     An agent's spawn is its child, of a role no higher than
                                     its own; one router per repo here, one repo-root per repo,
                                     one root per host. --read-only runs it in the repo's base
                                     clone, fetched first, and refuses its edits. A router's
                                     spawn starts hidden (H in the sidebar shows it) unless
                                     --shown]=],
  },
  { name = "new", module = "workspaces",
    retired = "iso spawn starts an agent, in a repo with --repo",
    audience = "user",
    role_form = "spawn",
    args = { "<text>..." },
    flags = { ["--dir"] = "<dir>", ["--worktree"] = false, ["--from"] = "<text>" },
    help = [=[
       iso new <name> [--dir path] [--worktree | --from <branch|PR>]
                                     create a workspace, print its id; its agents and files
                                     live in path (a project), else its own dir. --worktree
                                     gives it a new worktree of the repo at path, on branch
                                     $USER/<name>; --from one of an existing branch or PR
                                     (number or URL). Archiving removes it if clean]=],
  },
  { name = "dir", module = "workspaces",
    retired = "an agent's repo is set when it's spawned: iso spawn --repo owner/repo|dir",
    audience = "user",
    args = { "<ws>", "<dir>|-" },
    help = [=[
       iso dir <ws> [path|-]         print, set or (-) clear its project dir]=],
  },
  { name = "rename", module = "workspaces",
    audience = "user",
    args = { "<ws>|<agent>", "<text>..." },
    help = [=[
       iso rename <ws|agent> <name>   rename a workspace, or an agent (<ws>/<agent>)]=],
  },
  { name = "archive", module = "workspaces",
    retired = "iso rm <agent> stops an agent and tears down its worktree",
    audience = "user",
    args = { "<ws>" },
    help = [=[
       iso archive <ws>              stop its agents and move it to the archive]=],
  },
  { name = "archived", module = "workspaces",
    retired = "nothing is archived any more; the old workspaces are in ~/.isovim/legacy-backup-*",
    audience = "user",
    help = [=[
       iso archived                  list archived workspaces, newest first]=],
  },
  { name = "unarchive", module = "workspaces",
    retired = "nothing is archived any more; the old workspaces are in ~/.isovim/legacy-backup-*",
    audience = "user",
    args = { "<archived>" },
    help = [=[
       iso unarchive <ws>            bring one back (a worktree workspace gets its worktree)]=],
  },
  { name = "move", module = "workspaces",
    audience = "user",
    args = { "<ws>", "<host>" },
    flags = { ["--force"] = false, ["--all"] = false },
    help = [=[
       iso move <ws> <host> [--force]   move it to another host (ssh name); its agents resume
                                     there. --force moves it even while an agent is working
       iso move <owner>/<repo>/aN <host>
                                     move one agent (its exact address): record, journal,
                                     queue and session go, its worktree's branch is pushed and
                                     made again there as aN/<repo>-aN, and it resumes there.
                                     Refused mid-turn, with uncommitted work, and for roots; it
                                     keeps its aN unless that host has used it, and prints its
                                     address
       iso move <owner>/<repo> <host> --all
                                     move every agent of the repo (or general), each as above,
                                     parents first; its terminals stay. All are checked first,
                                     and the host asked, so a refusal moves none of them]=],
  },
  { name = "agent", module = "agents",
    audience = "user",
    role_form = "spawn",
    args = { "<ws>", "<kind>" },
    flags = {
      ["--name"] = "<text>",
      ["--hidden"] = false,
      ["--cmd"] = "<text>",
      ["--prompt"] = "<text>",
      ["--role"] = "<role>",
      ["--parent"] = "<address>",
      ["--v2"] = false,
      ["--read-only"] = false,
    },
    help = [=[
       iso agent <ws> <kind> [--name n] [--hidden] [--cmd c] [--prompt text] [--role r]
                     [--parent agent] [--v2 [--read-only]]
                                     add an agent (claude|codex|terminal|command), start it;
                                     --prompt starts a claude or codex agent on that prompt;
                                     --role root|repo-root|router|worker (default worker) picks
                                     the role prompt it's told (prompts in ~/.isovim/config.json).
                                     Its parent is the agent running this (iso new and iso fork
                                     set it too), or --parent. --v2 (trying out the new layout)
                                     makes it <owner>/<repo>/aN in ~/.iso/<owner>/<repo>/aN, for
                                     <ws> given as owner/repo or a dir in that repo (_ outside
                                     one); --read-only starts it in the repo's base clone]=],
  },
  { name = "role", module = "agents",
    audience = "user",
    role_form = "promote",
    args = { "<agent>", "<role>" },
    help = [=[
       iso role <agent> [root|repo-root|router|worker]   print or change its role; a change
                                     takes effect when it next restarts]=],
  },
  { name = "rm", module = "agents",
    audience = "user",
    args = { "<agent>..." },
    help = [=[
       iso rm <agent>...             stop agents and remove them from their workspace; their
                                     children go to their parent (archiving a workspace does
                                     the same)]=],
  },
  { name = "pr", module = "workspaces",
    args = { "<ws>", "<text>" },
    help = [=[
       iso pr <ws> <url|owner/repo#n>   register a PR for the workspace (agents run this)
       iso pr group "<name>" <pr>... [--note "<one line>"]
                                     a router puts its repo's PRs (URL, owner/repo#n or
                                     #n) in a group, made if it's new: the PRs surface
                                     shows the groups in order, each a box with its note,
                                     the PRs in none in Other. A PR is in one group at
                                     most; grouping it again moves it
       iso pr group --rm "<name>" | --order "<name>"...
                                     drop a group, or put groups in that order
       iso pr ungroup <pr>...         take PRs out of their group
       iso pr groups                  the groups and their PRs]=],
  },
  { name = "prs", module = "workspaces",
    retired = "iso listen 'pr.<owner/repo>.**' follows a repo's PRs",
    audience = "user",
    args = { "<ws>" },
    flags = { ["--json"] = false },
    help = [=[
       iso prs <ws> [--json]         its PRs with their state]=],
  },
  { name = "hide", module = "agents",
    retired = "every agent shows under its repo; iso rm <agent> removes one",
    audience = "user",
    args = { "<agent>" },
    help = [=[
       iso hide|unhide <agent>       hidden agents stay out of the sidebar and never notify]=],
  },
  { name = "unhide", module = "agents",
    retired = "every agent shows under its repo; iso rm <agent> removes one",
    audience = "user",
    args = { "<agent>" },
    summary = "show a hidden agent again",
  },
  { name = "open", module = "agents",
    audience = "user",
    args = { "<agent>" },
    help = [=[
       iso open <agent>              start it; show it in the TUI if open]=],
  },
  { name = "restart", module = "agents",
    audience = "user",
    args = { "<agent>" },
    help = [=[
       iso restart <agent>           restart it (Claude and Codex keep their conversation)]=],
  },
  { name = "attach", module = "agents",
    audience = "user",
    args = { "<agent>" },
    help = [=[
       iso attach <agent>            start it and attach this terminal to it (detach: C-b d); an
                                     ACP agent's chat and composer open in a minimal nvim (:qa)]=],
  },
  { name = "handover", module = "agents",
    audience = "user",
    args = { "<agent>" },
    flags = { ["--no-attach"] = false },
    help = [=[
       iso handover <agent>          hand an ACP agent's session to Claude's own screen: claude
                                     --resume in its pane, attached here; quitting Claude gives
                                     it back to the chat (--no-attach: leave the pane alone)]=],
  },
  { name = "phone", module = "agents",
    audience = "user",
    help = [=[
       iso phone                     pick an agent to attach to, needs-you first; for small
                                     screens over SSH]=],
  },
  { name = "send", module = "messaging",
    audience = "user",
    role_form = "msg",
    args = { "<address>", "<text>..." },
    flags = { ["--image"] = "<path>" },
    help = [=[
       iso send <agent> [--image <file>]... <text...>
                                     type text into it and submit (starts it if needed); from
                                     an agent it starts with isovim's stamp,
                                     "[from <host>:<ws>/<agent> · m<id>]", to reply to; each
                                     --image attaches a png, jpeg, gif or webp as [Image #n]]=],
  },
  { name = "msg", module = "messaging",
    audience = "user",
    args = { "parent|children|<address>", "<text>..." },
    flags = { ["--image"] = "<path>", ["--first"] = false, ["--now"] = false },
    summary = "iso send to its parent, its children, or any agent",
    help = [=[
       iso msg [--first|--now] <parent|children|agent> [--image <file>]... <text...>
                                     iso send to the agent that started this one, to each agent
                                     it started, or to any agent. --first and --now, before the
                                     target, are for an agent you may restart, or your child:
                                     --first puts it at the front of its queue, behind anything
                                     the user wrote, without touching the running turn; --now
                                     does too and cancels the turn, telling it to carry on after
                                     this message. --now is refused while a permission waits or
                                     the turn is on the user's own prompt, and to a lower role
                                     for a higher one's turn]=],
  },
  { name = "queue", module = "messaging",
    audience = "user",
    args = { "drop|<agent>", "<agent>", "<text>" },
    summary = "list an agent's queued messages, or drop one",
    help = [=[
       iso queue <agent>             an agent's queued messages, in the order they'll go: id,
                                     sender, age, text (one you may restart, or your child)
       iso queue drop <agent> <id>   remove one, the others keeping their places and stamps.
                                     Only the user drops what the user wrote]=],
  },
  { name = "bug", module = "bugs",
    audience = "anyone",
    args = { "<text>..." },
    flags = { ["--image"] = "<path>" },
    summary = "file a bug, complaint or request about isovim itself",
    help = [=[
       iso bug [--image <file>]... <text...|->
                                     file a bug, complaint or request about isovim itself
                                     (- reads it from stdin): it's queued in ~/.isovim/bugs/
                                     and the id printed at once; a worker picks it up and
                                     opens a GitHub issue in isaacchacko/isovim about it,
                                     keeping out anything private. Bare or under a role,
                                     from any agent or a shell]=],
  },
  { name = "fork", module = "agents",
    args = { "<agent>" },
    flags = { ["--name"] = "<text>", ["--prompt"] = "<text>", ["--at"] = "<seq>" },
    summary = "a tangent: a new workspace from a copy of an agent's conversation",
    help = [=[
       iso fork [<agent>] [--name n] [--prompt text] [--at seq]
                                     a tangent: a new workspace in the same project whose agent
                                     starts from a copy of <agent>'s conversation (default: the
                                     agent running this); nothing opens it, so focus stays put.
                                     An ACP agent's fork is its repo's next aN, its chat starting
                                     with the history it forked; --at forks it at a message (the
                                     seq of a journal entry, as <leader>if in its chat gives)]=],
  },
  { name = "ask", module = "messaging",
    retired = "a worker asks its router (iso worker msg parent); a router asks you with iso router surface question",
    args = { "<text>..." },
    help = [=[
       iso ask <question...>         from an agent: ask the root; the root (or anyone, with no
                                     root) raises it to you, into the Inbox. Workspace agents
                                     only; retired at cutover (a router's surface question)]=],
  },
  { name = "answer", module = "surfaces",
    audience = "user",
    args = { "<question>", "<option>..." },
    flags = { ["--raise"] = false, ["--why"] = "<text>" },
    summary = "answer a question surface",
    help = [=[
       iso answer <question> [<answer...>]
                                     answer a question surface (<repo>/<name> when
                                     names repeat across repos): an option's label or
                                     number, several for a multi question, or your own
                                     words where it takes them; with no answer, print
                                     the question and its options. In root mode the
                                     root decides its Inbox's questions first (they're
                                     tagged root deciding and wait on you only once
                                     raised); you can answer any of them anyway, and
                                     the first answer wins. A root answers with iso
                                     <root|repo-root> answer, --why "<reason>" saying
                                     why in its decision log, or gives one to you with
                                     iso <role> raise <question> [why] (or --raise)]=],
  },
  { name = "rootmode", module = "rootmode",
    audience = "user",
    args = { "on|off", "host|<repo>" },
    flags = { ["--task"] = "<text>" },
    summary = "put a root in charge of clearing the Inbox, for a repo or the host",
    help = [=[
       iso rootmode on|off <repo|host> [--task "<description>"]
                                     root mode: a root decides the Inbox's questions
                                     before they reach you, however they were asked;
                                     they're tagged root deciding, and come to your host
                                     Inbox only when it raises them, with its why
                                     (permission requests always do). It's told of each
                                     new one, and on lists those waiting. on spawns a
                                     worker over ACP and promotes it (repo-root, or root
                                     for the host), or uses the agent holding that
                                     role; --task is its first message, guidance it
                                     narrows itself by. off puts every question not
                                     decided in your host Inbox; the root keeps its role]=],
  },
  { name = "root", module = "messaging",
    args = { "<address>" },
    flags = { ["--clear"] = false },
    summary = "print or set the root; a root's actions (iso root help)",
    help = [=[
       iso root [<agent>|--clear]    print or set the root, the agent the others ask and whose
                                     stamped messages speak for you; <host>:<ws>/<agent> for a
                                     root on another host. iso root <action> is the root's
                                     namespace (iso root help)]=],
  },
  { name = "verify", module = "messaging",
    args = { "<text>" },
    flags = { ["--json"] = false, ["--here"] = false },
    help = [=[
       iso verify <m-id> [--json]    what isovim recorded for a stamp]=],
  },
  { name = "find", module = "inspect",
    audience = "user",
    args = { "<text>..." },
    flags = { ["--json"] = false, ["--local"] = false },
    summary = "find agents on every host by name, branch, PR or conversation",
    help = [=[
       iso find <query> [--json]     agents on every host ranked by where the query turns up:
                                     names, branch, PRs, what they're on, their conversation]=],
  },
  { name = "pin", module = "workspaces",
    retired = "iso <role> surface file|folder <path> puts it in your repo's Inbox",
    args = { "<ws>", "<path>" },
    flags = { ["--label"] = "<text>" },
    help = [=[
       iso pin <ws> <path> [--label text]   show a file or folder under the workspace in the sidebar
                                     (workspace agents; retired at cutover: surface file|folder)]=],
  },
  { name = "unpin", module = "workspaces",
    retired = "a surface leaves the Inbox when its file goes, or once opened",
    args = { "<ws>", "<path>" },
    summary = "stop showing a pinned file or folder",
    help = [=[
       iso unpin <ws> <path>]=],
  },
  { name = "transcript", module = "plumbing",
    args = { "<agent>" },
    audience = "plumbing",
    help = [=[
       iso transcript <agent>        rewrite its plain-text transcript, print the path]=],
  },
  { name = "status", module = "inspect",
    audience = "user",
    args = { "<address>" },
    help = [=[
       iso status <agent>            stopped | idle | working | attention | unread]=],
  },
  { name = "wait", module = "inspect",
    audience = "user",
    args = { "<address>" },
    flags = { ["--timeout"] = "<n>" },
    help = [=[
       iso wait <agent> [--timeout s]   block until it stops working, print the status]=],
  },
  { name = "peek", module = "inspect",
    audience = "user",
    args = { "<address>" },
    flags = { ["-n"] = "<n>" },
    help = [=[
       iso peek <agent> [-n lines]   print the last lines of its screen (default 40)]=],
  },
  { name = "listen", module = "events",
    args = { "<topic>..." },
    flags = { ["--once"] = false, ["--since"] = "<text>" },
    shared = true,
    summary = "print the events whose topics match, one JSON line each, as they happen",
    help = [=[
       iso listen <pattern...> [--once] [--since t]
                                     print each event whose topic matches a pattern, one JSON
                                     line {topic, time, ...} as it happens, until killed (made
                                     for a Monitor); --once exits after the first. Topics:
                                     agent.<scope>.<id>.status|spawned|exited|promoted,
                                     msg.<scope>.<id>, pr.<owner/repo>.<n>.state|ci|review,
                                     surface.<owner/repo>.<name>.created|changed|removed|
                                     answered|consumed, where an agent's scope is its repo (owner/repo, or _) and
                                     its id aN, or a legacy one's its workspace and agent ids.
                                     In a part "%" is written %25 and "." %2E
                                     (agent.owner/site%2Ecom.a3.status), and patterns match it
                                     as written. In a pattern * is any one dot-separated part,
                                     ** any number (quote them): agent.owner/repo.** is a whole
                                     repo, agent.*.*.status every agent's state. --since
                                     starts from a time (epoch seconds, or 90s, 10m, 2h, 1d ago)]=],
  },
  { name = "closed", module = "events",
    args = { "<text>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "checkhealth", module = "inspect",
    audience = "user",
    help = [=[
       iso checkhealth               check what isovim needs here and on the other hosts]=],
  },
  { name = "jump", module = "lifecycle",
    audience = "user",
    args = { "<text>..." },
    help = [=[
       iso jump [<text>]             go to a dir isovim keeps, in fzf, one level at a time: config
                                     and owners, then repos, then a repo's agents, iso/, config
                                     and base clone, then an agent's worktree; each level starts
                                     with . (here) and .. (up). <text> searches every level and
                                     jumps straight to a single match. The iso function from
                                     iso completion zsh|bash cds there; without it the dir is
                                     printed]=],
  },
  { name = "sync", module = "lifecycle",
    audience = "user",
    help = [=[
       iso sync                      send your config (~/.isovim/config.json but its self and
                                     hosts, and ~/.isovim/repos/ but base clones) to every host
                                     in hosts now; every write isovim makes there sends it too]=],
  },
  { name = "cutover", module = "cutover",
    audience = "user",
    flags = { ["--dry-run"] = false, ["--yes"] = false },
    help = [=[
       iso cutover --dry-run         what moving to v0 pushes, stops, seeds and moves away,
                                     touching nothing; the plan goes to ~/.isovim/cutover-plan.txt
       iso cutover --yes             carry out that plan, while a fresh dry run still matches it:
                                     the old layout goes to ~/.isovim/legacy-backup-<date>/ and
                                     enforcement comes on]=],
  },
  -- One reaper pass now; the TUI runs one every 10 minutes. Dry (logging to ~/.isovim/reaper.log)
  -- unless --live, until v0 is cut over.
  { name = "reap", module = "lifecycle",
    flags = { ["--dry-run"] = false, ["--live"] = false },
    hidden = true,
    audience = "plumbing",
  },
  -- The dir `iso jump` picks, printed: what the shell function cds to.
  { name = "__jump", module = "lifecycle",
    args = { "<text>..." },
    hidden = true,
    audience = "plumbing",
  },
  -- A config sync in the background, after a write (isovim.sync).
  { name = "__sync", module = "lifecycle",
    hidden = true,
    audience = "plumbing",
  },
  -- The move of an old work root or _/ (isovim.migrate), started apart from an agent that found one.
  { name = "__migrate", module = "lifecycle",
    hidden = true,
    audience = "plumbing",
  },
  -- iso-hook's PreToolUse for edit tools and Bash: a new-layout agent's first edit makes its
  -- worktree; a read-only agent's edits, and any agent's in a clone of a repo isovim knows outside
  -- its own worktree, are refused (isovim.cli.work).
  { name = "__pretool", module = "work",
    args = { "edit|bash" },
    hidden = true,
    audience = "plumbing",
  },
  -- checkhealth's old name; drop it after 2026-12-01.
  { name = "doctor", module = "inspect",
    audience = "user",
    role_form = "checkhealth",
    hidden = true,
  },
  { name = "version", module = "inspect",
    audience = "user",
    help = [=[
       iso version                   the isovim commit this runs]=],
  },
  { name = "update", module = "plumbing",
    audience = "plumbing",
    help = [=[
       iso update                    fast-forward the checkout isovim runs from to origin's main
                                     (only when clean and on main), then the open TUI hot reloads
                                     or restarts onto it; run it after you push to isovim's main
                                     (the TUI also looks every minute)]=],
  },
  { name = "task", module = "agents",
    retired = "the repo's Task Board, ~/.iso/<owner>/<repo>/iso/tasks.md",
    subs = {
      set = {
        args = { "<text>", "<text>..." },
        flags = {
          ["--status"] = "todo|doing|waiting|blocked|done",
          ["--parent"] = "<text>",
          ["--detail"] = "<text>",
          ["--pr"] = "<n>",
          ["--linear"] = "<text>",
        },
      },
      rm = { args = { "<text>" } },
      ls = {},
    },
    help = [=[
       iso task set <id> [<title>] [--status todo|doing|waiting|blocked|done] [--parent <id>]
                                     [--detail text] [--pr N] [--linear PRO-x]
                                     add or update one of your tasks; the sidebar shows them with T
                                     (workspace agents; retired at cutover: the router's tasks.md)
       iso task rm <id>              remove one of your tasks and its subtasks
       iso task ls                   your tasks]=],
  },
  { name = "pilot", module = "pilot",
    audience = "user",
    subs = {
      request = { args = { "<text>..." } },
      keys = { args = { "<text>" } },
      screen = {},
      status = {},
      release = {},
    },
    summary = "drive the open TUI: request, keys, screen, status, release",
    help = [=[
       iso pilot request <reason...> ask to drive the TUI: control comes after a 10s countdown unless declined;
                                     blocks until allowed or denied; busy at once while another agent holds it
       iso pilot keys <keys>         type into the TUI, in nvim key notation ("<C-h>j<CR>")
       iso pilot screen              print the TUI's screen
       iso pilot status|release      off | asking | active | denied, and who holds it; release hands control back
                                     (pressing Esc in the TUI takes control back too)
                                     keys, screen and release are only for the agent holding control]=],
  },
  { name = "completion", module = "complete",
    args = { "zsh|bash" },
    help = [=[
       iso completion zsh|bash       print Tab completion for the shell: source <(iso completion zsh)]=],
  },
  { name = "browser",
    audience = "user",
    args = { "<text>..." },
    summary = "drive a browser (bin/iso-browser.mjs)",
  },
  { name = "help",
    summary = "print this usage",
  },
  { name = "progress", module = "plumbing",
    args = { "<agent>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "autopin", module = "plumbing",
    args = { "<agent>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "autopr", module = "plumbing",
    args = { "<agent>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "checkstamp", module = "plumbing",
    args = { "<agent>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "receive", module = "plumbing",
    args = { "<dir>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "repo", module = "repo",
    subs = {
      import = { args = { "<dir>" } },
      base = { args = { "<text>" }, flags = { ["--from"] = "<dir>" } },
    },
    hidden = true,
  },
  { name = "__complete", module = "complete",
    args = { "<text>..." },
    hidden = true,
    audience = "plumbing",
  },
  -- Restarts a promoted agent once it isn't working and tells it who promoted it (iso <role> promote).
  { name = "__promote-finish", module = "roles",
    hidden = true,
    audience = "plumbing",
  },
  -- A repo's surfaces, scanned, as JSON (isovim.surfaces): for scripts, checks and other hosts.
  { name = "__surfaces", module = "surfaces",
    args = { "<repo>..." },
    hidden = true,
    audience = "plumbing",
  },
  -- Spawns the worker for a report a supervisor claimed from the bug queue (isovim.bugs).
  { name = "__bug-take", module = "bugs",
    args = { "<id>" },
    hidden = true,
    audience = "plumbing",
  },
  -- A bug worker records the issue it opened or commented on.
  { name = "__bug-done", module = "bugs",
    args = { "<id>", "<url>" },
    hidden = true,
    audience = "plumbing",
  },
  -- Whether claude or codex is logged in here, as JSON (isovim.auth): for iso move to ask the host
  -- an agent moves to.
  { name = "__auth", module = "inspect",
    args = { "claude|codex" },
    hidden = true,
    audience = "plumbing",
  },
  -- The role warnings for a command bin/iso runs itself (iso browser).
  { name = "__warn", module = "roles",
    hidden = true,
    audience = "plumbing",
  },
}

-- Actions that exist only under a role, written as `iso <action>` like the rest: iso <role> help
-- puts the role in.
local SURFACE_FLAGS = { ["--name"] = "<text>", ["--repo"] = "<repo>" }
M.role_actions = {
  raise = { name = "raise", module = "surfaces",
    args = { "<question>", "<text>..." },
    summary = "give a question root mode has you decide to the user, with a one-line why",
    help = [=[
       iso raise <question> [<why...>]
                                     give a question you can't stand behind to the user: it
                                     moves to their host Inbox with your one-line why (your
                                     recommendation), and no root answers it after. The same
                                     as iso answer <question> --raise [<why...>]]=],
  },
  surface = { name = "surface", module = "surfaces",
    subs = {
      question = { args = { "<path>" }, flags = SURFACE_FLAGS },
      file = { args = { "<path>" }, flags = SURFACE_FLAGS },
      folder = { args = { "<dir>" }, flags = SURFACE_FLAGS },
      chat = { args = { "<agent>" }, flags = SURFACE_FLAGS },
      link = { args = { "<text>", "<text>..." }, flags = vim.tbl_extend("force", SURFACE_FLAGS, { ["--note"] = "<text>", ["--title"] = "<text>" }) },
    },
    summary = "put a question, a file or folder, or a chat in your repo's Inbox",
    help = [=[
       iso surface question <json|file|-> [--name n]
                                     ask the user in your repo's Inbox: JSON {question,
                                     options: [{label, description?}], multi?, other?,
                                     name?}, checked at once. Blocks until it's
                                     answered, then prints the answer (each label
                                     chosen on a line, then any words of the user's)
                                     and removes the question, so run it in the
                                     background. Run again (same name or same
                                     question), it reattaches, and an answer given
                                     meanwhile comes back at once
       iso surface file|folder <path> [--name n]
                                     show a file or folder in your repo's Inbox; a
                                     missing one gets a .surface.error beside it
       iso surface chat <agent> [--name n]
                                     point the user at an agent's chat; it leaves the
                                     Inbox once they open it
       iso surface link <url|address|thing> [label] [--note "one line"] [--name n]
                                     a link to a web page (a localhost dev server, a
                                     preview deploy, a dashboard) or anything in
                                     isovim (an iso: address, or what iso link
                                     takes), its label and note shown: in the Inbox
                                     until the user opens it (<CR>; a web page in
                                     isovim's Chrome), then under Files
                                     These go in ~/.iso/<owner>/<repo>/iso/, where you
                                     also write <name>.md surfaces yourself (optional
                                     frontmatter: name, icon (a glyph, or a word:
                                     mail, chart, doc, bug, rocket, idea, plan, ...),
                                     color, consumable) and
                                     tasks.md, the Task Board (headings todo, doing,
                                     waiting, blocked, done; one task a line). From a
                                     shell, --repo owner/repo says whose]=],
  },
  page = { name = "page", module = "surfaces",
    subs = {
      comments = { args = { "<text>" }, flags = { ["--all"] = false } },
      reply = { args = { "<text>", "<text>", "<text>..." }, flags = { ["--ask"] = false } },
      resolve = { args = { "<text>", "<text>", "<text>..." } },
    },
    summary = "read, answer and resolve the user's comments on a page",
    help = [=[
       iso page comments <page> [--all]
                                     a page's open comments (--all: resolved ones too),
                                     each with the lines it's on, what they said then
                                     and its replies. A page is iso/pages/<name>.md in
                                     your repo's iso/, markdown the router writes for
                                     the user to read and comment on (design docs go
                                     there); <page> is its name, or <repo>/<name>
       iso page reply <page> <id> <text...> [--ask]
                                     reply under a comment; --ask when it asks the
                                     user something: the page waits on them, in their
                                     Inbox, until they reply
       iso page resolve <page> <id> [<note...>]
                                     resolve a comment once the page does what it asks,
                                     with a note of what changed; it leaves the page]=],
  },
  link = { name = "link", module = "surfaces", shared = true,
    args = { "<text>" },
    summary = "the iso: address of an agent, PR, thread, page or path, to link it",
    help = [=[
       iso link <thing>              print the iso: address of an agent (owner/repo/aN or aN),
                                     a PR (#12, owner/repo#12 or its URL), a thread (t3), a
                                     page or surface (its name) or a path; a web page's URL
                                     (localhost:3000 too) is its own address. Written in a post,
                                     a thread, a page or a PR comment, isovim draws it as a
                                     chip (glyph, label, state) that <Tab> or gf opens:
                                     iso:agent/<owner>/<repo>/aN, iso:thread/<repo>#t3,
                                     iso:pr/<owner>/<repo>#12, iso:surface/<repo>/<name>,
                                     iso:page/<repo>/<name>[#c4], iso:file/<path>]=],
  },
  thread = { name = "thread", module = "surfaces",
    subs = {
      new = { args = { "<text>", "<text>..." } },
      post = { args = { "<text>", "<text>..." }, flags = { ["--image"] = "<path>" } },
      resolve = { args = { "<text>", "<text>..." } },
      rename = { args = { "<text>", "<text>..." } },
      ask = { args = { "<text>", "<path>" } },
      ls = { flags = { ["--all"] = false } },
      show = { args = { "<text>" } },
    },
    summary = "a repo's threads: one idea's conversation between the user and the router",
    help = [=[
       iso thread new "<title>" ["first post"] [--no-reply]
                                     open a thread for each ask that's different, rather
                                     than burying it in your own chat; prints its id (t1,
                                     t2...).
                                     Threads live in iso/threads/ of a repo with a
                                     router here (none in General or Root). The user's
                                     posts come to you as prompts tagged [thread
                                     <repo>#<id> "<title>"]: answer them as usual, and
                                     your turn's last message is posted to the thread
                                     for you (tool calls stay in your chat). A thread
                                     the user stopped at the title of comes the same
                                     way, the title as their first post
       iso thread post <id> <text...> [--image <file>]... [--no-reply]
                                     post to a thread anytime: a follow-up, or what a
                                     worker finished that it was about. After a post
                                     it's the user's turn, the thread in their Inbox
                                     until they post. --no-reply: it needs nothing from
                                     them
       iso thread waiting <id> none|<agent>|user
                                     whose turn it is from now on. In a turn whose last
                                     message posts itself, run it before you end the
                                     turn: it stands for that post, in place of the
                                     user's turn. Whenever a post needs nothing from the
                                     user, say so, or they're nagged. On an agent it
                                     clears once that agent finishes or is removed, and
                                     you're told, so the thread doesn't sit
       iso thread resolve <id> [<outcome...>]
                                     resolve it once it's settled, without being asked,
                                     with its outcome; it goes under the open ones, then
                                     off the list after 5 more
       iso thread ask <id> <json|file|->
                                     ask the user in the thread, not the repo's
                                     Inbox: the same JSON as surface question. It
                                     waits in the thread (and the Inbox lists it,
                                     root mode deciding it first as any question)
                                     and blocks until it's answered, then prints the
                                     answer, so run it in the background; run again,
                                     it reattaches
       iso thread rename <id> <title...>
                                     a new title (posts already sent keep their tags)
       iso thread ls [--all]         the repo's open threads (--all: resolved too)
       iso thread show <id>          a thread's posts
                                     Routers make, post, rename and resolve threads; any other
                                     role reads them (ls, show)]=],
  },
  promote = { name = "promote", module = "roles",
    args = { "<agent>|router|repo-root|root", "router|repo-root|root", "<text>" },
    summary = "raise an agent (default: you) to router, repo-root or root",
    help = [=[
       iso promote [<agent>] router|repo-root|root ["reason"]
                                     raise an agent (default: you): a worker to router when
                                     it's in a repo with no router here; a worker or router
                                     to repo-root, or any of those to root, when there's none.
                                     No demotion. It restarts on its conversation as the new
                                     role (an ACP agent's session reloads once its turn ends),
                                     and one you promote gets a stamped message saying who and
                                     why, after that. A router or repo-root made root is
                                     forked: the fork is the root, the original keeps its role]=],
  },
  restart = { name = "restart", module = "roles",
    args = { "<agent>", "<text>" },
    flags = { ["--now"] = false },
    summary = "restart an agent (default: you) on its session once its turn and background work end",
    help = [=[
       iso restart [<agent>] ["note"] [--now]
                                     restart an ACP agent (default: you) on its session at the
                                     same address once its running turn ends, its queue kept;
                                     its next message says who restarted it, and the note
                                     (else to continue where it left off). You restart
                                     yourself and the agents below you; a router or repo-root
                                     any agent in its repo; the root any on this host.
                                     It also waits for the agent's background shells (a
                                     background Bash, a Monitor) to end, an hour at most,
                                     then kills them and says what it killed. --now doesn't
                                     wait for them; it still never cuts a running turn.
                                     Supervisors also restart themselves onto isovim's new
                                     code when it changes on disk, when idle, by the same
                                     rule]=],
  },
  rm = { name = "rm", module = "roles",
    args = { "<agent>..." },
    flags = { ["--keep-branch"] = false, ["--force"] = false },
    summary = "remove an agent you manage once its work is done",
    help = [=[
       iso rm <agent>... [--keep-branch] [--force]
                                     remove agents you may restart once their work is done,
                                     several in one go (one refused doesn't stop the rest):
                                     not mid-turn or with a question in the Inbox. Its
                                     supervisor stops and its record and aN/ go, as d in the
                                     sidebar does; its children go to its parent. Its journal
                                     and transcript stay in iso/ (iso find still sees it),
                                     its pushed branches and PRs stay, and its local branch
                                     goes once origin has all of it (--keep-branch keeps it).
                                     A worktree with uncommitted or unpushed work refuses,
                                     saying what's there; --force drops the uncommitted files
                                     and keeps unpushed commits on its branch]=],
  },
  wt = { name = "wt", module = "work",
    flags = { ["--from"] = "<text>" },
    summary = "make your worktree (aN/<repo>-aN) if you have none, and print its path",
    help = [=[
       iso wt [--from <branch|PR>]   your worktree, made if you have none, and its path: a
                                     new-layout agent's is aN/<repo>-aN, a name no other
                                     agent's has (aN/w links to it; you start in aN, so cd to
                                     the path it prints), on a new branch $USER/<your name>
                                     off origin's default branch, or --from an existing branch
                                     or PR (number or URL), from the repo's base clone (made
                                     if missing); then the repo's worktree_setup runs in it.
                                     It says when the repo has a setup script that hasn't run
                                     there. A workspace's agent has the workspace's checkout]=],
  },
  setup = { name = "setup", module = "work",
    summary = "run your repo's setup script in a pane named setup",
    help = [=[
       iso setup|teardown            run your repo's setup or teardown script (in
                                     ~/.isovim/repos/<owner>/<repo>/config.json) in your
                                     worktree (else aN), in a pane named for it, listed
                                     under Terminals; prints the pane's address, which peek
                                     and wait take. Again restarts it. Scripts get
                                     SUPERSET_WORKSPACE_PATH|NAME, SUPERSET_ROOT_PATH, and
                                     ISOVIM_WORKTREE_NAME and COMPOSE_PROJECT_NAME, both the
                                     worktree's dir name (<repo>-aN); the config's env
                                     ({NAME: value}, or false for none) wins over them.
                                     setup warns when another stack running here (docker
                                     ps) has the same compose project or a port the repo's
                                     compose file publishes, and runs anyway]=],
  },
  teardown = { name = "teardown", module = "work",
    summary = "run your repo's teardown script in a pane named teardown",
  },
  run = { name = "run", module = "work",
    args = { "<action>" },
    summary = "run your repo's run script, or one of its actions, in a pane named for it",
    help = [=[
       iso run [<action>]            the same for the run script, or one of the config's
                                     actions (name -> command list)]=],
  },
}

-- The entry iso <role> <name> runs; nil when the role has no such action.
---@return table?
function M.action(role, name)
  if not M.rank[role] or not name then
    return nil
  end
  local entry = M.role_actions[name] or M.find(name)
  local listed = vim.tbl_contains(M.shared, name) or vim.tbl_contains(M.only[role] or {}, name) or (entry and entry.shared)
  return listed and entry or nil
end

-- A role's actions in the order its help lists them.
---@return string[]
function M.actions(role)
  local names = {}
  for _, name in ipairs(vim.list_extend(vim.list_extend({}, M.shared), M.only[role] or {})) do
    if M.action(role, name) then
      names[#names + 1] = name
    end
  end
  return names
end

-- A help line as the role runs it: `iso ls ...` becomes `iso worker ls ...`, its description kept in
-- the column when there's room.
local function under_role(line, role)
  if not line:match("^       iso ") then
    return line
  end
  local head, said = line, nil
  -- What it does starts in column 38; a flag or argument there is still the command.
  if line:sub(37, 37) == " " and line:sub(38, 38):match("[^%s%[<%-]") then
    head, said = line:sub(1, 36):gsub("%s+$", ""), line:sub(38)
  end
  head = head:gsub("^       iso ", "       iso " .. role .. " ", 1)
  if not said then
    return head
  elseif #head <= 35 then
    return head .. (" "):rep(37 - #head) .. said
  end
  return head .. "\n" .. (" "):rep(37) .. said
end

-- A line as help writes one: the command, then what it does from column 38.
local function help_line(command, said)
  local head = "       iso " .. command
  return head .. (" "):rep(math.max(2, 37 - #head)) .. said
end

function M.role_usage(role)
  local parts = {
    ("usage: iso %s <action> ..."):format(role),
    ("       what a %s agent runs. isovim checks that the agent's record says %s and, for"):format(role, role),
    "       now, only warns when it doesn't",
  }
  for _, name in ipairs(M.actions(role)) do
    local entry = M.action(role, name)
    for line in vim.gsplit(entry.help or help_line(name .. " ...", M.summary(entry) or ""), "\n", { plain = true }) do
      parts[#parts + 1] = under_role(line, role)
    end
  end
  parts[#parts + 1] = help_line(role .. " help", "this list")
  return table.concat(parts, "\n")
end

local by_name
---@return table?
function M.find(name)
  if not by_name then
    by_name = {}
    for _, entry in ipairs(M.list) do
      by_name[entry.name] = entry
    end
  end
  return name and by_name[name]
end

-- A retired command, once enforcement is on: help and completion leave it out, and it fails.
local enforced
function M.retired(entry)
  if enforced == nil then
    enforced = require("isovim.config").enforced()
  end
  return entry.retired ~= nil and enforced
end

function M.usage()
  local parts = { M.header }
  for _, entry in ipairs(M.list) do
    if not M.retired(entry) then
      parts[#parts + 1] = entry.help
    end
  end
  parts[#parts + 1] = M.footer
  return table.concat(parts, "\n")
end

-- A command's line in completion: its summary, or the first thing its help says it does.
function M.summary(entry)
  if entry.summary or not entry.help then
    return entry.summary
  end
  local lines = vim.split(entry.help, "\n")
  local said = lines[1]:match("^%s*iso .-%s%s+(%S.*)$")
  for i = 2, #lines do
    said = said or lines[i]:match("^" .. (" "):rep(37) .. "([^%s%[].*)$")
  end
  return said and (said:gsub(";.*", ""))
end

return M
