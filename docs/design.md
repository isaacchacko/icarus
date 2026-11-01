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
| **surface** | an agent's structured output, a file in a repo's `iso/` that isovim draws in a TUI buffer (a question, markdown, the Task Board, a file or folder, a chat); some take an answer |
| **thread** | one idea's conversation between you and a repo's router, a view of it apart from the router's own chat (`iso/threads/<id>.jsonl`); only in a repo with a router |
| **page** | markdown a router writes for you to read and comment on line by line (`iso/pages/<name>.md`) |
| **Inbox** | the surfaces that need you (`needs_you`): an unanswered question, a raised one, unread markdown, a chat not yet opened. Every other surface lists as a plain row under its repo |

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
- The queue shows by itself while prompts wait, in a window under the chat (see The chat).
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
- a markdown table as Claude draws it once its last row has come (until then, as written): box
  borders, columns as wide as their widest cell as it shows (wide glyphs two cells), each aligned as
  its `:---:` row says, the header bold, `code` and **bold** in cells drawn with their marks taken
  out; one wider than the window narrows its widest columns, whose cells wrap within the row;
- each tool call one line as Claude names it, `Update(app.py)`, `Bash(./count.sh)`, its bullet
  colored by status, and what came back under `⎿`: a read's line count, an edit's diff numbered from
  the file's lines on red and green with the changed words brighter and the code highlighted, a
  command's first lines and `… +N lines` (`za` opens and closes any of them, `<C-o>` all of them);
- thinking dimmed and collapsed, the todo list as Claude's, the turn's summary after it;
- a permission or a question as Claude's numbered box, answered by its number in the input box or
  `<CR>` on an option (or from its question surface in the Inbox), then put away;
