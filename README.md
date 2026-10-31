# isovim

Agents first, in nvim. `iso` opens an nvim built around coding agents: a sidebar of workspaces, each with its Claude Code and Codex agents, terminals, PRs and dev servers. Agents keep running in tmux when the window closes. Plain `nvim` stays your editor; `iso` is for when the agents come first.

It's an isomer of neovim: the same parts, arranged around the agents.

## What it does

- **Workspaces.** One per task. A workspace can get its own git worktree and branch, runs its repo's setup script, and shows its diff size, PRs (with CI state) and the ports its dev servers listen on.
- **Agents.** Claude Code, Codex, terminals or any command, as many per workspace as you like. Each runs in its own tmux session and resumes its conversation when restarted. The sidebar shows which are working, which have something new for you and which are waiting on you, and a Needs-you pane lists those.
- **Pins.** Agents pin the files they point you at (a report, a screenshot, the file they changed) under their workspace; Enter opens one beside the chat.
- **Agents working together.** Every agent can list, find, read, wait on and message the others, on this host or another, from the shell: `iso ls`, `iso find`, `iso peek`, `iso wait`, `iso send`.
- **Other hosts.** Agents on your other machines show in the sidebar, and `m` moves a workspace (conversations, branch, uncommitted work) to another host over ssh.
- **A browser for agents.** `iso browser` runs one Chrome per host that agents drive over CDP, in the background, without taking your focus.
- **Hot reload.** Edit isovim's source and the running app picks it up.

## Install

Needs nvim 0.11+, tmux 3+, git, jq, ripgrep, lsof, node, `gh` (signed in), and `claude` and/or `codex`.

```sh
git clone https://github.com/isaacchacko/isovim ~/isovim
ln -s ~/isovim/bin/iso ~/.local/bin/iso
iso doctor
iso
```

The first `iso` installs its plugins (a LazyVim-based config in `starter/`, under its own `NVIM_APPNAME`, so your nvim config is untouched).

## Use

In the sidebar, `?` lists every key. The ones to start with:

| key | does |
|---|---|
| `a` / `A` / `t` | new workspace / agent / terminal |
| `Enter` | open the agent, PR or pin |
| `d` | remove the agent or pin, or archive the workspace |
| `P` / `H` / `L` | PRs, hidden agents, ports |
| `E` / `W` | files / back to workspaces |
| `<leader>e` | focus or close the sidebar |
| `Ctrl-h` / `Ctrl-l` | between the sidebar and the chat |

`iso help` lists the commands.

## Make it yours

Everything lives in `~/.isovim/`:

- **`instructions.md`** is added to what every agent is told at launch.
- **`config.json`**, all optional:
  ```json
  {
    "self": "laptop",
    "hosts": { "desktop": "desktop.local" },
    "aliases": { "box": "desktop" },
    "repo_dirs": ["~/clients"],
    "idle_after": 30
  }
  ```
  `hosts` are your other machines by ssh name, `repo_dirs` are more folders whose repos are offered when making a workspace (`~`, `~/code`, `~/src`, `~/Programs` and the like are always looked in).
- **`hooks/idle`**, any executable, runs once every agent has been quiet for `idle_after` minutes, once per quiet spell.
- **`iso agent <ws> claude --prompt "<text>"`** starts an agent on a prompt, so scripts can start work, and `iso ls --json` says when each agent was last active.

A repo can ship workspace scripts in `.isovim/config.json` (or a Superset `.superset/config.json`, read as-is): `setup`, `teardown` and `run` command lists.

## Develop

`pilot/iso.py` runs an isolated isovim headless (its own home, tmux servers and a fake agent), presses keys, reads nvim over RPC and renders the screen to PNG. Changes are checked by piloting, not by a test suite.

## License

MIT
