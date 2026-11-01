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
~/iso/
  <owner>/<repo>/
    iso/
      agents/aN.json             agent records (role, parent, session id, read-only, state)
      journal/aN.jsonl           each agent's conversation as isovim events
      transcripts/               plain-text transcripts, for grep
      *.surface, *.md            surfaces; tasks.md is the Task Board
    aN/w/                        an agent's worktree, made the first time it needs one
  root/  general/                the pseudo-repos, same shape
```

- Agent numbers are never reused.
- `root` and `general` are reserved; a real owner with one of those names gets a suffixed folder.
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
- The queue can be edited, reordered, cleared or "sent now" (which cancels the running turn).
- Cancel is a protocol call.

**Permissions.**
- Sessions run in bypass mode, as agents do today.
- Structured questions an agent asks (AskUserQuestion) become **question surfaces** in its repo's
  Inbox, and the answer goes back to the agent.
- A permission request that still arrives also becomes a question surface (allow / deny).

**Resume, fork, rewind.**
- A restarted supervisor loads its session by id.
- Fork copies the session, optionally up to a message.
- Rewind means editing one of your earlier prompts: isovim forks at the message before it, starts the
  agent's new session there, and sends the edited prompt. File changes are restored separately, from
  per-turn git snapshots in the agent's worktree.
- `/new`, `/clear`, `/resume` and `/fork` are implemented by isovim; every other slash command goes to
  the agent.

**Handing a session to Claude's own screen.** `iso handover <agent>` closes the ACP session, runs
`claude --resume` in the pane, and reloads the session when Claude exits. One writer at a time.

## The chat

A chat is a real nvim buffer drawn to look like Claude's screen:
- `⏺` messages and `⎿` tool results, drawn with extmarks;
- tool calls folded by default, diffs colored inline, a spinner while working;
- streamed token by token, following the bottom only when you're there;
- long lines wrap; there's no sideways scrolling.

The input box is another buffer under it, with full vim editing.

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
| markdown | the router writes `name.md` with frontmatter (`name`, `icon`, `color`, `consumable`) | rendered markdown and an input box; the router rewrites it in place |
| question | `iso router surface question <json\|file>`, which blocks until answered and prints the answer | options `{question, options:[{label, description}], multi?, other?}`; removed once answered |
| file / folder | `iso router surface file\|folder <path>` | opens beside the chat |
| chat | `iso router surface chat <agent>` | a green dot; consumed when you press Enter on it |
| Task Board | the router edits `tasks.md`: headings todo / doing / waiting / blocked / done, one line per task | rendered as a list |

- Rerunning a question reattaches to the same one, and returns its answer if it's already been given.
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
- tools: `browser`, `pilot` (one holder at a time), `spawn`, `promote`, `fork`, `checkhealth`, `version`

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
| `g` / `T` | general / terminals |
| `s` / `t` | spawn / new terminal |
| `x` | root mode for this repo |
| `j` | jump |
| `<` / `>` | switch host |
| `q` | the prompt queue |
| `u` / `f` | rewind / fork at the cursor |

**In the chat**
- `]]` / `[[` jump between your prompts; `]m` / `[m` between any messages.
- `za` folds; `i` / `a` / `o` / `<CR>` go to the input box; `<C-c>` cancels; `gf` opens a file.

**In the input box**
- `<CR>` sends; `<S-CR>` adds a newline; `<Up>` / `<Down>` browse history when it's empty.
- `<Esc>` drops to normal mode; `<C-k>` goes up to the chat.

**In the sidebar**

| key | does |
|---|---|
| `<CR>` / `<Tab>` | open / collapse |
| `<` / `>` | switch host |
| `<C-j>` / `<C-k>` | move between windows |
| `s` / `t` | spawn / new terminal |
| `r` / `d` / `R` / `m` | rename / remove / restart / move |
| `x` | root mode |
| `o` / `y` / `c` | open the port / copy the PR URL / changes |
| `u` | measure CPU/RAM |
| `H` / `P` / `L` | toggles |
| `?` | help |

## Cutover

v0 starts fresh rather than migrating.

`iso cutover --dry-run` lists what will be removed: every workspace, legacy agent, worktree and pin.
Then, after your go, `iso cutover`:
1. pushes any dirty or unpushed worktree to a `wip/<agent>` branch;
2. stops every legacy agent;
3. seeds the repo configs and base clones;
4. wipes the old layout: it is moved, not deleted, into `~/.isovim/legacy-backup-<date>/`.

The old conversations in `~/.claude/projects` are left untouched. Every agent, including clu's root,
starts cold.

## After v0

- isovim's own plugin list in place of LazyVim.
- Events and attach across hosts (`host.*`, `<host>:` topics).
- A kanban view of `tasks.md`.
