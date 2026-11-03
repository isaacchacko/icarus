-- isovim's keys anywhere: the global ones LazyVim had (<leader><leader>, <leader>ff, <leader>/, ...)
-- turned to repos and agents, and the <leader>i group. Agents are found by scope (isovim.scope:
-- a repo, Root, General, Terminals) and by role. The <leader>a keys from before still work for now,
-- each saying once which key replaced it. The chat's and the composer's keys are the chat's own.
local store = require("isovim.store")
local scope = require("isovim.scope")
local status = require("isovim.status")
local icons = require("isovim.icons")
local repos = require("isovim.repos")

local M = {}

local function isovim()
  return require("isovim")
end

local function sidebar()
  return require("isovim.sidebar")
end

local function toast(message, level)
  Snacks.notify(message, { title = "isovim", level = level })
end

local hinted = {} ---@type table<string, true>

-- The first press of a retiring key in a session names the key that replaced it.
function M.hint(old, new)
  if not hinted[old] then
    hinted[old] = true
    toast(("%s is retiring: %s"):format(old, new))
  end
end

-- Every agent on this host but terminals and script panes, as pickers list them; hidden ones only
-- while H shows them.
---@return {ws: string, ws_name: string, agent: string, name: string, kind: string, role: string, scope: string}[]
function M.agents()
  local list = {}
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      if not scope.is_terminal(agent) and (not agent.hidden or isovim().show_hidden) then
        list[#list + 1] = {
          ws = ws.id,
          ws_name = ws.name,
          agent = agent.id,
          name = agent.name,
          kind = agent.kind,
          -- The root `iso root` named has the role in all but its record.
          role = scope.is_root(ws.id, agent) and "root" or store.role(agent),
          scope = scope.of_agent(ws.id, agent.id),
        }
      end
    end
  end
  return list
end

-- Most recently opened first (isovim.recent_agents), then by when each last changed state.
local function by_recency(list)
  local rank = {}
  for i, key in ipairs(isovim().recent_agents) do
    rank[key] = i
  end
  for _, entry in ipairs(list) do
    entry.rank = rank[entry.ws .. "/" .. entry.agent] or math.huge
    entry.changed = vim.fn.getftime(store.state_file(entry.ws, entry.agent))
  end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return a.changed > b.changed
  end)
  return list
end

---@param want fun(entry): boolean
local function find(want)
  return vim.tbl_filter(want, by_recency(M.agents()))
end

local function open(entry)
  isovim().open(entry.ws, entry.agent)
end

-- The agent the focused window shows, as "<ws>/<agent>".
local function shown()
  local buf = vim.api.nvim_get_current_buf()
  return vim.b[buf].isovim_id and (vim.b[buf].isovim_id .. "/" .. (vim.b[buf].isovim_agent or "main")) or nil
end

local function current_scope()
  return isovim().current_scope or scope.GENERAL
end

