# isovim

Claude Code chats in nvim. `iso` opens a sidebar of your chats, newest first, each marked working, idle or needs you, beside a home page where `n` starts a new chat. Every chat is Claude over ACP, drawn the way Claude Code draws its own screen, in a real nvim buffer.

![isovim: the sidebar of chats, one waiting on a permission, its chat on the right](docs/screenshot.png)

## Install

Needs nvim 0.11+, node and npm, and `claude` (logged in).

```sh
git clone https://github.com/isaacchacko/isovim ~/isovim
ln -s ~/isovim/bin/iso ~/.local/bin/iso
iso
```

`iso` is plain nvim with this checkout's `init.lua`, under its own `NVIM_APPNAME` (`isovim-next`), so your nvim config and data are untouched. The first chat installs the pinned ACP adapter, `claude-agent-acp`, with npm.

## Use

- **Home**: `n` starts a new chat in the dir `iso` was started in.
- **Sidebar**: `<CR>` opens the chat under the cursor (home on the top line), `n` starts a new one.
- **Chat**: type in the composer under it; `<CR>` sends (in insert mode too, `<S-CR>` for a new line), `<C-c>` interrupts. A prompt sent while Claude works waits its turn. A permission Claude asks for shows as its numbered box: type the number and `<CR>`, or `<CR>` on an option. `za` opens or collapses a tool call's output or a thought.

Chats run while isovim does, in bypassPermissions mode. Quitting stops them; opening one again loads its session, history and all.

## Files

- `init.lua`, `bin/iso`: the config and the launcher.
- `lua/isovim/init.lua`: the layout, sidebar on the left and home or a chat beside it.
- `lua/isovim/chats.lua`: the list of chats (`stdpath("data")/chats.json`) and their status.
- `lua/isovim/sidebar.lua`, `lua/isovim/landing.lua`: the sidebar and home.
- `lua/isovim/acp/session.lua`: one chat's ACP connection; `client.lua` and `transport.lua` are its JSON-RPC over stdio, `adapter.lua` installs and starts claude-agent-acp, `imports.lua` expands your CLAUDE.md `@imports`, which the adapter doesn't.
- `lua/isovim/acp/chat.lua`, `look.lua`: drawing a chat, and how it looks.
