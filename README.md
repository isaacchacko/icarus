# isovim

Agents first, in nvim. `iso` opens an nvim built around coding agents: a sidebar of workspaces, each with its Claude Code and Codex agents, terminals, PRs and dev servers. Agents keep running in tmux when the window closes. Plain `nvim` stays your editor; `iso` is for when the agents come first.

![isovim: workspaces with their agents, terminals and pins in the sidebar, an agent's chat on the right](docs/screenshot.png)

## What it does

- **Workspaces**, one per task, each with its own worktree, PRs and dev servers.
- **Agents**: Claude Code, Codex, terminals or any command, as many per workspace as you like.
- **Tasks** each agent keeps, shown under its row.
- **Pins**: the files an agent points you at, one Enter away.
- **Agents talking to each other**, with one root agent the others ask.
- **Other hosts**: their agents in the same sidebar, and workspaces that move between machines.

## Install

Needs nvim 0.11+, tmux 3+, git, jq, ripgrep, lsof, node, `gh` (signed in), and `claude` and/or `codex`.

```sh
git clone https://github.com/isaacchacko/isovim ~/isovim
ln -s ~/isovim/bin/iso ~/.local/bin/iso
iso checkhealth
iso
```

The first `iso` installs its plugins (a LazyVim-based config in `starter/`, under its own `NVIM_APPNAME`, so your nvim config is untouched).

## Use

In the sidebar, `?` lists every key. The ones to start with:

| key | does |
|---|---|
| `s` / `t` | spawn a worker in the repo under the cursor / new terminal |
| `Tab` | expand or collapse a workspace (all start collapsed) |
| `Enter` | open the agent, PR or pin |
| `d` | remove the agent or pin, or archive the workspace |
| `P` / `H` / `L` | PRs, hidden agents, ports |
| `E` / `W` | files / back to workspaces |
| `<` / `>` | the previous / next host's workspaces |
| `Ctrl-j` / `Ctrl-k` | between the Inbox, the workspaces, Terminals and the footer |
| `<leader>e` | focus or close the sidebar |
| `Ctrl-h` / `Ctrl-l` | between the sidebar and the chat |

Anywhere, LazyVim's keys work on repos: `<leader><leader>` picks a repo (or Root, General, Terminals), `<leader>ff` / `<leader>/` find files in / grep the repo and its agents' transcripts, `<leader>,` lists the repo's buffers, `<leader>fr` recent agents (`<leader>fR` recent files). The `<leader>i` group reaches agents: `in` the next one that needs you, `ir` / `iR` / `iH` the repo's router / nearest root / host root, `iw` / `ia` / `ib` a worker in the repo / any agent / the previous one, `is` / `it` spawn / new terminal. The `<leader>a` keys from before still work for now and say which key replaced them.

`iso help` lists the commands. For Tab completion of commands, agents, workspaces and hosts, add `source <(iso completion zsh)` to ~/.zshrc after compinit (bash: `eval "$(iso completion bash)"` in ~/.bashrc).

## More

### Workspaces and agents

- A workspace can get its own git worktree and branch, runs its repo's setup script, and shows its diff size, PRs (with CI and review state) and the ports its dev servers listen on. A PR an agent opens shows up by itself.
- Each agent runs in its own tmux session and resumes its conversation when restarted. The sidebar shows which are working, which have something new for you and which are waiting on you, and an Inbox lists those.
- Agents keep their own task lists (`iso task`), with status, parent steps, PRs and what they wait on; `T` shows them under each agent's row.
- Agents pin the files they point you at (a report, a screenshot, the file they changed) under their workspace; Enter opens one beside the chat.

### Agents working together

- Agents run their commands under their role, `iso <worker|router|repo-root|root> <action>` (`iso worker help` lists a worker's), and bare `iso <command>` is yours. isovim checks the role against the agent's record and, for now, only warns on a mismatch, or when an agent runs a bare command.
- Every agent can list, find, read, wait on and message the others, on this host or another, from the shell: `iso worker ls`, `find`, `peek`, `wait`, `msg`.
- **Its own work.** A worker or router runs `iso <role> wt [--from <branch|PR>]` for its worktree and `iso <role> setup`, `teardown` and `run [<action>]` for its repo's scripts, each acting on the agent that runs it (known by its process, not its cwd). A new-layout agent (`<owner>/<repo>/aN`) gets its worktree only when it asks: `aN/w`, on a new branch `$USER/<its name>` off origin's default branch (or the branch or PR given), made from the repo's base clone, which is cloned first if missing; the repo's `worktree_setup` then runs in it, and the agent, which starts in `aN/`, does `cd w`. A second `wt` just prints the path. Scripts run in `aN/w` (or `aN` before it has one), each in a pane of its own named for it and listed under Terminals as `<action> · <repo>/aN`; running one again restarts it. A workspace's agent keeps its workspace's checkout and panes.
- An agent that starts another (`iso <role> spawn`, `iso <role> fork`, `iso agent`, `iso new`) is its parent: `iso <role> msg parent` and `msg children` reach them, and removing an agent hands its children to its own parent. An agent spawns roles up to its own; there's one router per repo on a host, one repo-root per repo and one root per host. `iso spawn` starts one from a shell or a script, with no parent.
- **Promotion.** `iso <role> promote [<agent>] router|repo-root|root ["reason"]` raises an agent (itself by default): a worker to router in a git repo with no router here, a worker or router to repo-root or root when there's none. It restarts on its conversation with its new role's prompt, and one promoted by another agent gets a stamped message saying who and why. A router made root is forked: the fork is the root and the router stays. There's no demotion.
- **A root, and stamps you can trust.** Name one agent the root (`iso root`). Workers `iso ask` it; the root raises what's yours with `iso ask`, and only those raises show in the Inbox. Every message between agents carries isovim's stamp, proven from the sending process, so a receiver is told which stamps are real and that only the root's speak for you; a typed or reused tag is called out.

### Other hosts

Agents on your other machines show in the sidebar, one host at a time (`<` / `>`); the Inbox lists what waits on you on all of them. `m` moves a workspace (conversations, branch, uncommitted work) to another host over ssh.

### A browser for agents

`iso browser` runs one Chrome per host that agents drive over CDP, in the background, without taking your focus.

### Hot reload

Edit isovim's source and the running app picks it up.

### Make it yours

Everything lives in `~/.isovim/`:

- **`instructions.md`** is added to what every agent is told at launch.
- **`config.json`**, all optional:
  ```json
  {
    "self": "laptop",
    "hosts": { "desktop": "desktop.local" },
    "aliases": { "box": "desktop" },
    "repo_dirs": ["~/clients"],
    "idle_after": 30,
    "prompts": { "root": "~/notes/root.md", "router": "prompts/router.md" },
    "repo_defaults": { "glyph": "\uf401", "palette": ["teal", "magenta", "#ff9e64"] }
  }
  ```
  `hosts` are your other machines by ssh name, `repo_dirs` are more folders whose repos are offered when making a workspace (`~`, `~/code`, `~/src`, `~/Programs` and the like are always looked in). `prompts` names a file (relative to `~`) for each role, `root`, `repo-root`, `router` or `worker`, added after `instructions.md` to what agents of that role are told. `repo_defaults` is the glyph and the colors new repos are given (below); without it, the repo glyph and the twelve colors red to pink.
- **`repos/<owner>/<repo>/config.json`** sets how a repo's workspaces show in the sidebar, picked by their git origin: `{"glyph": "\uf1d3", "color": "teal"}`. `color` is `#rrggbb` or one of red, orange, yellow, lime, green, teal, cyan, sky, blue, purple, magenta, pink. The first time isovim sees a repo without a `color`, it writes one into this file, with the default glyph if it has none: the palette's next color, the one at (number of repo configs that have a color) mod (palette size), so repos take the colors in the order they're first seen and wrap round. From then on the file decides, so edit it to change them. A file that isn't valid JSON is never written over.
- **`hooks/idle`**, any executable, runs once every agent has been quiet for `idle_after` minutes, once per quiet spell.
- **Roles.** Every agent is a `worker` unless made a `root` (sets the north star), `repo-root` (holds one repo's) or `router` (a repo's one interface to you, running the swarm): promoted by an agent (above), `iso spawn --role router`, or `iso role <agent> router`, which it picks up when it next restarts. It's told its role, gets its role's prompt, and has it in `$ISOVIM_ROLE`; `iso ls` shows it.
- **`iso agent <ws> claude --prompt "<text>"`** starts an agent on a prompt, so scripts can start work, and `iso ls --json` says when each agent was last active.

A repo's workspace scripts, `setup`, `teardown` and `run` command lists in Superset's format, live in the same `repos/<owner>/<repo>/config.json`, beside `worktree_setup` (run in a new-layout agent's new worktree) and `actions` (name → command list, run by `iso <role> run <action>`, which Tab completes). A command whose first word is a file in that folder runs it, so scripts can sit beside the config (`"./setup.sh"`). The first time isovim looks for a repo's scripts and its config has none, it copies them from the repo's own `.isovim/config.json` (or a Superset `.superset/config.json`) and records `imported_from` and `imported_at`; it never imports again or writes over a key you set. A script the config lacks is still read from the repo's file.

## Develop

`pilot/iso.py` runs an isolated isovim headless (its own home, tmux servers and a fake agent), presses keys, reads nvim over RPC and renders the screen to PNG. Changes are checked by piloting, not by a test suite; `pilot/checks/` holds scripts that check one thing each. Pilots set `ISOVIM_WORK` (where agents' work lives, default `~/iso`) into their own tmp dir.

## License

MIT
