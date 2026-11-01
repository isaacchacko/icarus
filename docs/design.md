# isovim design (v0)

isovim is an agent mux built on nvim. You work at the speed of thought: the system brings you what
needs you, with its context loaded, and keeps everything else moving without you.

isovim provides the mechanisms; clu (or anyone) plugs in the policy, such as which prompt each role
gets. It's a personal tool, not built for teams.

## Vocabulary

| word | meaning |
|---|---|
| **host** | a machine |
| **repo** | a codebase identified by its remote, `owner/repo` |
| **pseudo-repo** | `root` (the host root, pinned first), `general` (agents with no repo, and files outside every repo), `terminals` |
| **agent** | one ACP session run by a supervisor, addressed `<owner>/<repo>/aN` |
| **role** | `worker` < `router` < `repo-root` < `root` |
| **surface** | a file in a repo's `iso/` that shows you something; some take an answer |
| **Inbox** | the surfaces waiting on you |

## On disk

```
~/.isovim/
  config.json                    hosts, prompts per role, repo_defaults {glyph, palette}
  repos/<owner>/<repo>/
    config.json                  glyph, color, setup / teardown / worktree_setup / run / actions
    base-clone/                  detached at origin's default branch; read-only agents work here
  events/events.jsonl            the event bus
~/.iso/
  <owner>/<repo>/
    iso/
      agents/aN.json             agent records (role, parent, session id, read-only, state)
      journal/aN.jsonl           each agent's conversation as isovim events
      transcripts/               plain-text transcripts, for grep
      *.surface, *.md            surfaces; tasks.md is the Task Board
      images/                    images pasted or dropped into an input box
    aN/w/                        an agent's worktree, made the first time it needs one
  root/  general/                the pseudo-repos, same shape
```

- Agent numbers are never reused.
- `root` and `general` are reserved; a real owner with one of those names gets a suffixed folder.
- The work root was `~/iso`, which a shell with AUTO_CD (oh-my-zsh's default) enters when `iso` is
  typed in `~`. The first `iso` command or TUI start that finds it moves it to `~/.iso`, every agent
  at the same address: chat agents restart there on their sessions, worktrees are repaired, terminals
  keep running. With an agent mid-turn (or claude logged out) it waits, and `~/iso` stays the work
  root until it moves.
- Config syncs to the other hosts (`~/.isovim/repos/` and `config.json`, skipping `base-clone/`) on
  every write.

## Agents run over ACP

**The supervisor.** Each agent's tmux pane runs `nvim -l agent_host.lua <addr>` (tmux still owns
lifetimes, so agents outlive the TUI).

- It starts the ACP adapter (`claude-agent-acp` or `codex-acp`, pinned), with `CLAUDE_CODE_EXECUTABLE`
  set to your own `claude` and `CLAUDE_CODE_ENTRYPOINT` set so sessions stay visible to
  `claude --resume`.
- It creates or loads the session, passing the role prompt and isovim's hooks.
- It expands `@imports` from the CLAUDE.md files itself, since the adapter doesn't, and appends them to
  the session prompt.
- It always drains the adapter's output, writes every update to the journal, and publishes status and
  messages to the event bus.
- It serves an nvim RPC socket. The TUI, `iso attach` and the CLI all talk to the agent through it.

**Prompts and messages.**
- A prompt sent while the agent is busy is **queued** and delivered when its turn ends. This covers
  yours and other agents' alike, so nothing is ever typed into a shared box.
- The queue shows by itself while prompts wait, between the chat and the input box (see The chat).
  It can be edited, reordered, cleared or "sent now" (which cancels the running turn).
