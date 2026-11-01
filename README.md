# isovim

An agent mux built on nvim. `iso` opens an nvim where coding agents come first: a sidebar of your repos, each with a router that runs its workers and an Inbox of what's waiting on you, and every agent's chat a real nvim buffer. Agents keep running when the window closes. isovim brings you what needs you, with its context loaded, and keeps everything else moving without you. Plain `nvim` stays your editor.

![isovim: the sidebar of repos and agents, an agent's chat on the right](docs/screenshot.png)

## What it does

- **Repos**, each with its agents, its Inbox, its PRs and its scripts, in its own glyph and color.
- **Agents** that run Claude Code over ACP, each in a chat drawn like Claude's own screen, with a vim input box under it. Messages sent while one works queue up; nothing is ever typed over you.
- **Roles**: workers do the work, a router per repo runs them and is your one interface to it, and roots decide for you while you're away.
- **Surfaces**: the router's questions, files, chats and Task Board, in the repo's Inbox.
- **Other hosts**: their agents and Inboxes in the same sidebar.

## Install

Needs nvim 0.11+, tmux 3+, git, jq, ripgrep, lsof, rsync, node and npm, `gh` (signed in), and `claude`.

```sh
git clone https://github.com/isaacchacko/isovim ~/isovim
ln -s ~/isovim/bin/iso ~/.local/bin/iso
iso checkhealth
iso
```

The first `iso` installs its plugins (a LazyVim-based config in `starter/`, under its own `NVIM_APPNAME`, so your nvim config is untouched) and seeds the role prompts in `~/.isovim/prompts/`. The first agent installs the pinned ACP adapter, `claude-agent-acp`, with npm.

## Use

In the sidebar, `s` spawns a worker in the repo under the cursor and opens its chat; type in the box under it and `Enter` sends. `Enter` on a repo opens its router, and on an Inbox row, that surface. `<leader>in` anywhere goes to the next thing that needs you. `?` lists every key.

`iso help` lists the commands. For Tab completion and the `iso jump` shell function, add `source <(iso completion zsh)` to ~/.zshrc after compinit (bash: `eval "$(iso completion bash)"` in ~/.bashrc).

## More

### The model

- A **repo** is a codebase, known by its remote, `owner/repo`. Beside the real ones are three pseudo-repos: `root` (the host root, pinned first), `general` (agents in no repo) and `terminals`.
- An **agent** is one ACP session, addressed `<owner>/<repo>/aN` (`_/aN` in General); numbers are never reused. Its supervisor runs in a tmux pane, so it outlives the TUI, and `claude --resume` sees its session. It starts in `~/iso/<owner>/<repo>/aN/` and gets its worktree, `aN/w`, on its first edit, on a new branch `$USER/<its name>` off origin's default branch. A read-only agent (`--read-only`) works in the repo's base clone instead, and its edits are refused.
- A **role** is `worker` < `router` < `repo-root` < `root`. Every agent starts as a worker. There's one router per repo per host, one repo-root per repo and one root per host. An agent spawns roles up to its own, and agents promote each other one way only: a worker to router, a worker or router to repo-root, any of them to root, each only when that place is empty. A promoted agent's session reloads with its new role's prompt; a router or repo-root made root is forked, so the repo keeps it. The agent that starts another is its parent, and a removed agent's children go to its parent (at the top, to the repo's router).
- A **surface** is a file in a repo's `~/iso/<owner>/<repo>/iso/`, written only by its router, that shows you something; some take an answer. isovim watches them and writes a `<file>.surface.error` beside one that's broken.

  | surface | made by | shows |
  |---|---|---|
  | markdown | the router writes `<name>.md` (optional frontmatter: `name`, `icon`, `color`, `consumable`) | the rendered file, rewritten in place |
  | question | `iso router surface question <json\|file\|->` | `{question, options: [{label, description}], multi?, other?}`; the router blocks until it's answered |
  | file / folder | `iso router surface file\|folder <path>` | the file or folder, beside the chat |
  | chat | `iso router surface chat <agent>` | an agent's chat, gone once you open it |
  | Task Board | the router edits `tasks.md` | headings todo, doing, waiting, blocked, done; one task a line |

- An **Inbox** is the surfaces waiting on you: each repo has one, the host's gathers the root's surfaces and a row per busy repo, and the top one counts other hosts'. PRs show only once the router registers them (`iso router pr`).
- **Root mode**: `iso rootmode on <repo|host> [--task "<description>"]` gives a repo (a repo-root) or the host (the root) an agent that decides the routers' questions while you're away, spawning a worker and promoting it if there's no root yet. A question goes to the most specific active root, which answers it (`iso <root|repo-root> answer`) or raises it to your Inbox (`--raise`). `--task` is the root's first message, guidance it narrows itself by. Only the host root's stamped messages carry your authority, and its prompt lists what's permanently off.

### Chats

- Each message is drawn as Claude draws it: `❯` your prompts, `⏺` the agent's text, `✻` thinking, tool calls one line each with their output folded under `⎿` (`za` opens one), diffs colored inline, Bash output streaming, a spinner while it works. It streams token by token and follows the bottom only when you're there.
- The input box is a buffer under the chat, with full vim editing. A prompt sent while the agent works, yours or another agent's, is queued and goes when its turn ends; `<leader>iq` opens the queue to edit, reorder or clear (`:w`), and `Enter` on a line sends it now, cancelling the running turn.
- `iso attach <agent>` opens the same chat and input box in a minimal nvim, from any terminal or over ssh; `iso phone` picks an agent, needs-you first, and attaches. `iso handover <agent>` gives the session to Claude's own screen (`claude --resume` in its pane) and takes it back when Claude exits.
- Sessions run in bypass mode and survive: a restarted agent loads its session, and `iso <role> fork` copies one.
- Landing now: fork up to a message (`<leader>if`); rewind (`<leader>iu`), which edits one of your earlier prompts, forks before it, sends the edited prompt and restores the files from per-turn snapshots; `/new`, `/clear`, `/resume` and `/fork` done by isovim (every other slash command goes to the agent); and a structured question or permission request from an agent becoming a question surface in its repo's Inbox, with your answer going back to it. Until then those keys say "not yet" and permission requests are denied.

### Keys

Plain nvim keys keep their meaning. File keys work on repos and agents, and everything isovim's own is under `<leader>i`.

- `<leader><leader>` picks a repo; `<leader>ff` finds a file in it and `<leader>/` greps it, transcripts included; `<leader>,` shows its buffers; `<leader>fr` recent agents (`<leader>fR` recent files); `<leader>e` opens or closes the sidebar.
- `<leader>i`: `n` the next thing that needs you; `i` / `h` / `I` the repo / host / other hosts' Inbox; `r` the router, `R` the nearest root, `H` the host root; `w` / `a` / `b` a worker / any agent / the previous one; `g` / `T` General / Terminals; `s` / `t` spawn / new terminal; `j` jump; `<` / `>` switch host; `q` the queue; `u` / `f` rewind / fork at the cursor; `x` root mode (not wired yet: use `iso rootmode`).
- In a chat: `]]` / `[[` your prompts, `]m` / `[m` any message, `za` folds, `i` / `a` / `o` / `Enter` to the input box, `<C-c>` cancels, `gf` opens a file. In the input box: `Enter` sends, `<S-CR>` (or `<C-j>`) a newline, `<Up>` / `<Down>` your earlier prompts while it's empty, `<Esc>` normal mode, `<C-k>` up to the chat.
- In the sidebar: `Enter` / `Tab` open / collapse, `<` / `>` switch host, `<C-j>` / `<C-k>` between windows, `s` / `t` spawn / terminal, `r` / `d` / `R` / `m` rename / remove / restart / move, `o` / `y` / `c` its port / copy the PR URL / its changes, `u` measure CPU and RAM, `H` / `P` / `L` hidden agents / PRs / ports, `?` help.

### The CLI

Agents run `iso <worker|router|repo-root|root> <action>`, checked against their own record (for now isovim warns on a mismatch; after cutover it refuses). Bare `iso <action>` is yours. `iso <role> help` lists a role's actions.

- **Every role**: `msg <agent|parent|children> <text>`, `ls`, `status`, `peek`, `wait`, `find`, `transcript`, `listen`; `browser`, `pilot` (drive the TUI, one holder at a time), `spawn [--role r] [--read-only] [--name n] "<prompt>"`, `promote [<agent>] <role> ["reason"]`, `fork`, `checkhealth`, `version`.
- **Workers and routers**: `wt [--from <branch|PR>]` makes the worktree up front; `setup`, `teardown` and `run [<action>]` run the repo's scripts in it, each in a pane of its own under Terminals. Setup runs only when asked.
- **Routers**: `surface question|file|folder|chat`, and `pr <owner/repo> <url>` to register a PR.
- **Roots**: `answer <repo>/<question> <answer...>`, or `--raise` to give it to you.
- **Yours**: `iso` opens the TUI. `spawn [--repo owner/repo|dir]` (with no parent), `jump` (fzf, one level at a time, `.` and `..`), `attach`, `phone`, `handover`, `move`, `rm`, `restart`, `rename`, `rootmode`, `answer`, `listen`, `verify`, `sync`, `checkhealth`.
- **Retired**: `task`, `pin` and `ask` still work for workspace agents until cutover; v0's replacements are the router's `tasks.md`, `surface file|folder` and `surface question`. `doctor` is a hidden alias of `checkhealth` until 2026-12-01.

Every message between agents carries isovim's stamp, `[from <host>:<agent> · m<id>]`, proven from the sending process, and it arrives as its own prompt; the receiver is told whether it's real, and only the host root's speak for you.

### Events

Every change is a JSON line in `~/.isovim/events/events.jsonl`: `agent.<scope>.<id>.status|spawned|exited|promoted`, `msg.<scope>.<id>`, `surface.<owner/repo>.<name>.created|changed|removed|answered|consumed` and `pr.<owner/repo>.<n>.state|ci|review`, where an agent's scope is its repo and its id `aN`. In a part, `%` is written `%25` and `.` `%2E`. `iso listen '<pattern>'... [--once] [--since 10m]` streams the matching ones, `*` matching one part and `**` any number: `agent.acme/app.**` is a whole repo.

### Make it yours

Everything lives in `~/.isovim/`:

- **`prompts/<role>.md`**, seeded on first run for worker, router, repo-root and root: what each role is for. They're policy, yours to edit; isovim never writes over one, and recreates one you delete. The root's lists the actions that are permanently off (spending money, force-pushing a shared branch, deleting remote data, posting publicly, approving a PR, changing credentials). isovim's own words for each role, how to use isovim, come first, then **`instructions.md`** (added for every agent), then the role's file.
- **`config.json`**, all optional:
  ```json
  {
    "self": "laptop",
    "hosts": { "desktop": "desktop.local" },
    "aliases": { "box": "desktop" },
    "repo_dirs": ["~/clients"],
    "idle_after": 30,
    "prompts": { "root": "~/notes/root.md", "router": "~/.isovim/prompts/router.md", "worker": null },
    "repo_defaults": { "glyph": "", "palette": ["teal", "magenta", "#ff9e64"] }
  }
  ```
  `hosts` are your other machines by ssh name. `prompts` names a file (relative to `~`) for each role; isovim fills in the seeded file for a role with no entry, and `null` gives a role none. `repo_defaults` is the glyph and the colors new repos are given; without it, the repo glyph and the twelve colors red to pink. Every write isovim makes to `config.json` or `repos/` is sent to your other hosts (`iso sync` sends it now); each host keeps its own `self` and `hosts`, and base clones stay put.
- **`repos/<owner>/<repo>/config.json`** is a repo's: `glyph`, `color` (`#rrggbb` or a palette name), and its scripts in Superset's format: `setup`, `teardown`, `run`, `worktree_setup` (run in each new worktree) and `actions` (name → command list, for `iso <role> run <action>`). A new repo gets the palette's next color. Its scripts are imported once from the repo's own `.isovim/config.json` or `.superset/config.json`. Beside it, `base-clone/` is the clone worktrees and read-only agents come from.
- **`hooks/idle`**, any executable, runs once every agent has been quiet for `idle_after` minutes.

### Other hosts, the browser, hot reload

- Other machines' agents show in the sidebar one host at a time (`<` / `>`), and the top Inbox counts what waits on you there.
- `iso browser` runs one Chrome per host that agents drive over CDP, with your logins, without taking your focus.
- Edit isovim's source and the running app picks it up.

### Cutover

v0 starts fresh rather than migrating. Until then, the workspaces and agents from before (in Claude's TUI, with `iso task`, `iso pin` and `iso ask`) keep running beside v0's and fold under their repo in the sidebar. `iso cutover --dry-run` will list what goes (every workspace, legacy agent, worktree and pin), and after your go `iso cutover` pushes any unsaved work to a `wip/<agent>` branch, stops the legacy agents, seeds the repo configs and base clones, and wipes the old layout. Conversations in `~/.claude/projects` are left alone. The reaper, which tears down `aN/` dirs with no agent every 10 minutes, only logs (to `~/.isovim/reaper.log`) until then.

## Develop

`pilot/iso.py` runs an isolated isovim headless (its own home, tmux servers, and fake agents: `pilot/fake-acp-agent` stands in for the ACP adapter and logs every frame it's sent), presses keys, reads nvim over RPC and renders the screen to PNG. Changes are checked by piloting, not by a test suite; `pilot/checks/` holds scripts that check one thing each.

## License

MIT