- Claude's colors, for dark and light backgrounds;
- streamed token by token, following the bottom only when you're there: while its end is on screen
  (a long line's last wrapped row too), and in the window you're in while your cursor is in the
  input box;
- long lines wrap; there's no sideways scrolling.
Everything drawn is a pure function of the journal, so a replay draws what live drew.

The input box (the composer) is the same buffer's last lines, under the conversation, so motions,
`/` search, visual selections and yanks run across the conversation and your draft alike. It's
drawn as Claude's prompt: Claude's spinner line above it while the agent works (its verb, the
time, tokens, how to interrupt), a rule above and below it, `❯` before it and a hint under it, all
virtual text, so only what you type is text there. Normal mode works anywhere as in any buffer;
`i a o O I A c s C S R gi gI` on the conversation (and `c s C S R I A` on a selection there) take
you to the end of your draft, typing, and in the input box they're vim's own (a key a plugin
maps, as LazyVim's flash maps `s`, is left to it). The conversation is read-only: the buffer is
modifiable only while your cursor, and a selection's other end, is in the input box, so `dd`,
`x` or `p` on it is refused, with one quiet line (`the conversation is read-only: i to write in
your draft`, at most every few seconds) rather than vim's E21, and a change that still reaches it (`dk` from the input box's first
line, `:%s`) is caught as it happens and the chat drawn again from the journal, your draft as it
was before that change. `<BS>`, `<C-w>` and `<C-u>` stop at the input box's start, and `<Up>`
there stays (or walks your earlier prompts while the box is empty).

Output streams in above the input box, which moves down without moving your cursor in your text.
nvim's undo records rows, which that would throw off, so the buffer keeps none: the draft's own
states are kept, one per change in normal mode and one per insert, and `u` / `<C-r>` (`g-` /
`g+`) step through them, so `u` undoes your typing and never what streamed in. Following the end
means the input box at the window's bottom with the conversation's end right above it; a window
scrolled up shows the spinner line as its winbar, with `↓ more below`, as the input box is out of
sight there. Sending a prompt or an answer takes every window to the end.

The input box takes images as Claude's prompt does: `<C-v>` in insert mode pastes the clipboard's
(pngpaste or osascript on macOS, wl-paste or xclip on Linux), and with no image there is vim's own
`<C-v>`, so a literal insert still works; a path to an image pasted or dropped in (quoted,
backslash-escaped or a `file://` URL), or typed and then sent, attaches that file, copied under
`iso/images/` since a dragged screenshot is a temp file. Each shows as an `[Image #n]` chip, in the
input box and in the chat. A paste made up on the conversation goes into the input box, at its end.
A surface's input box (a buffer of its own) takes them the same way. A paste doesn't block: the
statusline shows `󰋩 pasting image ▰▰▰▱▱▱` (filling with the bytes copied for a file, sweeping while
the clipboard is read) until the chip lands where `<C-v>` was pressed, or says for a few seconds why
it failed.

While prompts wait, the queue shows in a window of its own under the chat's, right below the input
box: one prompt a line, as tall as its lines up to six, titled `queued · N`. It opens as the first
prompt queues and closes when the last one goes; `q` hides it until another queues. It's a buffer
you edit: change, reorder or delete lines, or add one, and `:w` makes it the queue; `<CR>` on a line
sends that prompt now. A redraw never touches it while you're editing it, nor closes it. It isn't
part of a saved layout: the chat brings it back under each window that shows it, so switching
workspaces, opening another agent or restarting leaves no stray queue window.

`<C-j>` / `<C-k>` walk down and up the column: from the
conversation `<C-j>` goes to the input box (typing), from the input box to the queue while it shows;
`<C-k>` goes from the queue to the input box and from the input box up to the conversation's end.

Closing the chat's tab (`Snacks.bufdelete`, `:bd`) closes the chat whole, its queue with it;
opening it again draws it afresh from the journal. (`:bd` unloads rather than wipes, and an
unloaded scratch buffer comes back as an empty file with a swap file.) Following and measuring skip
a window that's gone, shows another buffer or has no rows.

`iso attach <agent>` opens a minimal nvim attached to that agent's supervisor: the same chat, input
box and all, from any terminal or over ssh. `iso phone` picks an agent (needs-you first) and attaches.

## Threads

A single chat for a single idea is easy to read, but a new agent per small idea costs a cold start
each time, and one router taking every idea in its one chat is hard to follow. A thread is a
virtual chat: the router stays one agent with one session, its context warm, and each thread
shows only the exchanges about its one thing. Threads exist only in a repo with a router on this
host; General, Root and Terminals have none, and starting one there says why.

- **Stored** as `iso/threads/<id>.jsonl` (`t1`, `t2`…), appended to, never rewritten: a header
  `{kind: thread, id, title, created_by, at, status: open}`, then posts `{kind: post, by: user|<agent
  address>, text, at, images?}`, `resolved {by, outcome?}`, `reopened {by}`, and `working
  {state: start|end}` around the router's turn on one of its posts. What you've read is
  `run/<repo>/threads.json` (the last line seen, per thread).
- **The view** is the chat's (isovim.acp.chat on the thread's file instead of a journal), a tab of
  its own, drawn as the PR view is (isovim.boxes, its helpers shared with isovim.pr_view): a banner
  (an open or resolved pill, the title bold, a dim line: the router, who started it, how long ago,
  how many posts, the last one's age), then each post in a rounded box headed `author · time`,
  yours tinted as your prompts are, the router's border in its bullet's color, markdown and tables
  inside it with their marks taken out; a resolved thread ends with its outcome's box. The
  one-buffer composer stays at its end, unboxed (insert keys go to the draft, normal mode
  everywhere, the draft's own undo, `<C-v>` images). `<CR>` there posts, and sends the router a
  prompt through its queue: `[thread <repo>#<id> "<title>"] <text>` (and its images). While its
  turn on the post runs, the bar over the composer says `<router> is working on it…`. `r` on the
  conversation resolves the thread, or opens a resolved one again.
- **The router's replies:** its supervisor sees the tag on the prompt it delivers, marks that turn
  working in the thread, and when the turn ends posts its last message (what it said after its
  last tool call) there, so the router just answers. Its tool calls stay in its own chat. It posts
  anytime with `iso router thread post <id> "..."`, opens a thread for a new topic itself with
  `iso router thread new "<title>" ["first post"]` rather than bury it in its chat, and resolves one
  with `iso router thread resolve <id> ["outcome"]`; `thread ls [--all]` and `thread show <id>` read
  them, which any role may; only routers (and you, from a shell) make, post and resolve.
- **Starting one:** `t` on a repo's (or agent's) row in the sidebar, or `<leader>it` in the current repo: the
  view opens with its composer asking for the title (`<CR>`), then your first post.
- **Listed** as plain rows under the repo, newest first, with the thread glyph, title and how many
  posts (`working…` while the router's turn on it runs). One with a router post you haven't read
  waits on you: it's in the repo's and the host's Inbox (`new reply`) until you open it. A resolved
  one drops off the list (`thread ls --all` shows it); the jump picker lists the open ones.

## Roles and root mode

- **Starting role:** every agent starts as a worker. An agent spawns only roles at or below its own, and
  the limits hold: one router per repo per host, one repo-root per repo, one root per host.
- **A router's workers start hidden** (`iso router spawn --shown` for one the user should see): the
  sidebar, its team counts and the pickers leave them out until `H` shows them (persisted), and a
  hint at the list's end counts them (`3 hidden · H`). One that needs the user (a raised decision)
  still shows and notifies, and its surfaces are in the Inbox as anyone's. The user's spawns, and
  workers' and roots', show.
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
- **Root mode:** a root decides the Inbox's questions before they reach you.
  `iso rootmode on|off <repo|host> [--task "<description>"]` turns it on for a repo (its repo-root) or
  the host (the host root), spawning a worker and promoting it if the role is empty.
  - Questions aren't routed: each stays in its repo's Inbox. While root mode is on for its repo or
    the host, its root decides it first, however it was asked: a router's surface question, an ACP
    agent's AskUserQuestion, a shell. The root deciding a question is the repo's root, else the host
    root, never the one that asked it.
  - A question a root is deciding is tagged "root deciding" in its repo's Inbox (the surface's
    `deciding`, read when it's parsed) and doesn't need you: it isn't counted, notified, in the host
    Inbox or reached by `<leader>in` (`needs_you` is false). The root's answer
    (`iso <root|repo-root> answer`) clears it. Its raise (`iso <root|repo-root> raise <question>
    <why>`, or `answer --raise <why>`) writes `raised`, `raised_by` and `why` into the surface: the
    question goes to your host Inbox, its row and view showing the one-line why, and no root answers
    it after. An ACP agent's permission requests are raised from the start (`raised_by` isovim), since
    they let it run a tool its mode stopped.
  - You may answer anything, root deciding or not. The first answer wins, and reaches the asker the
    same way whoever gave it.
  - With root mode off, no root decides anything: every pending question needs you. So turning it on
    tags what's waiting, and turning it off puts what the root hadn't decided in your host Inbox,
    neither touching the files; the TUI rechecks its surfaces when `iso rootmode` runs, or within 5s
    of `rootmode.json` changing.
  - The root is told of each new question it decides, in one message per batch, and when root mode
    turns on gets one message listing those already waiting. The telling is a subscription: a root's
    ACP supervisor listens on the event bus for its Inboxes' question surfaces, a few seconds after
    the last, and catches up on start with those asked while it was down, so it doesn't matter who
    asked or scanned a question, or on what code. Each question is told once (marked in the scan's
    state).
  - A root narrowed by `--task` raises everything outside it. The description is guidance only,
    delivered as the root's first message.
  - Your delegated authority (stamps) belongs to the host root.

## Surfaces

Surfaces are files in a repo's `iso/`, written only by its router. isovim watches them, hot-reloads
them, and writes a `*.surface.error` beside any that's broken or whose target is gone. A markdown
surface, the Task Board or a question opens as a tab of its own in its repo's scope, named as its
Inbox row is (Task Board, the surface's title, the question's name) after the row's glyph; closing
the tab closes it and its input box, which has no tab. The landing is
one tab, isovim, in every scope.

| type | made by | shown as |
|---|---|---|
| markdown | the router writes `name.md` with frontmatter (`name`, `icon`, `color`, `consumable`) | rendered markdown and an input box (it takes images, as the chat's does); the router rewrites it in place |
| page | the router writes `pages/<name>.md` (frontmatter as markdown's), for design docs; its comments are `pages/<name>.comments.jsonl` beside it | rendered markdown you comment on line by line (see Pages below); a plain row with how many comments are open, in the Inbox only while a reply asks you something |
| question | `iso router surface question <json\|file>`, which blocks until answered and prints the answer | a buffer of its own: who asked, the question, its options numbered (`{question, options:[{label, description}], multi?, other?}`); answered there, then shows the answer; removed once its asker has it |
| file / folder | `iso router surface file\|folder <path>` | the file as a tab in the main window; the folder as the explorer's root |
| chat | `iso router surface chat <agent>` | a green dot; consumed when you press Enter on it |
| Task Board | the router edits `tasks.md`: headings todo / doing / waiting / blocked / done (a heading's first word names it), one line per task | the sections that hold tasks, each task after its status's glyph, an owner like `(a1)` dimmed, alone in its window with no input box; one that doesn't parse shown as it is and marked broken |
| PRs | isovim, for a repo (or the root) with PRs registered by `iso <role> pr` (which keeps who registered each and when) | drawn by isovim (`isovim_prs`) from the PRs' cache, never waiting on gh: grouped Open, Draft, Merged today, Closed, a merged or closed one gone a day after; a line each with its CI glyph, `#n` and title, its review (approved, changes requested, review required), the agent that registered it and its age. `<CR>` opens the PR in the browser, `y` copies its URL, `c` opens its Files changed, `a` the agent's chat. A plain row after the Task Board with how many it lists; in the Inbox, with how many, while a PR waits on you (open, not a draft, CI green, no changes requested) |

**Pages** are for reading and discussing what a router writes, design docs first. A page holds no
state: comments live beside it, one JSON object a line (`id` c1, c2…, the `quote` of the lines it's
on, their `from`/`to` lines in the file, the `heading` path above them, `text`, `by`, `at`, `status`
open or resolved, `replies`, and once resolved `resolved_by`, `note`). In the page's tab:
- `c` comments on the line under the cursor, `V`/`v` then `c` (or `<CR>`) on the lines selected:
  the input box under the page takes it (its title says which lines, under which heading; `<C-c>`
  cancels), `<CR>` keeps it and sends it to the repo's router as a prompt, `[page comment
  <repo>/<page>#<id>] on "<heading>" lines a-b of <file>`, the quoted lines, your words and how to
  answer.
- An open comment shows where its quote is now, found again by its text after the router rewrites
  the page (the match closest to where it was, then its first line alone, then its heading, else
  the line it was on): a sign beside its lines, and under them a dim line, its first line and how
  many replies. `<CR>` on it opens all of it and its replies (and closes it again), `a` replies
  (sent to the router as `[page reply ...]`), `]c` / `[c` go to the next and previous, `r` shows the
  resolved ones too, dimmed with their note, or hides them. Tables are render-markdown's, as in any
  markdown surface, so a page's lines stay the file's lines.
- Agents answer with `iso <role> page comments <page> [--all]`, `iso <role> page reply <page> <id>
  "..." [--ask]` and `iso <role> page resolve <page> <id> ["what changed"]`: the router changes the
  page wherever a comment asks, then resolves it with a note, and the comment leaves the page. A
  reply with `--ask` asks you something: the page waits on you, in the Inbox, until you reply.

- Rerunning a question reattaches to the same one, and returns its answer if it's already been given.
- A question opens as a tab in the main window like a markdown surface, never as a popup, drawn in the chat's question-box style. `<CR>` on an option or its number picks it; in a
  multi question they tick it (`<Space>` too) and Submit or `s` sends. One that takes your own words
  has the input box under it, whose `<CR>` sends them. The answer goes the way `iso answer`'s does,
  and the buffer shows it, as it does when the question is answered elsewhere; `q` closes it. `n`
  and `N` replace it with the next or previous question waiting on you in the Inbox's order (round
  past the end; one a root is deciding isn't waiting on you). An
  agent's permission request (Allow / Deny) is one of these too.
- PRs appear only when an agent registers them (`iso <role> pr`), in the PRs surface. `<CR>` on a PR
  there (or picking it in `<leader><leader>`) opens its own view (`isovim_pr`, isovim.pr_view), a tab:
  its header (#n and title; state, author, base ← head, the agent that registered it, age,
  mergeable or conflicts), its description drawn as the chat draws an agent's markdown (tables
  too), its checks with their glyph and duration (`<CR>` on a failed one opens `gh run view
  --log-failed` as a tab), its reviews and comments and the inline threads by file:line with their
  replies (resolved ones folded), and its files with their +/- counts (`<CR>` opens that file's
  part of `gh pr diff` as a diff buffer tab, `c` the whole diff). The header is a banner (the state as a
  colored pill, #n and the title bold, a dim line of facts with glyphs); each section is a rounded box
  as wide as the window, its title bold after a glyph and its counts in the top border, a key hint in
  the bottom one; failed checks come first, names aligned and durations in a column; each review,
  comment and thread is a small box of its own, replies on a │ rail; + counts green, − red, a file's
  type glyph beside it; the colors are the chat's palette, set again with the colorscheme or
  background. Each section folds (`za`) to its top line; `o` opens
  it in the browser, `y` copies its URL, `a` opens the registering agent's chat, `r` fetches again.
  It's read-only: approving, merging and commenting are the browser's. gh runs in the background
  (gh pr view, and gh api graphql for the threads), cached under `run/<repo>/pr-<n>.json`; the view
  draws from the cache at once with "refreshing…" in its header, says when gh gave nothing, and
  fetches again on a `pr.<repo>.<n>.ci|review|state` event. The sidebar's
  P toggle, which swapped a repo's agents for its PRs, is gone with the PR rows and their `y`.
- `d` on a surface's row removes it, the user's own action (the router-only rule for `iso/` is
  the agents'): a file or folder surface only points, so its `.surface` goes at once and what it
  names stays (a pinned path likewise unpins); a chat pointer goes at once too. Markdown, a page with
  its comments and an answered question hold content, so they go after a one-key `y` in the command
  line (`Remove page "X" and its 3 comments? y/n`); a question still waiting goes only on a `y` to
  "its asker waits on it", else it stays with that hint. The Task Board and the PRs surface are
  isovim's views: `d` hides them for the repo until they change (a new task, a PR), kept in
  `run/<repo>/hidden.json`. Each publishes `surface.<repo>.<name>.removed`, and its open tab closes.

## The sidebar

```
S (7) - swarming            ← style meter: live agents on this host
‹ macbook ›                 ← the host you're viewing (< >)
Inbox 2                     ← the shown host's: every surface that needs you
├─  app - ? a0 asks: merge? ← its repo's glyph and name, then the surface
└─  isovim - ? mini-animate …
♛ root  ⏺                   ← the host root, with the crown
▾ isovim ●             2    ← repo header in its color; opens the router; at the right, how
                               many of its agents run (the working color while any works)
     Task Board ◐ 2         ← surfaces that need nothing from you, plain, the Task Board first
     the plan                 (read markdown, files, answered questions)
  ▾ Inbox 2                 ← the ones that need you; gone when none does
  ├─ ? merge the fix?
  └─ ✎ review notes
    router · rework vocab
    a3 · tab line fix        (workers; teams behind them are counted, not listed)
▾  general                 ← fa-globe: agents in no repo
▾ 󰆍 terminals 2             ← md-console: this host's terminals; script panes marked with a robot
    zsh
─────────────────────────
cpu 12%  ram 18/24G         ← the footer, the column's only other window; u to measure
Settings
ISOVIM 2de9e2b
```

The column is two windows, the list and the footer. The list starts with the Inbox of the host it
shows, so `<` and `>` switch it with the rest (on another host it says whose, `Inbox 2 ·
cleopatra`); `<leader>ih` brings it back to this host. Terminals is the list's last group, as General
is one: Enter on a terminal opens it, `n` makes one, `r` / `d` / `o` rename, remove and open its
port, and `<leader>iT` lands on it. Each
surface waiting on you is a row of its own, in the order `<leader>in` walks them: its repo's glyph in
its color and short name (root's or general's for theirs), then the surface's mark and title, cut to
the window's width, and a raised question's why, dimmed. Enter opens it as a tab. There is no Inbox of the other hosts: their
surfaces are reached by showing that host.

Every Inbox shows only the surfaces that need you, under dim tree guides (`├─`, `└─` for the last);
the rest of a repo's (or the root's) surfaces list as plain rows under its header, above its agents,
the Task Board first, and a surface moves there from the Inbox once it's dealt with. Each surface
type has its own row format. In root mode, an Inbox
shows a "root mode" marker beside its count; a question its root is deciding says "root deciding",
quietly, and one it raised to you shows its why after "↑".

## The tab bar

A tab is a view of a sidebar entry, as a file's buffer is a view of the file. The tab bar shows what
you opened, under the current scope (a repo, Root, General or Terminals): agents' chats (Enter on a
row, a picker, `<leader>ib` / `<leader>ip`), named with their status mark as in the sidebar (`…`
working, `●` unread, `●!` waiting on you), the router first and then the others by number; then
surfaces, the landing and any files. Closing a tab (`<leader>bd`, `:bd`, its x) hides it as closing a
file's buffer does: an agent keeps running and stays in the sidebar, its chat and queue close, and
opening it again brings the tab back; a surface closes until it's reopened. `<leader>bo` closes every
other tab, `<leader>bD` and `<leader>wd` close the window too while another editing window remains,
and from a queue or input box each acts on its chat or view. Picking a chat's tab (or `<S-h>` /
`<S-l>`, `[b` / `]b`) shows it whole, its input box at its end. A queue whose chat is no longer on
screen closes and stays closed until the chat is shown again; a window a close leaves empty shows
your last tab. The empty buffer nvim starts with goes once nothing shows it.

Nothing opens a split by itself: a surface, a pinned file, a file a chat names (`gf`), Settings, the
changes view's pick, a picker's or the explorer's file opens as a tab in the window you're in (the
main one from the sidebar), replacing what it shows as `:b` does; the chat's input box is its own
buffer's end, so it goes with it. A markdown surface's input box stays under its view, part of its
tab. Splits are yours to make (`:vsplit`, `<C-w>v`); the terminal toggle is the one isovim key that
opens one.

## Images

Images are drawn by Snacks.image (the kitty graphics protocol, as Ghostty, kitty and WezTerm speak
it), which the starter enables. The TUI's code runs in an `nvim --embed` server, but Snacks writes its
escapes through `nvim_ui_send`, which hands them to the TUI client and so to the terminal, and it
finds the terminal by its XTVERSION answer, which the client passes back as a TermResponse; the
server shares the terminal, so the cell size comes from its ioctl. So an image file opened wherever
isovim opens files (isovim.show: `gf` from a chat, a file surface, a pinned path, a pick) is an image
buffer and a tab, the jump's preview of one draws it, and a markdown surface or page draws its images
inline, a relative path resolving against the repo's `iso/` (or `iso/pages/`). isovim.image adds:
`<CR>` on an `[Image #n]` chip in a chat's conversation opens that prompt's image as a tab; a PR's
images (`![…](…)`, `<img>`) show in its view as `image: name · <CR> opens`, fetched under
`run/<repo>/images/` (with gh's token for GitHub's) and opened as a tab, else in the browser; and where
the terminal doesn't answer as one that draws images (`iso attach` over ssh, a plain terminal), an
image buffer is one line saying so instead of Snacks' notes.

## Events

Every change is appended as a JSON line to `~/.isovim/events/events.jsonl`. Topics:

- `agent.<scope>.<id>.status|spawned|exited|promoted`
- `msg.<scope>.<id>`
- `surface.<repo>.<name>.created|changed|removed|answered|consumed`
- `pr.<repo>.<n>.state|ci|review`
- `root.<scope>.raised|decided`
- `bug.<id>.filed|taken|issued`

Segment values encode `%` and `.` as `%25` and `%2E`. `iso <role> listen <pattern>… [--once]`
streams the matching events, with `*` matching one part and `**` any number.

## The bug queue

`iso bug [--image <file>]... <text...|->` files a bug, complaint or request about isovim itself,
from any agent (bare `iso bug` or `iso <role> bug`) or your shell. It writes one report to
`~/.isovim/bugs/queue/<id>.json` (its text, the reporter's address or `user`, its repo, cwd,
time, isovim's sha and the host; images copied to `~/.isovim/bugs/<id>/`), publishes
`bug.<id>.filed`, prints the id and returns. Nothing in it blocks or fails its caller.

- **Pick-up:** every ACP supervisor subscribes to the queue: it watches `queue/`, and a second after
  it changes, or a few seconds after it starts (for what was filed while none ran), claims each
  report by renaming it to `~/.isovim/bugs/<id>.json`. Only one rename wins, so each report is
  taken once, with or without the TUI. The winner runs `iso __bug-take <id>` on the tmux server.
- **The worker:** `__bug-take` spawns a hidden worker in isaacchacko/isovim, `bug-<id>`, whose parent
  is isovim's router on this host, with `prompts/bug.md` filled in as its first message. It gathers
  context (errors.log and the TUI's messages near the report's time, the reporter's recent turns
  about isovim, code pointers), labels it bug, complaint or request, comments on an open duplicate
  or opens an issue with `gh`, records the URL with `iso __bug-done <id> <url>` (`bug.<id>.issued`),
  tells its parent and stops.
- **Privacy:** isaacchacko/isovim is public and reporters often work in private repos, so the
  worker's brief says to write only what's about isovim itself, paraphrasing the rest ("an agent in
  a private repo"). The raw report and its images stay in `~/.isovim/bugs/`.

## The CLI

- `iso <worker|router|repo-root|root> <action>` is for agents, checked against the caller's identity.
- `iso <action>` (bare) is for you, and refuses agents.
- Actions every role needs repeat under each role.
- `iso completion zsh|bash` gives Tab completion at every position, plus the `iso jump` shell function.

**Every role:**
- talking and watching: `msg`, `ls`, `status`, `peek`, `wait`, `find`, `transcript`, `listen`
- tools: `browser`, `pilot` (one holder at a time), `spawn`, `promote`, `restart`, `fork`, `checkhealth`,
  `version`, `update` (pulls isovim's own checkout; run after pushing to isovim's main)

**Router and worker:** `wt`, `setup`, `teardown`, `run <action>`, resolved for the calling agent.

**Router only:** `surface question|file|folder|chat`, `pr`.

**Router, repo-root and root:** `rm <agent> [--keep-branch] [--force]`.

**Roots:** `answer`, `raise`.

**Yours:** `iso` opens the TUI. The bare commands are:
- `spawn` (no parent), `jump` (fzf drill-down with `.` and `..`)
- `attach`, `phone`, `handover`
- `move`, `rm`, `restart`, `rename`, `rootmode`, `answer`
- `listen`, `verify`, `checkhealth`

**Anyone** (you or an agent, bare or under a role): `bug`.

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
- **A router owns its workers' life, as CRUD.** Create: `iso router spawn` (hidden until `H`). Read:
  `ls`, `status`, `peek`, `wait`, `transcript`. Update: `msg`, `restart`. Delete: `iso router rm
  <agent>` once a worker's work has landed and nothing more is expected of it, unless the router keeps
  it as the standing owner of an area it keeps sending follow-ups to, which its Task Board line says.
  Cleaning up finished workers is the router's job, not the reaper's.
- **`iso <role> rm <agent> [--keep-branch] [--force]`** is a router's, repo-root's or root's, on the
  agents it may restart: its own descendants; for a router or repo-root any agent in its repo; for the
  root any on the host. It refuses an agent mid-turn or with a question or permission waiting in the
  Inbox, and a worktree with uncommitted files or commits no origin branch has (it lists them) unless
  `--force`, which drops the uncommitted files and keeps unpushed commits on the local branch. The
  removal is `iso rm`'s, `d` in the sidebar: the supervisor stops, the record and `aN/` go (teardown,
  below), and the children go to its parent. The journal and the transcript stay in `iso/`, the
  transcript headed `# <name> (removed <date> by <who>)`, so `iso find` and grep still find the agent.
  Pushed branches and PRs are left alone; the local branch is deleted once origin has all of it,
  unless `--keep-branch`.
- **Teardown:** when an agent is removed, isovim runs the repo's teardown and deletes `aN/`. Unsaved
  work is discarded.
- **The reaper** runs every 10 minutes and tears down any `aN/` with no record. It runs as a dry run,
  logging only, until v0 is cut over.

## Keys

Plain nvim keys keep their meaning: windows, buffers, hunks, lazygit. File keys translate to repos
and agents, and everything isovim-specific lives under `<leader>i`.

**Global**
- `<leader><leader>` jumps to anything the sidebar shows, each drawn as its row on the left (the
  Inbox's items first, then what you opened last) with a preview on the right: an agent's status
  and its chat's end (its chat buffer if loaded, else its transcript or its journal's last 64 KB), a
  surface as it opens, a file or folder, a repo's or Terminals' rows, a terminal's pane; all local,
  nothing waiting on the network or an agent, opening it as `<CR>` on its row would and moving the sidebar's
  cursor there; `H` in the picker (`<M-h>` while typing) toggles hidden agents in. `<leader>iP` picks a repo; `<leader>ff` finds a file in it; `<leader>/` greps it, transcripts
  included.
- `<leader>,` shows the repo's buffers; `<leader>fr` shows recent agents (`<leader>fR` recent files).
- `<leader>e` opens or closes the sidebar.

**`<leader>i`**

| key | does |
|---|---|
| `n` | the next thing that needs you |
| `i` / `h` | the repo / host Inbox (the host's is at the top of the list) |
| `r` | the router |
| `R` | the nearest root |
| `H` | the host root |
| `w` / `a` | pick a worker / pick any agent |
| `b` | the previous agent |
| `p` | the previous repo, at the agent last open there |
| `P` | pick a repo (Root, General and Terminals among them) |
| `o` | the current repo's PRs surface |
| `g` / `T` | general / terminals |
| `s` / `t` / `N` | spawn / new thread / new terminal |
| `x` | root mode for this repo |
| `j` | jump |
| `<` / `>` | switch host |
| `q` | the prompt queue (opened even when empty, to add a line) |
| `u` / `f` | rewind / fork at the cursor |
| `l` | the landing |
| `U` / `!` | check for an isovim update now / restart isovim now |

**The landing**
- On start, when there is nothing to resume, the editing area shows the landing (`isovim.landing`):
  what isovim is, the Inbox count, the repos in `~/.isovim/repos`, the keys that matter (their words
  read from the key tables, as `?` does) and quick actions on single keys: `s` spawn in a repo picked,
  `p` anything in the sidebar (as `<leader><leader>`), `j` jump to a dir, `i` the host's Inbox, `n` a terminal, `m` send a repo to a host, `?` help.
  `<leader>il` brings it back. It belongs to no workspace, so no layout keeps it.

**In the chat** (the conversation and, at its end, the input box: one buffer)
- `]]` / `[[` jump between your prompts; `]m` / `[m` between any messages.
- `za` folds; `<C-o>` opens every tool call's output and thought while any is collapsed, else
  collapses them all, and the ones that come after follow it until `<C-o>` again (`za` still
  folds one); `<C-c>` cancels; `gf` opens a file; `u` / `<C-r>` undo and redo in the input box.
- On the conversation, `i` `a` `o` `O` `I` `A` `c` `s` `C` `S` `R` and `<CR>` go to the end of
  your draft, typing (`<CR>` on a box's option answers with it); `<C-j>` goes down to the input box.

**In the queue**
- Edit lines and `:w`; `<CR>` sends the prompt on the line now; `q` hides it.
- `<C-k>` goes up to the input box.

**In the input box**
- `<CR>` sends; `<S-CR>` (or `<M-CR>`, for a terminal that can't send `<S-CR>`) adds a newline;
  `<Up>` / `<Down>` browse history when it's empty.
- `<C-v>` pastes the clipboard's image (vim's own `<C-v>` when there's none).
- `<Esc>` drops to normal mode; `<C-k>` goes up to the conversation's end and `<C-j>` down to the
  queue while it shows, in either mode.

**Into the sidebar and back**
- `<C-h>` goes to the sidebar from anything in the main column (a chat and its input box, the queue,
  a surface or question and its input box), in insert mode too: in an input box it takes the place of vim's backspace,
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
| `<C-l>` | back to the window you came from |
| `s` / `t` / `n` | spawn / new thread (on a repo's or agent's row) / new terminal |
| `r` / `d` / `R` / `m` | rename / remove / restart / move |
| `x` | root mode |
| `o` / `c` | open the port / changes |
| `u` | measure CPU/RAM |
| `H` / `L` | toggles |
| `P` | the row's repo's PRs surface (the root's on its rows; on General or Terminals, the current repo's); one with none registered says so |
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
  code: an open chat's keys, autocmds, guard and journal follower are bound again (its follower
  going on from where the old one got to), and nothing is redrawn unless the chat's drawing changed
  (`acp/chat.lua` or `acp/look.lua`). Then each chat is drawn again from its journal into a buffer
  of its own, a few milliseconds a turn (those on screen first) while the old one goes on as it was,
  and once done its conversation takes the old one's place above your draft, keeping each window's
  scroll, your draft, its undo and your cursor in it, the tool calls and thoughts you opened or
  collapsed and a rewind you're editing. A reload doesn't hold up your keys either way. A chat from
  before its input box joined its buffer is made again at once, giving that box's text and images
  to the one buffer. Surface views and the sidebar re-bind their keys and redraw; timers call
  through `require`, and the ones that hold a closure (the migrate timer, the chat's spinner) are
  replaced. `starter/lua/config/keymaps.lua` runs again.
- **Needs a restart:** the rest of `starter/` (the plugin specs, `config/lazy.lua`), which lazy.nvim
  reads once at startup; `bin/iso` restores the plugins as it starts when `lazy-lock.json` changed.
  The toast says so,
  or, when a self-update brought it, that isovim restarts onto it by itself; `<leader>i!` restarts
  now.
- **Agents restart themselves:** the agents' supervisors (`nvim -l agent_host.lua`: `acp/host.lua`,
  `acp/client.lua`, `acp/adapter.lua` and the rest they load) keep the code they started with until
  they restart, which each does by itself at its next idle moment (see Agents run over ACP, Resume);
  `R` in the sidebar restarts one at once. The toast names such files.

A chat made again draws its journal as one batch: windows that followed the end go to it once,
after, rather than being measured after every entry (a 7.5k-entry chat took 9s, the TUI frozen
meanwhile; now about 2). Nothing that runs on its own (timers, scheduled callbacks,
autocmds, the supervisors' pushes) raises into nvim's messages, where an error's hit-enter prompt
held the whole TUI: `isovim.safe` catches it and toasts it at WARN with its stack, at most once a
minute for each place, and the TUI carries on. nvim runs other events in the middle of a reload (a
long `nvim_win_text_height` handles what's waiting), when modules are half loaded and a chat half
made, so timers and the supervisors' pushes skip their turn while one is under way; the journal
brings what was pushed. isovim also sets `messagesopt=wait:0` and `nomore`, so a message that does reach the command
line never waits on a key. The TUI's nvim server ends itself once its TUI process is gone, even
while it waits on a key (`isovim.orphan`, a libuv timer), and names itself in
`~/.isovim/isovim.server`, so `bin/iso` kills one left behind before it starts a TUI; the TUI binds
its socket again whenever the path is missing.

Events are taken together (200ms after the last, and not while git holds its index lock), so a save
or a `git pull` of many files is one reload. Changed files are compiled first: one that doesn't, or
a module that fails as it loads, keeps the old code, and the toast gives the error. The toast names
the changed files (or how many, past four). A TUI that started on a `reload.lua` from before this
needs one restart to get it.

## Self-update

isovim keeps the checkout it runs from up to date itself (`isovim.update`), so nobody has to quit,
pull and start it again. The edit guard still refuses agents' writes and git commands there: the
pull is the TUI's own, or `iso update`'s, one isovim command, not an agent's git.
- **When it looks:** the TUI fetches origin's default branch (`origin/HEAD`, else `main`) 5s after it
  starts and every minute after, in the background with a 30s timeout and no prompts. `iso update`
  (`iso <role> update`, any role, and the prompt every agent gets says to run it after pushing to
  isovim's main) makes the same pull itself, TUI open or not, prints what happened (it fails when it
  can't pull), and then hands an update to an open TUI over its socket, which says so and hot
  reloads or arms its restart as for its own. `bin/iso-hook` runs it after any agent's Bash call
  that pushes (`git ... push`), so a push to main lands within seconds.
  `<leader>iU` looks now and says what it found. An offline fetch is quiet.
- **When it pulls:** a fast-forward (`git merge --ff-only`), only when the checkout is on the
  default branch, no tracked file has changes (untracked ones, `.claude/` and `.vibe-wise/`, are
  fine) and it is behind origin, not diverged. Otherwise it does nothing and says why once (local
  changes, naming the files; another branch or a detached HEAD; diverged; a fast-forward git
  refused) in a toast, again only when the reason changes, and the sidebar's footer shows
  `not updating: <why>` until it can pull again (`Enter` on it checks now). It never stashes, resets
  or rebases.
- **Nothing of isovim's own dirties the checkout:** lazy.nvim's lockfile and LazyVim's extras
  (`vim.g.lazyvim_json`) are the host's, `~/.isovim/lazy-lock.json` and `~/.isovim/lazyvim.json`, so
  `:Lazy update`, a pin or `:LazyExtras` write there. `bin/iso` seeds the lockfile from
  `starter/lazy-lock.json` and, when that changes, replaces it and restores the plugins (it keeps
  the copy it seeded from, `lazy-lock.seeded.json`, to tell). The extras start as
  `starter/lazyvim.json`'s; when that changes, the extras it added or dropped since
  (`lazyvim.seeded.json`) are added to or dropped from the host's, and the ones you toggled stay.
- **What then:** `lua/isovim/` hot reloads through the watcher, as for any pull (`reload.lua`
  included). `starter/` (but `config/keymaps.lua`) and `bin/iso` are read only at startup, so they
  restart the TUI; `bin/iso-hook` and `bin/iso-browser.mjs` run fresh each call and need nothing.
- **The restart:** it waits until you've pressed no key for 20s, are in normal mode, and no picker
  or float has focus, and no file buffer has unsaved changes (it says once that it waits on one).
  Then `isovim updated: restarting in 5s · any key to wait`; any key postpones it until you're idle
  again. It writes `~/.isovim/restart.json` (every open chat, most recent first, the current
  workspace, the scope, each composer's draft; the current workspace's splits are already in its
  `layout.json`) and exits with code 75. `bin/iso` runs nvim in a loop: on 75 it runs itself
  again, the updated `bin/iso`, with no arguments, which restores the plugins first if
  `starter/lazy-lock.json` changed. The new TUI reopens the chats of agents still running, the current
  workspace's layout, the scope and the drafts, and deletes the file. Agents live in tmux and their
  supervisors, so they never notice. The TUI names itself in `isovim.lock` (`bin/iso` names itself
  until then), so `iso --takeover` still stops the TUI, and the loop with it.
- A TUI started by a `bin/iso` from before the loop (no `ISOVIM_LOOP`) still pulls and hot reloads,
  but says to quit and run `iso` instead of restarting. `ISOVIM_SELF_UPDATE=0` turns it off; pilots
  do, but for `pilot/checks/self_update.py`.

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