- A prompt that queues while you edit the queue isn't lost when you write it: it goes after yours.
- A prompt can carry images, as Claude Code's does: each is a file under the repo's `iso/images/`,
  shown in the text as `[Image #n]`, and travels by path (the queue and the journal keep paths, not
  bytes). The supervisor reads them into ACP image blocks (base64 and mimeType) when the prompt goes,
  if the adapter's `promptCapabilities.image` says it takes them (claude-agent-acp and codex-acp both
  do; a Codex model without image input refuses the prompt), else it names the files in the text.
  Deleting a chip, in the input box or in the queue's buffer, drops its image. `iso send|msg --image
  <file>` attaches one.
- Cancel is a protocol call.

**Permissions.**
- Sessions run in bypass mode, as agents do today.
- Structured questions an agent asks (AskUserQuestion) become **question surfaces** in its repo's
  Inbox, and the answer goes back to the agent.
- A permission request that still arrives also becomes a question surface (allow / deny).

**Resume, fork, rewind.**
- A restarted supervisor loads its session by id.
- `iso <role> restart [<agent>] ["note"]` restarts an agent: itself or one below it (it started it, or
  started one that did); a router or repo-root, any agent in its repo; the root, any on the host. The
  supervisor waits for the running turn to end (it never cancels it), puts `[isovim: you were
  restarted by <who>: <note>]` (with no note, to continue where it left off) first in its queue on
  disk, and has the tmux server run `iso restart`, what `R` in the sidebar does. The next supervisor
  resumes the session at the same address and sends the queue, that message first.
- A supervisor restarts itself onto isovim's new code. Every 30s, and whenever it goes idle, it
  compares the mtime and size of the files it runs (`acp/agent_host.lua` and every isovim module it
  has loaded, so a change only the TUI runs, like the chat's, restarts nothing) with what it started
  on. On a change it waits a random 0-60s, so a dozen agents don't restart in the same second, and
  restarts if it's still idle: no turn, nothing queued or held, no question waiting, no handover. It
  gets no message, since nothing was cut off. A changed file that doesn't compile keeps it on the old
  code, said once in its chat. A pull or isovim's self-update only has to change the files.
- Fork copies the session, optionally up to a message.
- Rewind means editing one of your earlier prompts: isovim forks at the message before it, starts the
  agent's new session there, and sends the edited prompt. File changes are restored separately, from
  per-turn git snapshots in the agent's worktree.
- `/new`, `/clear`, `/resume` and `/fork` are implemented by isovim; every other slash command goes to
  the agent.

**Handing a session to Claude's own screen.** `iso handover <agent>` closes the ACP session, runs
`claude --resume` in the pane, and reloads the session when Claude exits. One writer at a time.

## The chat

A chat is a real nvim buffer drawn to look like Claude Code's screen (docs/chat-compare/ has the two
side by side):
- your prompt on Claude's gray band after `❯`; the agent's text after Claude's bullet (`⏺` on macOS,
  `●` elsewhere, as Claude has it), its markdown's `code` and **bold** drawn, not shown;
- each tool call one line as Claude names it, `Update(app.py)`, `Bash(./count.sh)`, its bullet
  colored by status, and what came back under `⎿`: a read's line count, an edit's diff numbered from
  the file's lines on red and green with the changed words brighter and the code highlighted, a
  command's first lines and `… +N lines` (`za` opens and closes any of them);
- thinking dimmed and collapsed, the todo list as Claude's, the turn's summary after it;
- a permission or a question as Claude's numbered box, answered by its number in the input box or
  `<CR>` on an option (or from its question surface in the Inbox), then put away;
- Claude's colors, for dark and light backgrounds;
- streamed token by token, following the bottom only when you're there: while its end is on screen
  (a long line's last wrapped row too), and in the chat while your cursor is on its last line;
- long lines wrap; there's no sideways scrolling.
Everything drawn is a pure function of the journal, so a replay draws what live drew.

The input box is another buffer under it, with full vim editing: Claude's spinner line above it
while the agent works (its verb, the time, tokens, how to interrupt), a rule above and below it,
`❯` before it and a hint under it. It takes images as Claude's prompt does: `<C-v>` in insert mode
pastes the clipboard's (pngpaste or osascript on macOS, wl-paste or xclip on Linux), and with no
image there is vim's own `<C-v>`, so a literal insert still works; a path to an image pasted or
dropped in (quoted, backslash-escaped or a `file://` URL), or typed and then sent, attaches that
file, copied under `iso/images/` since a dragged screenshot is a temp file. Each shows as an
`[Image #n]` chip, in the input box and in the chat. A surface's input box takes them the same way.
A paste doesn't block: the statusline shows `󰋩 pasting image ▰▰▰▱▱▱` (filling with the bytes copied
for a file, sweeping while the clipboard is read) until the chip lands where `<C-v>` was pressed,
or says for a few seconds why it failed.

While prompts wait, the queue shows between the two, in a window of its own: one prompt a line, as
tall as its lines up to six, titled `queued · N`. It opens as the first prompt queues and closes when
the last one goes; `q` hides it until another queues. It's a buffer you edit: change, reorder or
delete lines, or add one, and `:w` makes it the queue; `<CR>` on a line sends that prompt now. A
redraw never touches it while you're editing it, nor closes it. It isn't part of a saved layout: the
chat brings it back wherever its input box shows, so switching workspaces, opening another agent or
restarting leaves no stray queue window.

The column is always the chat, the queue while it shows, and the input box at the bottom, six lines
tall. A drag on a separator, `:resize` or a restored layout can't change the input box's height, and
a window that would come between them or under them (a split opened from the chat) goes beside the
chat instead.

