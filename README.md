# icarus

Claude Code agents in nvim, organized by tasks. A task has a `task.md`, a folder of files, and agents that work with you in those files: they comment on lines, propose edits you accept or reject, and watch what you type. It began as a rebuild of isovim, which lives on in the `isovim` branch.

![icarus: the sidebar of chats, one waiting on a permission, its chat on the right](docs/screenshot.png)

## Install

Needs nvim 0.11+, node and npm, and `claude` (logged in).

```sh
git clone https://github.com/isaacchacko/icarus ~/icarus
ln -s ~/icarus/bin/icarus ~/.local/bin/icarus
ln -s ~/icarus/bin/icarus ~/.local/bin/ica
icarus
```

`icarus` is plain nvim with this checkout's `init.lua`, under its own `NVIM_APPNAME` (`icarus`, so its data is under `~/.local/share/icarus`), so your nvim config and data are untouched. The first chat installs the pinned ACP adapter, `claude-agent-acp`, with npm.

## Use

- **Tasks**: `<leader>m` is the list of tasks, `<leader>f` finds a task, `<leader><leader>` goes back to the last one, and `<D-[>` and `<D-]>` go back and forward through views.
- **A task's screen**: one buffer at a time, centred, with an outline of everything on the task: files, agents, visuals, PRs. `<leader>h` goes into it, `<CR>` opens a row, ◆ marks what's waiting on you, `<leader>z` is zen, `<leader>k` opens the drawer with the header and PRs.
- **Agents**: `<leader>g` is the graph, `<leader>d` turns a chat from what was said to its full details.
- **Files**: `<leader>w` watches a file with the agent you're in, so your edits reach it with its next turn. `<leader>c` comments on a line, and agents answer with comments and proposals.

Agents use `ica`: `ica help` lists what it gives them. `ica bug <what happened>` files a report in `~/.icarus/bugs/`.

## Orchestration

A task runs in one style, set by `orchestration:` in its `task.md` header or with `<leader>o`.

- **router-worker**: one lead is your interface, and workers do one job each. `<leader>A` turns on auto mode, where the lead stands in for you and decides what it can. `~/.icarus/auto.md` adds what it should know about you.
- **democracy**: peers wire themselves into a graph of claims and typed edges, in `<leader>g`. A claim reaches you through a reviewer, decisions go to a vote, and icarus refuses a move that would deadlock them.

**Daedalus** wakes once a day (`<leader>D` for now), reads what agents did, finds what was lost, and coaches them through `~/.icarus/daedalus/coaching.md`, each change a bet it checks later. It follows `~/.icarus/daedalus/prompt.md` if you've written one, and `bin/daedalus-measure` prints the numbers.

Agents run in bypassPermissions mode while icarus does. Quitting stops them; opening one again loads its session, history and all.
