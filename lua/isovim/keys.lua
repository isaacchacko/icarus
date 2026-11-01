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

-- A key whose target isn't built yet says so.
local function not_yet(what)
  return function()
    toast(what .. ": not yet")
  end
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
      local kind_icon, kind_hl = icons.get(item.kind)
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

-- Opens the scope: the root for Root, the Terminals window for Terminals, else the scope's agent
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

local PSEUDO_ICONS = { root = "root", general = "general", terminals = "terminal" }

function M.pick_repo()
  local counts = {}
  for _, entry in ipairs(M.agents()) do
    counts[entry.scope] = (counts[entry.scope] or 0) + 1
  end
  Snacks.picker.pick({
    source = "isovim_repos",
    title = "Repos",
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
  elseif store.v2(ws) and ws ~= "_" then
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

-- The prompt queue of the ACP agent whose chat (or composer) you're in, else the one on screen.
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
  local win = vim.fn.bufwinid(chat.composer)
  require("isovim.acp.queue").open(chat.ws, chat.agent, win ~= -1 and win or nil)
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

-- The current repo's Inbox (repo), this host's (host) or the other hosts' (others), opened, the
-- cursor on its first surface waiting on you.
local function inbox(which)
  return function()
    sidebar().focus_inbox(which)
  end
end

-- Spawns a worker in the current repo, as s does on a repo in the sidebar.
function M.spawn()
  sidebar().spawn(isovim().current)
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
  { "<leader><leader>", M.pick_repo, "pick a repo (or Root, General, Terminals)" },
  { "<leader>ff", M.find_files, "find a file in the repo" },
  { "<leader>/", M.grep, "grep the repo and its agents' transcripts" },
  { "<leader>,", M.buffers, "the repo's buffers" },
  { "<leader>fr", M.recent_agents, "recent agents" },
  { "<leader>fR", function()
    Snacks.picker.recent()
  end, "recent files" },
}

M.GROUP = {
  { "n", function()
    isovim().next_needs_you()
  end, "next agent that needs you" },
  { "i", inbox("repo"), "the repo's Inbox" },
  { "h", inbox("host"), "the host's Inbox" },
  { "I", inbox("others"), "the other hosts' Inbox" },
  { "r", open_role("router", "router"), "the repo's router" },
  { "R", M.nearest_root, "the nearest root (repo-root, else host root)" },
  { "H", M.open_host_root, "the host root" },
  { "w", M.workers, "a worker in the repo" },
  { "a", M.any_agent, "any agent" },
  { "b", M.previous_agent, "the previous agent" },
  { "g", function()
    M.select_scope(scope.GENERAL)
  end, "General (agents in no repo)" },
  { "T", function()
    sidebar().focus_window("terminals")
  end, "the Terminals window" },
  { "s", M.spawn, "spawn a worker over ACP in the repo" },
  { "t", M.new_terminal, "new terminal" },
  { "<lt>", function()
    sidebar().step_host(-1)
  end, "the previous host" },
  { ">", function()
    sidebar().step_host(1)
  end, "the next host" },
  { "x", not_yet("Root mode"), "root mode on the repo (not yet)" },
  { "j", function()
    require("isovim.jump").picker()
  end, "jump: a dir isovim keeps, one level at a time" },
  { "q", M.prompt_queue, "the prompt queue of the agent on screen" },
  { "u", not_yet("Rewind"), "rewind at the prompt under the cursor (not yet)" },
  { "f", not_yet("Fork at a message"), "fork at the message under the cursor (not yet)" },
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

M.RETIRED = {
  { "t", on_current("isovim_terminal"), "<leader>it" },
  { "a", on_current("isovim_add_agent"), "<leader>is" },
  { "n", function()
    sidebar().actions.isovim_add()
  end, "<leader>is" },
  { "j", function()
    isovim().next_needs_you()
  end, "<leader>in" },
  { "w", function()
    isovim().switch_workspace()
  end, "<leader><leader> or <leader>ia" },
  { "b", function()
    isovim().last_workspace()
  end, "<leader>ib" },
  { "m", on_current("isovim_move"), "m in the sidebar" },
  { "d", function()
    isovim().changes()
  end, "c in the sidebar" },
  { "o", function()
    isovim().open_port(isovim().current)
  end, "o in the sidebar" },
  { "f", function()
    isovim().find()
  end, "<leader>/ (this repo's transcripts)" },
  { "r", function()
    isovim().run_script()
  end, "iso <role> run (no key yet)" },
  { "u", function()
    isovim().unarchive()
  end, "no key yet" },
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
      M.hint("<leader>a" .. key[1], key[3])
      fn()
    end, { desc = "which_key_ignore" })
  end
  pcall(function()
    require("which-key").add({ { "<leader>i", group = "isovim" } })
  end)
end

return M