local function pick_agents(title, list)
  if #list == 0 then
    return toast("No agents for " .. title)
  end
  Snacks.picker.pick({
    source = "isovim_agents",
    title = title,
    layout = { preset = "select" },
    items = vim.tbl_map(function(entry)
      return vim.tbl_extend("force", entry, { text = ("%s %s %s %s"):format(entry.ws_name, entry.name, entry.role, scope.label(entry.scope)) })
    end, list),
    format = function(item)
      local icon, hl = status.icon(status.get(item.ws, item.agent))
      local kind_icon, kind_hl = icons.agent(item)
      local line = { { icon, hl }, { " " }, { kind_icon, kind_hl }, { " " }, { item.ws_name .. " · " .. item.name } }
      if item.role ~= "worker" then
        line[#line + 1] = { " " .. item.role, "Special" }
      end
      line[#line + 1] = { "  " .. scope.label(item.scope), "Comment" }
      return line
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        open(item)
      end
    end,
  })
end

-- The host's root.
local function host_root()
  return find(function(entry)
    return entry.role == "root"
  end)[1]
end

-- The current repo's agent with the role.
local function in_repo(role)
  local here = current_scope()
  return find(function(entry)
    return entry.role == role and entry.scope == here
  end)[1]
end

-- Opens the scope: the root for Root, the sidebar's Terminals for Terminals, else the scope's agent
-- opened last (or its workspace changed last); General with nothing in it just becomes current.
function M.select_scope(name)
  if name == scope.TERMINALS then
    isovim().set_scope(name)
    return sidebar().focus_window("terminals")
  elseif name == scope.ROOT then
    local root = host_root()
    return root and open(root) or toast("No root on this host")
  end
  local agent = find(function(entry)
    return entry.scope == name
  end)[1]
  if agent then
    return open(agent)
  end
  isovim().set_scope(name)
  toast(("Nothing in %s yet"):format(scope.label(name)))
end

-- The repos with agents here, the one used last first, between the pseudo-repos: Root (when there
-- is one) pinned first, then General and Terminals.
function M.scopes()
  local seen, list = {}, {}
  local root = host_root()
  if root then
    list[1] = scope.ROOT
  end
  seen[scope.ROOT], seen[scope.GENERAL], seen[scope.TERMINALS] = true, true, true
  for _, entry in ipairs(by_recency(M.agents())) do
    if not seen[entry.scope] then
      seen[entry.scope] = true
      list[#list + 1] = entry.scope
    end
  end
  return vim.list_extend(list, { scope.GENERAL, scope.TERMINALS })
end

local PSEUDO_ICONS = { root = "root", general = "general", terminals = "terminals" }

function M.pick_repo()
  local counts = {}
  for _, entry in ipairs(M.agents()) do
    counts[entry.scope] = (counts[entry.scope] or 0) + 1
  end
  Snacks.picker.pick({
    source = "isovim_repos",
    title = "Projects",
    layout = { preset = "select" },
    items = vim.tbl_map(function(name)
      return { name = name, text = scope.label(name), count = counts[name] }
    end, M.scopes()),
    format = function(item)
      local icon, hl = icons.get(PSEUDO_ICONS[item.name])
      if not PSEUDO_ICONS[item.name] then
        local style = repos.style(item.name)
        icon, hl = style.glyph, repos.highlight(style.color)
      end
      local line = { { icon, hl }, { " " }, { item.text, item.name == current_scope() and "Title" or nil } }
      if item.count then
        line[#line + 1] = { ("  %d agent%s"):format(item.count, item.count == 1 and "" or "s"), "Comment" }
      end
      return line
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.select_scope(item.name)
      end
    end,
  })
end

-- Where the current repo's files are: the focused agent's work dir (a new-layout agent's worktree),
-- else the current workspace's dir, a new-layout repo's base clone, or ~ outside every repo.
function M.repo_dir()
  local buf = vim.api.nvim_get_current_buf()
  local ws, agent = vim.b[buf].isovim_id, vim.b[buf].isovim_agent
  if ws and agent and store.v2(ws) and scope.of_workspace(ws) == current_scope() then
    return store.work_dir(ws, agent)
  end
  ws = isovim().current
  if not ws or scope.of_workspace(ws) ~= current_scope() then
    local recent = find(function(entry)
      return entry.scope == current_scope()
    end)[1]
    ws = recent and recent.ws
  end
  if not ws or current_scope() == scope.TERMINALS then
    return vim.fs.normalize("~")
  elseif store.v2(ws) and not store.is_pseudo(ws) then
    local base = repos.dir(ws) .. "/base-clone"
    return vim.fn.isdirectory(base) == 1 and base or store.dir(ws)
  end
  return store.dir(ws)
end

-- The transcripts of the current scope's agents: a workspace's transcripts/, a new-layout repo's
-- iso/transcripts/; those already under dir aren't listed twice.
function M.transcript_dirs(dir)
  local dirs, seen = {}, {}
  for _, entry in ipairs(M.agents()) do
    local path = store.path(entry.ws) .. "/transcripts"
    if entry.scope == current_scope() and not seen[path] and vim.fn.isdirectory(path) == 1 and not vim.startswith(path, dir .. "/") then
      seen[path] = true
      dirs[#dirs + 1] = path
    end
  end
  return dirs
end

function M.find_files()
  Snacks.picker.files({ cwd = M.repo_dir(), title = "Files · " .. scope.label(current_scope()) })
end

function M.grep()
  local dir = M.repo_dir()
  Snacks.picker.grep({ cwd = dir, dirs = vim.list_extend({ dir }, M.transcript_dirs(dir)), title = "Grep · " .. scope.label(current_scope()) })
end

-- The listed buffers are the current scope's (isovim.scope).
function M.buffers()
  Snacks.picker.buffers({ title = "Buffers · " .. scope.label(current_scope()) })
end

function M.recent_agents()
  local here = shown()
  pick_agents("Recent agents", find(function(entry)
    return entry.ws .. "/" .. entry.agent ~= here
  end))
end

function M.any_agent()
  pick_agents("Agents", M.agents())
end

function M.workers()
  local here = current_scope()
  pick_agents("Workers · " .. scope.label(here), find(function(entry)
    return entry.scope == here and entry.role == "worker"
  end))
end

-- The agent opened before the one on screen; again flips back, like vim's <C-^>.
function M.previous_agent()
  local here = shown()
  for _, key in ipairs(isovim().recent_agents) do
    local ws, agent = key:match("^(.+)/([^/]+)$")
    if key ~= here and ws and store.agent(ws, agent) then
      return isovim().open(ws, agent)
    end
  end
  toast("No other agent yet")
end

-- The repo (or Root, General, Terminals) you were in before this one, at the agent you last had open
-- there; again flips back. A repo whose agents are all gone is skipped.
function M.previous_repo()
  local here = current_scope()
  local scopes = {}
  for _, entry in ipairs(M.agents()) do
    scopes[entry.scope] = true
  end
  for _, name in ipairs(isovim().recent_scopes) do
    if name ~= here and (scopes[name] or name == scope.GENERAL or name == scope.TERMINALS) then
      return M.select_scope(name)
    end
  end
  toast("No other project yet")
end

-- What the jump offers: the rows that stand for something (agents, surfaces, the Inbox's items,
-- repos and the pseudo-repos, terminals, pinned paths), not titles or hints. A surface in a repo's
-- Inbox is the host Inbox's item already.
local function jumpable(row)
  local kinds = { waiting = true, agent = true, surface = true, repo = true, terminals = true, terminal = true, path = true, pr = true }
  return kinds[row.kind] and not row.in_inbox
end

-- A row's chunks for the picker: its indent and tree guide dropped, a right-aligned mark after it,
-- and the repo of a row whose repo its header gave.
local function jump_chunks(row)
  local chunks = {}
  for _, chunk in ipairs(require("isovim.sidebar").row_chunks(row)) do
    if #chunks > 0 or not chunk[1]:match("^[%s├└─│▾▸]*$") then
      chunks[#chunks + 1] = chunk.right and { " " .. chunk[1], chunk[2] } or { chunk[1], chunk[2] }
    end
  end
  local key = row.kind ~= "waiting" and row.kind ~= "repo" and (row.group_key or row.repo_key)
  if key then
    chunks[#chunks + 1] = { "  " .. scope.label(key), "Comment" }
  elseif row.kind == "terminal" then
    chunks[#chunks + 1] = { "  Terminals", "Comment" }
  end
  return chunks
end

-- The jump's items: the Inbox's first, in its order; then agents and terminals, the one opened last
-- first (as by_recency); then the rest in the list's order.
local function jump_items(hidden)
  local rank = {}
  for i, key in ipairs(isovim().recent_agents) do
    rank[key] = i
  end
  local items = {}
  local rows = require("isovim.sidebar").all_rows(hidden)
  -- And every PR registered here, each opening its own view, after the list's rows.
  local surfaces = require("isovim.surfaces")
  for _, key in ipairs(surfaces.repos()) do
    local board = surfaces.prs_entry(key)
    for _, group in ipairs({ "open", "draft", "merged", "closed" }) do
      for _, pr in ipairs(board and board.groups[group] or {}) do
        rows[#rows + 1] = { kind = "pr", repo_key = key, group_key = key, pr = pr, url = pr.url }
      end
    end
  end
  for i, row in ipairs(rows) do
    if jumpable(row) then
      local chunks = jump_chunks(row)
      local order = { 2, 0, i }
      if row.kind == "waiting" then
        order = { 0, 0, i }
      elseif (row.kind == "agent" or row.kind == "terminal") and not row.host then
        order = { 1, rank[row.ws .. "/" .. row.agent] or math.huge, -vim.fn.getftime(store.state_file(row.ws, row.agent)) }
      end
      items[#items + 1] = vim.tbl_extend("force", row, {
        row = row,
        chunks = chunks,
        order = order,
        text = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks)),
      })
    end
  end
  table.sort(items, function(a, b)
    for i = 1, 3 do
      if a.order[i] ~= b.order[i] then
        return a.order[i] < b.order[i]
      end
    end
    return false
  end)
  return items, rows
end

local PREVIEW_LINES = 40

-- An ACP agent's last words from its journal's end (its last 64 KB, read once): your prompts, its
-- messages and its tool calls, plainly, as a chat not yet drawn would show them.
local function journal_tail(ws, agent)
  local path = require("isovim.acp.journal").path(ws, agent)
  local stat = vim.uv.fs_stat(path)
  local fd = stat and vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end
  local size = 65536
  local data = vim.uv.fs_read(fd, size, math.max(0, stat.size - size)) or ""
  vim.uv.fs_close(fd)
  local lines, message = {}, nil
  local function flush()
    if message then
      vim.list_extend(lines, vim.split(vim.trim(message), "\n"))
      message = nil
    end
  end
  for _, line in ipairs(vim.split(data, "\n", { trimempty = true })) do
    local ok, entry = pcall(vim.json.decode, line)
    local update = ok and type(entry) == "table" and entry.update or nil
    if ok and type(entry) == "table" and entry.kind == "prompt" then
      flush()
      vim.list_extend(lines, { "", "❯ " .. tostring(entry.text or entry.message or ""):gsub("\n", " "), "" })
    elseif type(update) == "table" and update.sessionUpdate == "agent_message_chunk" and type(update.content) == "table" then
      message = (message or "") .. tostring(update.content.text or "")
    elseif type(update) == "table" and update.sessionUpdate == "tool_call" then
      flush()
      lines[#lines + 1] = "⏺ " .. tostring(update.name or update.title or "tool")
    end
  end
  flush()
  return #lines > 0 and vim.list_slice(lines, math.max(1, #lines - PREVIEW_LINES + 1)) or nil
end

-- The end of an agent's chat: its chat buffer's last lines while it's loaded (as the chat draws
-- them), else its transcript's; nil when it has neither yet.
local function chat_tail(ws, agent)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent and vim.api.nvim_buf_is_loaded(buf) then
      local count = vim.api.nvim_buf_line_count(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, count - PREVIEW_LINES), count, false)
      while #lines > 0 and vim.trim(lines[#lines]) == "" do
        table.remove(lines)
      end
      if #lines > 0 then
        return lines
      end
    end
  end
  local path = require("isovim.transcript").path(ws, agent)
  if vim.uv.fs_stat(path) then
    return vim.fn.readfile(path, "", -PREVIEW_LINES)
  end
  return journal_tail(ws, agent)
end

-- A surface as its view shows it: a question with its options, the Task Board, the PRs surface or
-- markdown rendered; a file or folder is previewed as one (file set).
---@return string[] lines, string? ft, string? file
local function surface_preview(entry)
  if entry.type == "question" then
    local lines = { "# " .. (entry.question or entry.title or entry.name), "" }
    for i, option in ipairs(entry.options or {}) do
      lines[#lines + 1] = ("%d. **%s**%s"):format(i, option.label or "?", option.description and (": " .. option.description) or "")
    end
    if entry.answer then
      vim.list_extend(lines, { "", "answered: " .. vim.inspect(entry.answer) })
    end
    return lines, "markdown"
  elseif entry.type == "file" or entry.type == "folder" then
    local path = entry.path or ""
    if vim.fn.isdirectory(path) == 1 then
      return vim.fn.readdir(path), nil
    end
    return { path }, nil, vim.uv.fs_stat(path) and path or nil
  elseif entry.type == "markdown" or entry.type == "tasks" or entry.type == "prs" or entry.type == "decisions" or entry.type == "page" then
    return (require("isovim.surface_view").render(entry)), "markdown"
  end
  return { (entry.title or entry.name or "?") .. " (" .. tostring(entry.type) .. ")" }
end

-- What the jump previews for a row: an agent's chat's end under its status, a surface as it opens,
-- a group's rows as the sidebar lists them, a terminal's pane's last lines. All local and quick:
-- nothing waits on the network or an agent; anything else is a line about it.
---@return string[] lines, string? ft, string? file
local function jump_preview(item, rows)
  local row = item.row
  if row.kind == "agent" and not row.host then
    local head = ("%s · %s · %s"):format(row.name or row.agent, status.get(row.ws, row.agent) or "idle", row.role or "worker")
    return vim.list_extend({ head, "" }, chat_tail(row.ws, row.agent) or { "(nothing said yet)" })
  elseif row.kind == "terminal" and not row.host then
    local ok, text = pcall(require("isovim.panes").capture, row.ws, row.agent, PREVIEW_LINES)
    return ok and vim.split(vim.trim(text), "\n") or { row.name }
  elseif (row.kind == "surface" or row.kind == "waiting") and row.surface and not row.host then
    return surface_preview(row.surface)
  elseif row.kind == "repo" or row.kind == "terminals" then
    local lines = {}
    for _, other in ipairs(rows) do
      local mine = row.kind == "terminals" and other.kind == "terminal"
        or row.kind == "repo" and (other.group_key == row.repo_key or (other.repo_key == row.repo_key and other.kind ~= "repo"))
      if mine and jumpable(other) then
        lines[#lines + 1] = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, jump_chunks(other)))
      end
    end
    return #lines > 0 and lines or { "(nothing here)" }
  end
  return { item.text }
end

-- <leader><leader>: a jump to any entry the sidebar shows, each as its row on the left, a preview of
-- it on the right; picking opens it in the main area as <CR> on its row would, and the sidebar's
-- cursor goes to it. Hidden agents only after H (in the list, or the input in normal mode; <M-h>
-- while typing), which toggles them.
function M.jump()
  local state = { hidden = isovim().show_hidden, rows = {} }
  Snacks.picker.pick({
    source = "isovim_jump",
    title = "Jump",
    layout = { preset = "default" },
    finder = function()
      local items
      items, state.rows = jump_items(state.hidden)
      return items
    end,
    format = function(item)
      return item.chunks
    end,
    preview = function(ctx)
      local ok, lines, ft, file = pcall(jump_preview, ctx.item, state.rows)
      if ok and file then
        ctx.item.file = file
        return Snacks.picker.preview.file(ctx)
      end
      ctx.preview:reset()
      ctx.preview:set_lines(ok and lines or { ctx.item.text })
      if ok and ft then
        ctx.preview:highlight({ ft = ft })
      end
    end,
    actions = {
      isovim_toggle_hidden = function(picker)
        state.hidden = not state.hidden
        toast(state.hidden and "Hidden agents shown" or "Hidden agents left out")
        picker:find()
      end,
    },
    win = {
      input = { keys = { ["H"] = { "isovim_toggle_hidden", mode = { "n" } }, ["<M-h>"] = { "isovim_toggle_hidden", mode = { "i", "n" } } } },
      list = { keys = { ["H"] = "isovim_toggle_hidden" } },
    },
    confirm = function(picker, item)
      picker:close()
      if item then
        require("isovim.sidebar").open_row(item.row)
      end
    end,
  })
end

-- A repo's PRs surface (the current scope's when key is nil: the root's in Root, the workspace's repo
-- in Terminals), opened as a tab; one with none registered says so.
---@param key? string a repo key, or "root"
function M.prs(key)
  if not key then
    local here = current_scope()
    key = here == scope.TERMINALS and isovim().current and require("isovim.sidebar").group_key(isovim().current) or here
  end
  local surfaces = require("isovim.surfaces")
  surfaces.open(surfaces.prs_entry(key, true))
end

-- The prompt queue of the ACP agent whose chat you're in, else the one on screen: its window under
-- the chat, opened even when nothing waits.
function M.prompt_queue()
  local chat_mod = require("isovim.acp.chat")
  local chat = chat_mod.of_buf()
  if not chat then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      chat = chat or chat_mod.of_buf(vim.api.nvim_win_get_buf(win))
    end
  end
  if not chat then
    return toast("The prompt queue: open an ACP agent's chat first")
  end
  require("isovim.acp.queue").focus(chat.ws, chat.agent)
end

local function open_role(role, missing)
  return function()
    local agent = in_repo(role)
    if agent then
      return open(agent)
    end
    toast(("No %s in %s"):format(missing, scope.label(current_scope())))
  end
end

-- The repo's repo-root, else the host's root.
function M.nearest_root()
  local agent = in_repo("repo-root") or host_root()
  return agent and open(agent) or toast("No root on this host")
end

function M.open_host_root()
  local root = host_root()
  return root and open(root) or toast("No root on this host")
end

-- The current repo's Inbox (repo) or this host's (host, at the top of the sidebar's list), opened, the
-- cursor on its first surface waiting on you.
local function inbox(which)
  return function()
    sidebar().focus_inbox(which)
  end
end

-- Spawns a worker in the current repo, as s does on a repo in the sidebar: General's when that's
-- current, even with nothing in it; in Terminals a terminal, as a worker there means nothing. In
-- Root (nothing spawns there) or the workspace's own repo, the workspace's, which knows a legacy
-- one's clone.
function M.spawn()
  local here, ws = current_scope(), isovim().current
  if here == scope.TERMINALS then
    return M.new_terminal()
  elseif here == scope.ROOT or (ws and scope.of_workspace(ws) == here) then
    return sidebar().spawn(ws)
  end
  sidebar().spawn({ repo_key = here })
end

function M.new_terminal()
  local ws = isovim().current
  if not ws then
    return toast("No workspace selected", "warn")
  end
  sidebar().actions.isovim_terminal({ ws = ws })
end

-- {lhs, fn, description}, all in normal mode; `?` in the sidebar lists them.
M.GLOBAL = {
  { "<leader><leader>", M.jump, "jump to anything the sidebar shows (H: hidden agents too)" },
  { "<leader>ff", M.find_files, "find a file in the project" },
  { "<leader>/", M.grep, "grep the project and its agents' transcripts" },
  { "<leader>,", M.buffers, "the project's buffers" },
  { "<leader>fr", M.recent_agents, "recent agents" },
  { "<leader>fR", function()
    Snacks.picker.recent()
  end, "recent files" },
}

M.GROUP = {
  { "n", function()
    isovim().next_needs_you()
  end, "next agent that needs you" },
  { "i", inbox("repo"), "the project's Inbox" },
  { "h", inbox("host"), "the host's Inbox" },
  { "r", open_role("router", "router"), "the project's router" },
  { "R", M.nearest_root, "the nearest root (repo-root, else host root)" },
  { "H", M.open_host_root, "the host root" },
  { "w", M.workers, "a worker in the project" },
  { "a", M.any_agent, "any agent" },
  { "b", M.previous_agent, "the previous agent" },
  { "P", M.pick_repo, "pick a project (or Root)" },
  { "o", function()
    M.prs()
  end, "the project's PRs surface" },
  { "p", M.previous_repo, "the previous project (at the agent you last had open there)" },
  { "g", function()
    M.select_scope(scope.GENERAL)
  end, "General (agents in no repo)" },
  { "T", function()
    sidebar().focus_window("terminals")
  end, "Terminals in the sidebar" },
  { "s", M.spawn, "spawn a worker over ACP in the project" },
  { "t", function()
    local scope = require("isovim.scope")
    local current = isovim().current_scope
    require("isovim.acp.chat").new_thread(current ~= scope.GENERAL and current ~= scope.ROOT and current ~= scope.TERMINALS and current or nil)
  end, "a new thread with the project's router" },
  { "N", M.new_terminal, "new terminal" },
  { "<lt>", function()
    sidebar().step_host(-1)
  end, "the previous host" },
  { "[", function()
    sidebar().step_project(-1)
  end, "the previous project in the sidebar" },
  { "]", function()
    sidebar().step_project(1)
  end, "the next project in the sidebar" },
  { ">", function()
    sidebar().step_host(1)
  end, "the next host" },
  { "x", function()
    sidebar().toggle_root_mode()
  end, "root mode on or off for the project in focus (in Root or General: the host)" },
  { "j", function()
    require("isovim.jump").picker()
  end, "jump: a dir isovim keeps, one level at a time" },
  { "q", M.prompt_queue, "the prompt queue of the agent on screen" },
  { "u", function()
    require("isovim.acp.chat").rewind_at_cursor()
  end, "rewind: edit your prompt under the cursor and go on from before it" },
  { "f", function()
    require("isovim.acp.chat").fork_at_cursor()
  end, "fork the agent at the message under the cursor" },
  { "l", function()
    require("isovim.landing").open()
  end, "the landing: what isovim is, its keys, quick actions" },
  { "U", function()
    require("isovim.update").check(true)
  end, "check for an isovim update now" },
  { "!", function()
    require("isovim.update").restart()
  end, "restart isovim now, onto the code on disk" },
}

-- The <leader>a keys from before: {key, what it did, its replacement}.
local function on_current(action)
  return function()
    local ws = isovim().current
    if not ws then
      return toast("No workspace selected", "warn")
    end
    sidebar().actions[action]({ ws = ws, ws_name = store.name(ws), kind = "workspace" })
  end
end

-- legacy: refused once enforcement is on (its action says so, in place of the hint).
M.RETIRED = {
  { "t", on_current("isovim_terminal"), "<leader>iN" },
  { "a", on_current("isovim_add_agent"), "<leader>is", legacy = true },
  { "n", function()
    sidebar().actions.isovim_add()
  end, "<leader>is", legacy = true },
  { "j", function()
    isovim().next_needs_you()
  end, "<leader>in" },
  { "w", function()
    isovim().switch_workspace()
  end, "<leader>iP or <leader>ia" },
  { "b", function()
    isovim().last_workspace()
  end, "<leader>ip" },
  { "m", on_current("isovim_move"), "m in the sidebar" },
  { "d", function()
    isovim().changes()
  end, "c in the sidebar" },
  { "o", function()
    isovim().open_port(isovim().current)
  end, "o in the sidebar" },
  { "f", function()
    isovim().find()
  end, "<leader>/ (this project's transcripts)" },
  { "r", function()
    isovim().run_script()
  end, "iso <role> run (no key yet)" },
  { "u", function()
    isovim().unarchive()
  end, "no key yet", legacy = true },
}

function M.setup()
  for _, key in ipairs(M.GLOBAL) do
    vim.keymap.set("n", key[1], key[2], { desc = "isovim: " .. key[3] })
  end
  for _, key in ipairs(M.GROUP) do
    vim.keymap.set("n", "<leader>i" .. key[1], key[2], { desc = "isovim: " .. key[3] })
  end
  for _, key in ipairs(M.RETIRED) do
    local fn = key[2]
    vim.keymap.set("n", "<leader>a" .. key[1], function()
      if not (key.legacy and require("isovim.config").enforced()) then
        M.hint("<leader>a" .. key[1], key[3])
      end
      fn()
    end, { desc = "which_key_ignore" })
  end
  pcall(function()
    require("which-key").add({ { "<leader>i", group = "isovim" } })
  end)
end

return M
