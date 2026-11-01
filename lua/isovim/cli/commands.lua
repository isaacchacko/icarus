-- Every iso command, in the order `iso help` lists them. This one table drives cli.lua's dispatch,
-- `iso help`, Tab completion (isovim.cli.complete) and bin/iso, which finds a command by the
-- `{ name = "<command>",` that starts its entry here, so keep each entry starting that way.
--   name      the word after iso
--   module    isovim.cli.<module> runs it, as the function of the same name; none means bin/iso does
--   args      its words in order, as usage writes them: <kind>, literal|literal|<kind>, and a last
--             one ending in ... repeats. Kinds are what Tab offers: ws, archived, agent (this host's),
--             address (an agent here or <host>:<agent>), host, kind, role, command, topic (an
--             event pattern), path, dir, and text and n, which offer nothing
--   flags     flag -> the kind of its value, or false for a flag without one
--   subs      subcommand -> { args, flags }, for a command whose first word picks what it does
--   help      its lines in `iso help`, verbatim; summary is its one line in completion, when the
--             help doesn't give one
--   hidden    not offered by completion
--   shared    an action every role has too (iso <role> <name>), once commands take a role first
--   audience  who runs it: nil is anyone (every command until roles); "plumbing" is isovim's own
--             hooks, hosts and shell completion, which any refusal of agents or users lets through
local M = {}

M.header = [=[
usage: iso                           open the TUI (iso --takeover to steal it from another terminal)]=]

M.footer = [=[
<ws> is a workspace id, name, or unique prefix of either. <agent> is <ws>/<agent id or name>,
or just <ws> for the workspace's first visible agent. send, msg, status, wait and peek also take
<host>:<agent> for an agent on another host (hosts in ~/.isovim/config.json).]=]

M.list = {
  { name = "ls", module = "inspect",
    flags = { ["--json"] = false },
    help = [=[
       iso ls [--json]               list agents: ws/agent, status, role, workspace · agent, parent]=],
  },
  { name = "new", module = "workspaces",
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
    args = { "<ws>", "<dir>|-" },
    help = [=[
       iso dir <ws> [path|-]         print, set or (-) clear its project dir]=],
  },
  { name = "rename", module = "workspaces",
    args = { "<ws>|<agent>", "<text>..." },
    help = [=[
       iso rename <ws|agent> <name>   rename a workspace, or an agent (<ws>/<agent>)]=],
  },
  { name = "archive", module = "workspaces",
    args = { "<ws>" },
    help = [=[
       iso archive <ws>              stop its agents and move it to the archive]=],
  },
  { name = "archived", module = "workspaces",
    help = [=[
       iso archived                  list archived workspaces, newest first]=],
  },
  { name = "unarchive", module = "workspaces",
    args = { "<archived>" },
    help = [=[
       iso unarchive <ws>            bring one back (a worktree workspace gets its worktree)]=],
  },
  { name = "move", module = "workspaces",
    args = { "<ws>", "<host>" },
    flags = { ["--force"] = false },
    help = [=[
       iso move <ws> <host> [--force]   move it to another host (ssh name); its agents resume
                                     there. --force moves it even while an agent is working]=],
  },
  { name = "agent", module = "agents",
    args = { "<ws>", "<kind>" },
    flags = {
      ["--name"] = "<text>",
      ["--hidden"] = false,
      ["--cmd"] = "<text>",
      ["--prompt"] = "<text>",
      ["--role"] = "<role>",
      ["--parent"] = "<address>",
    },
    help = [=[
       iso agent <ws> <kind> [--name n] [--hidden] [--cmd c] [--prompt text] [--role r]
                     [--parent agent]
                                     add an agent (claude|codex|terminal|command), start it;
                                     --prompt starts a claude or codex agent on that prompt;
                                     --role root|router|worker (default worker) picks the
                                     role prompt it's told (prompts in ~/.isovim/config.json).
                                     Its parent is the agent running this (iso new and iso fork
                                     set it too), or --parent]=],
  },
  { name = "role", module = "agents",
    args = { "<agent>", "<role>" },
    help = [=[
       iso role <agent> [root|router|worker]   print or change its role; a change takes effect
                                     when it next restarts]=],
  },
  { name = "rm", module = "agents",
    args = { "<agent>" },
    help = [=[
       iso rm <agent>                stop an agent and remove it from its workspace; its children
                                     go to its parent (archiving a workspace does the same)]=],
  },
  { name = "pr", module = "workspaces",
    args = { "<ws>", "<text>" },
    help = [=[
       iso pr <ws> <url|owner/repo#n>   register a PR for the workspace (agents run this)]=],
  },
  { name = "prs", module = "workspaces",
    args = { "<ws>" },
    flags = { ["--json"] = false },
    help = [=[
       iso prs <ws> [--json]         its PRs with their state]=],
  },
  { name = "hide", module = "agents",
    args = { "<agent>" },
    help = [=[
       iso hide|unhide <agent>       hidden agents stay out of the sidebar and never notify]=],
  },
  { name = "unhide", module = "agents",
    args = { "<agent>" },
    summary = "show a hidden agent again",
  },
  { name = "open", module = "agents",
    args = { "<agent>" },
    help = [=[
       iso open <agent>              start it; show it in the TUI if open]=],
  },
  { name = "restart", module = "agents",
    args = { "<agent>" },
    help = [=[
       iso restart <agent>           restart it (Claude and Codex keep their conversation)]=],
  },
  { name = "attach", module = "agents",
    args = { "<agent>" },
    help = [=[
       iso attach <agent>            start it and attach this terminal to it (detach: C-b d)]=],
  },
  { name = "phone", module = "agents",
    help = [=[
       iso phone                     pick an agent to attach to, needs-you first; for small
                                     screens over SSH]=],
  },
  { name = "send", module = "messaging",
    args = { "<address>", "<text>..." },
    help = [=[
       iso send <agent> <text...>    type text into it and submit (starts it if needed); from
                                     an agent it starts with isovim's stamp,
                                     "[from <host>:<ws>/<agent> · m<id>]", to reply to]=],
  },
  { name = "msg", module = "messaging",
    args = { "parent|children|<address>", "<text>..." },
    summary = "iso send to its parent, its children, or any agent",
    help = [=[
       iso msg <parent|children|agent> <text...>
                                     iso send to the agent that started this one, to each agent
                                     it started, or to any agent]=],
  },
  { name = "fork", module = "agents",
    args = { "<agent>" },
    flags = { ["--name"] = "<text>", ["--prompt"] = "<text>" },
    summary = "a tangent: a new workspace from a copy of an agent's conversation",
    help = [=[
       iso fork [<agent>] [--name n] [--prompt text]
                                     a tangent: a new workspace in the same project whose agent
                                     starts from a copy of <agent>'s conversation (default: the
                                     agent running this); nothing opens it, so focus stays put]=],
  },
  { name = "ask", module = "messaging",
    args = { "<text>..." },
    help = [=[
       iso ask <question...>         from an agent: ask the root; the root (or anyone, with no
                                     root) raises it to you, into the Inbox]=],
  },
  { name = "root", module = "messaging",
    args = { "<address>" },
    flags = { ["--clear"] = false },
    summary = "print or set the root",
    help = [=[
       iso root [<agent>|--clear]    print or set the root, the agent the others ask and whose
                                     stamped messages speak for you; <host>:<ws>/<agent> for a
                                     root on another host]=],
  },
  { name = "verify", module = "messaging",
    args = { "<text>" },
    flags = { ["--json"] = false, ["--here"] = false },
    help = [=[
       iso verify <m-id> [--json]    what isovim recorded for a stamp]=],
  },
  { name = "find", module = "inspect",
    args = { "<text>..." },
    flags = { ["--json"] = false, ["--local"] = false },
    summary = "find agents on every host by name, branch, PR or conversation",
    help = [=[
       iso find <query> [--json]     agents on every host ranked by where the query turns up:
                                     names, branch, PRs, what they're on, their conversation]=],
  },
  { name = "pin", module = "workspaces",
    args = { "<ws>", "<path>" },
    flags = { ["--label"] = "<text>" },
    help = [=[
       iso pin <ws> <path> [--label text]   show a file or folder under the workspace in the sidebar]=],
  },
  { name = "unpin", module = "workspaces",
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
    args = { "<address>" },
    help = [=[
       iso status <agent>            stopped | idle | working | attention | unread]=],
  },
  { name = "wait", module = "inspect",
    args = { "<address>" },
    flags = { ["--timeout"] = "<n>" },
    help = [=[
       iso wait <agent> [--timeout s]   block until it stops working, print the status]=],
  },
  { name = "peek", module = "inspect",
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
                                     agent.<agent>.status|spawned|exited|promoted, msg.<agent>,
                                     pr.<owner/repo>.<n>.state|ci|review. In a pattern * is any
                                     one dot-separated part, ** any number (quote them). --since
                                     starts from a time (epoch seconds, or 90s, 10m, 2h, 1d ago)]=],
  },
  { name = "closed", module = "events",
    args = { "<text>" },
    hidden = true,
    audience = "plumbing",
  },
  { name = "doctor", module = "inspect",
    help = [=[
       iso doctor                    check what isovim needs here and on the other hosts]=],
  },
  { name = "version", module = "inspect",
    help = [=[
       iso version                   the isovim commit this runs]=],
  },
  { name = "task", module = "agents",
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
       iso task rm <id>              remove one of your tasks and its subtasks
       iso task ls                   your tasks]=],
  },
  { name = "pilot", module = "pilot",
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
}

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

function M.usage()
  local parts = { M.header }
  for _, entry in ipairs(M.list) do
    parts[#parts + 1] = entry.help
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
