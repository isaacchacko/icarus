# icarus

Claude Code chats in nvim, stripped down from isovim. `icarus` (or `ica`) opens a sidebar of your chats, newest first, each marked working, idle or needs you, beside a home page where `n` starts a new chat. Every chat is Claude over ACP, drawn the way Claude Code draws its own screen, in a real nvim buffer.

![icarus: the sidebar of chats, one waiting on a permission, its chat on the right](docs/screenshot.png)

## Install

Needs nvim 0.11+, node and npm, and `claude` (logged in).

```sh
git clone https://github.com/isaacchacko/isovim ~/isovim
ln -s ~/isovim/bin/icarus ~/.local/bin/icarus
ln -s ~/isovim/bin/icarus ~/.local/bin/ica
icarus
```

`icarus` is plain nvim with this checkout's `init.lua`, under its own `NVIM_APPNAME` (`icarus`, so its data is under `~/.local/share/icarus`), so your nvim config and data are untouched. The first chat installs the pinned ACP adapter, `claude-agent-acp`, with npm.

## Use

- **Home**: `n` starts a new chat in the dir `icarus` was started in.
- **Sidebar**: `<CR>` opens the chat under the cursor (home on the top line), `n` starts a new one.
- **Chat**: type in the composer under it; `<CR>` sends (in insert mode too, `<S-CR>` for a new line), `<C-c>` interrupts. A prompt sent while Claude works waits its turn. A permission Claude asks for shows as its numbered box: type the number and `<CR>`, or `<CR>` on an option. `za` opens or collapses a tool call's output or a thought.

Chats run while icarus does, in bypassPermissions mode. Quitting stops them; opening one again loads its session, history and all.

## Files

- `init.lua`, `bin/icarus`: the config and the launcher.
- `lua/icarus/init.lua`: the layout, sidebar on the left and home or a chat beside it.
- `lua/icarus/chats.lua`: the list of chats (`stdpath("data")/chats.json`) and their status.
- `lua/icarus/sidebar.lua`, `lua/icarus/landing.lua`: the sidebar and home.
- `lua/icarus/acp/session.lua`: one chat's ACP connection; `client.lua` and `transport.lua` are its JSON-RPC over stdio, `adapter.lua` installs and starts claude-agent-acp, `imports.lua` expands your CLAUDE.md `@imports`, which the adapter doesn't.
- `lua/icarus/acp/chat.lua`, `look.lua`: drawing a chat, and how it looks.