`<C-j>` / `<C-k>` walk down and up the column, chat → queue → input box, as they walk the sidebar's
windows; with no queue showing they go straight between the chat and the input box.

`iso attach <agent>` opens a minimal nvim attached to that agent's supervisor: the same chat and input
box, from any terminal or over ssh. `iso phone` picks an agent (needs-you first) and attaches.

## Roles and root mode

- **Starting role:** every agent starts as a worker. An agent spawns only roles at or below its own, and
  the limits hold: one router per repo per host, one repo-root per repo, one root per host.
- **Promotion** is done by agents (themselves or another), one way only:
  - worker → router: in a repo with no router on this host.
  - worker or router → repo-root, and any of those → root: only if that level is empty.
  - Router → root and repo-root → root fork the agent, so the repo keeps its router or root with the
    same context.
  - A promoted agent reloads its session with the new role's prompt. If another agent promoted it, it
    receives a message saying who and why.
- **Roots have no parent.** When an agent is removed, its children go to its parent; at the top, to the
  repo's router.
- **Role prompts** are files set in `config.json` (`prompts`). The host root's prompt lists the actions
  that are permanently off; agents are trusted to follow it.
- **Root mode:** `iso rootmode on|off <repo|host> [--task "<description>"]` spawns a worker and promotes
  it.
  - A router's questions go to the most specific active root.
  - A repo root narrowed by `--task` raises everything outside it to your Inbox. The description is
    guidance only, delivered as the root's first message.
  - Roots answer questions with `iso <root|repo-root> answer`.
  - Your delegated authority (stamps) belongs to the host root.

## Surfaces

Surfaces are files in a repo's `iso/`, written only by its router. isovim watches them, hot-reloads
them, and writes a `*.surface.error` beside any that's broken or whose target is gone.

| type | made by | shown as |
|---|---|---|
| markdown | the router writes `name.md` with frontmatter (`name`, `icon`, `color`, `consumable`) | rendered markdown and an input box (it takes images, as the chat's does); the router rewrites it in place |
| question | `iso router surface question <json\|file>`, which blocks until answered and prints the answer | a buffer of its own: who asked, the question, its options numbered (`{question, options:[{label, description}], multi?, other?}`); answered there, then shows the answer; removed once its asker has it |
| file / folder | `iso router surface file\|folder <path>` | opens beside the chat |
| chat | `iso router surface chat <agent>` | a green dot; consumed when you press Enter on it |
| Task Board | the router edits `tasks.md`: headings todo / doing / waiting / blocked / done (a heading's first word names it), one line per task | the sections that hold tasks, each task after its status's glyph, an owner like `(a1)` dimmed, alone in its window with no input box; one that doesn't parse shown as it is and marked broken |

- Rerunning a question reattaches to the same one, and returns its answer if it's already been given.
- A question opens beside the chat (or in the main window) like a markdown surface, never as a
  popup, drawn in the chat's question-box style. `<CR>` on an option or its number picks it; in a
  multi question they tick it (`<Space>` too) and Submit or `s` sends. One that takes your own words
  has the input box under it, whose `<CR>` sends them. The answer goes the way `iso answer`'s does,
  and the buffer shows it, as it does when the question is answered elsewhere; `q` closes it. An
  agent's permission request (Allow / Deny) is one of these too.
- PRs appear only when the router registers them (`iso router pr`).

## The sidebar

```
S (7) - swarming            ← style meter: live agents on this host
Inbox 2                     ← other hosts' waiting items (Enter switches host)
‹ macbook ›                 ← the host you're viewing (< >)
  Inbox 1                   ← this host: root surfaces + one row per busy repo
  root  ⏺
  isovim ●                  ← repo header in its color; opens the router
    Inbox                   ← this repo's surfaces
    router · rework vocab
    a3 · tab line fix        (workers; teams behind them are counted, not listed)
  general
Terminals 2                 ← this host's terminals; script panes marked with a robot
cpu 12%  ram 18/24G         ← u to measure
Settings
ISOVIM 2de9e2b
```

Every Inbox shows only surfaces, and each surface type has its own row format. In root mode, an Inbox
shows a "root mode" marker beside its count.

## Events

Every change is appended as a JSON line to `~/.isovim/events/events.jsonl`. Topics:

- `agent.<scope>.<id>.status|spawned|exited|promoted`
- `msg.<scope>.<id>`
- `surface.<repo>.<name>.created|changed|removed|answered|consumed`
- `pr.<repo>.<n>.state|ci|review`
- `root.<scope>.raised|decided`

Segment values encode `%` and `.` as `%25` and `%2E`. `iso <role> listen <pattern>… [--once]`
streams the matching events, with `*` matching one part and `**` any number.

## The CLI

- `iso <worker|router|repo-root|root> <action>` is for agents, checked against the caller's identity.
- `iso <action>` (bare) is for you, and refuses agents.
- Actions every role needs repeat under each role.
- `iso completion zsh|bash` gives Tab completion at every position, plus the `iso jump` shell function.

**Every role:**
- talking and watching: `msg`, `ls`, `status`, `peek`, `wait`, `find`, `transcript`, `listen`
- tools: `browser`, `pilot` (one holder at a time), `spawn`, `promote`, `restart`, `fork`, `checkhealth`,
  `version`

**Router and worker:** `wt`, `setup`, `teardown`, `run <action>`, resolved for the calling agent.

**Router only:** `surface question|file|folder|chat`, `pr`.

**Roots:** `answer`.

**Yours:** `iso` opens the TUI. The bare commands are:
- `spawn` (no parent), `jump` (fzf drill-down with `.` and `..`)
- `attach`, `phone`, `handover`
- `move`, `rm`, `restart`, `rename`, `rootmode`, `answer`
- `listen`, `verify`, `checkhealth`

**Retired:** `pin`, `ask`, `task`, `doctor` (a hidden alias until 2026-12-01), the workspace commands.

## Lifecycle

- **Read-only agents** (`--read-only`) run in `base-clone/`, fetched at start, and their write tools
  are refused.
- **Worktrees:** an agent gets one with `wt`, or automatically on its first edit. `setup` runs the
  repo's setup script only when asked.
- **The edit guard:** every agent's edit in a clone of a repo isovim knows (one under
  `~/.isovim/repos/`), outside its own `aN/w`, is refused, with word to spawn an agent into that repo;
  repos isovim doesn't know, like `~/.clu/discs` and dotfiles, stay editable. For v0 it reads Bash
  only for git commands, so a shell write (`sed -i`, `cp`, `>>`) or git behind a variable gets
  through: agents aren't dumb, and the guard is there for mistakes, not for an agent working round it.
- **Teardown:** when an agent is removed, isovim runs the repo's teardown and deletes `aN/`. Unsaved
  work is discarded.
- **The reaper** runs every 10 minutes and tears down any `aN/` with no record. It runs as a dry run,
  logging only, until v0 is cut over.

## Keys

Plain nvim keys keep their meaning: windows, buffers, hunks, lazygit. File keys translate to repos
and agents, and everything isovim-specific lives under `<leader>i`.

**Global**
- `<leader><leader>` picks a repo; `<leader>ff` finds a file in it; `<leader>/` greps it, transcripts
  included.
- `<leader>,` shows the repo's buffers; `<leader>fr` shows recent agents (`<leader>fR` recent files).
- `<leader>e` opens or closes the sidebar.

**`<leader>i`**

| key | does |
|---|---|
| `n` | the next thing that needs you |
| `i` / `h` / `I` | the repo / host / other-hosts Inbox |
| `r` | the router |
| `R` | the nearest root |
| `H` | the host root |
| `w` / `a` | pick a worker / pick any agent |
| `b` | the previous agent |
| `p` | the previous repo, at the agent last open there |
| `g` / `T` | general / terminals |
| `s` / `t` | spawn / new terminal |
| `x` | root mode for this repo |
| `j` | jump |
| `<` / `>` | switch host |
| `q` | the prompt queue (opened even when empty, to add a line) |
| `u` / `f` | rewind / fork at the cursor |
| `l` | the landing |

**The landing**
- On start, when there is nothing to resume, the editing area shows the landing (`isovim.landing`):
  what isovim is, the Inbox count, the repos in `~/.isovim/repos`, the keys that matter (their words
  read from the key tables, as `?` does) and quick actions on single keys: `s` spawn in a repo picked,
  `p` pick a repo, `j` jump, `i` the host's Inbox, `t` a terminal, `m` send a repo to a host, `?` help.
  `<leader>il` brings it back. It belongs to no workspace, so no layout keeps it.

**In the chat**
- `]]` / `[[` jump between your prompts; `]m` / `[m` between any messages.
- `za` folds; `i` / `a` / `o` / `<CR>` go to the input box; `<C-c>` cancels; `gf` opens a file.
- `<C-j>` goes down to the queue while it shows, else to the input box.

**In the queue**
- Edit lines and `:w`; `<CR>` sends the prompt on the line now; `q` hides it.
- `<C-k>` goes up to the chat, `<C-j>` down to the input box.

**In the input box**
- `<CR>` sends; `<S-CR>` (or `<M-CR>`, for a terminal that can't send `<S-CR>`) adds a newline;
  `<Up>` / `<Down>` browse history when it's empty.
- `<C-v>` pastes the clipboard's image (vim's own `<C-v>` when there's none).
- `<Esc>` drops to normal mode; `<C-k>` goes up to the queue while it shows, else the chat, in either
  mode; `<C-j>` does nothing, as nothing is below it.

**Into the sidebar and back**
- `<C-h>` goes to the sidebar from anything in the main column (a chat, the queue, the input box,
  a surface or question and its input box), in insert mode too: in the input box it takes the place of vim's backspace,
  which is `<BS>`. It lands in the sidebar window you were last in (the list at first), on the row
  you left there, found by what it stands for (an agent, repo, surface or PR) since rows move as
  the list refreshes; if that row is gone, on the agent you came from, then its repo.
- `<C-l>` from the sidebar goes back to the window you came from, typing again where you were if
  you were (the main window if it shows something else now).

**In the sidebar**

| key | does |
|---|---|
| `<CR>` / `<Tab>` | open / collapse |
| `<` / `>` | switch host |
| `<C-j>` / `<C-k>` | move between windows |
| `<C-l>` | back to the window you came from |
| `s` / `t` | spawn / new terminal |
| `r` / `d` / `R` / `m` | rename / remove / restart / move |
| `x` | root mode |
| `o` / `y` / `c` | open the port / copy the PR URL / changes |
| `u` | measure CPU/RAM |
| `H` / `P` / `L` | toggles |
| `?` | help |

`m` sends the row under the cursor to a host picked from the peers (this one left out), by `iso move`.
On a repo's header (or General's) it sends every agent of the repo (`iso move <owner>/<repo> <host>
--all`): parents first, so workers keep their router there; terminals stay. All of them are checked
before any goes, and the host asked, so a refusal (an agent mid-turn, a root, uncommitted work, the
host unreachable) says why and moves none. Once they're there the list shows that host, on the
repo. On an agent's row it moves that agent alone, like every other row key acting on its row; on
another host's agent it brings it here.

## Hot reload

The TUI watches its own source (`isovim.reload`): `lua/isovim/` and every directory under it, and
`starter/`. On macOS one recursive watcher covers each; on Linux, where inotify watches one directory,
each directory has its own and one made later (a pull's) is watched as it appears.
- **Hot reloads:** any `.lua` under `lua/isovim/`, `acp/` and `cli/` included, and `reload.lua`
  itself. Every isovim module is unloaded and `setup` runs again. What's on screen takes the new
  code: an open chat is made again on its own buffers and drawn again from its journal, keeping
  each window's scroll, the composer's text, the tool calls and thoughts you opened or collapsed and
  a rewind you're editing; surface views and the sidebar re-bind their keys and redraw; timers call
  through `require`, and the ones that hold a closure (the migrate timer, the chat's spinner) are
  replaced. `starter/lua/config/keymaps.lua` runs again.
- **Needs a restart:** the rest of `starter/` (the plugin specs, `config/lazy.lua`), which lazy.nvim
  reads once at startup; a changed `lazy-lock.json` also needs `:Lazy restore`. The toast says so.
- **Agents restart themselves:** the agents' supervisors (`nvim -l agent_host.lua`: `acp/host.lua`,
  `acp/client.lua`, `acp/adapter.lua` and the rest they load) keep the code they started with until
  they restart, which each does by itself at its next idle moment (see Agents run over ACP, Resume);
  `R` in the sidebar restarts one at once. The toast names such files.

Events are taken together (200ms after the last, and not while git holds its index lock), so a save
or a `git pull` of many files is one reload. Changed files are compiled first: one that doesn't, or
a module that fails as it loads, keeps the old code, and the toast gives the error. The toast names
the changed files (or how many, past four). A TUI that started on a `reload.lua` from before this
needs one restart to get it.

## Cutover

v0 starts fresh rather than migrating.

`iso cutover --dry-run` lists what will be removed: every workspace, legacy agent, worktree and pin.
Then, after your go, `iso cutover`:
1. pushes any dirty or unpushed worktree to a `wip/<agent>` branch;
2. stops every legacy agent;
3. seeds the repo configs and base clones;
4. wipes the old layout: it is moved, not deleted, into `~/.isovim/legacy-backup-<date>/`.

The old conversations in `~/.claude/projects` are left untouched. Every legacy agent, including
clu's root on cleopatra, starts cold. New-layout agents keep running, a host's `root/aN` among them.

## After v0

- isovim's own plugin list in place of LazyVim.
- Events and attach across hosts (`host.*`, `<host>:` topics).
- A kanban view of `tasks.md`.
