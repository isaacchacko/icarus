local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local scope = require("isovim.scope")
local prs = require("isovim.prs")
local icons = require("isovim.icons")
local stream = require("isovim.stream")
local layout = require("isovim.layout")
local diffstat = require("isovim.diffstat")
local remote = require("isovim.remote")

local M = {}

M.current = nil ---@type string? id of the workspace last focused
M.sort = "created" ---@type "created"|"active"
M.show_hidden = false
M.show_prs = false -- every workspace lists its PRs instead of its agents
M.show_ports = false -- rows show the ports their agents and terminals listen on
M.show_tasks = false -- agents' tasks show under their rows
M.explorer_roots = {} ---@type table<string, {cwd: string, file?: string}> workspace id -> where its explorer was left
M.recent = {} ---@type string[] workspace ids, most recently selected first (<leader>aw)
M.expanded = {} ---@type table<string, true> workspaces (host:id for another host's) whose rows show; the rest are collapsed

-- Persisted so a hot reload picks up where the old code left off.
function M.remember(key, value)
  M[key] = value
  store.write_session({
    current = M.current,
    sort = M.sort,
    show_hidden = M.show_hidden,
    show_prs = M.show_prs,
    show_ports = M.show_ports,
    show_tasks = M.show_tasks,
    explorer_roots = M.explorer_roots,
    recent = M.recent,
    expanded = M.expanded,
  })
end

-- The sidebar is a non-floating snacks_layout_box holding floating picker windows.
local function is_sidebar(win)
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return (ft:match("^snacks_") and ft ~= "snacks_dashboard") or vim.api.nvim_win_get_config(win).relative ~= ""
end

-- Pickers, grep and :e work in the workspace's project, as in a normal nvim session there; with
-- none selected, in ~.
local function enter_dir(id)
  local dir = id and store.dir(id) or vim.fs.normalize("~")
  if vim.fn.getcwd() ~= dir then
    vim.cmd.cd({ vim.fn.fnameescape(dir), mods = { silent = true } })
  end
end

-- Selecting a workspace scopes the buffer list to it and brings back its splits, keeping the
-- buffer just opened on screen; the sidebar's cursor follows.
local function select(id)
  local switching = id ~= M.current
  if id then
    M.recent = vim.list_extend({ id }, vim.tbl_filter(function(other)
      return other ~= id
    end, M.recent))
  end
  M.remember("current", id)
  enter_dir(id)
  -- The terminal's tab or window title says which workspace isovim is on.
  vim.o.title = true
  vim.o.titlestring = id and ("isovim · " .. store.name(id)) or "isovim"
  scope.apply(id, is_sidebar)
  if switching and id then
    local buf = vim.api.nvim_get_current_buf()
    local want = vim.b[buf].isovim_ws == id and buf or nil
    -- Its splits from this session, else from its layout.json (moved in, unarchived, not yet visited),
    -- unless they're on screen: rebuilding would close the split just opened from.
    if not layout.shown(id, is_sidebar, want) and not layout.restore(id, is_sidebar, want) then
      layout.resume(id, is_sidebar, M.open_leaf(id), want)
    end
  end
  require("isovim.sidebar").follow()
end

local function main_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not is_sidebar(win) then
      return win
    end
  end
  vim.cmd("botright vnew")
  return vim.api.nvim_get_current_win()
end
M.is_sidebar, M.main_win = is_sidebar, main_win

-- A chat buffer is an agent's terminal (isovim.stream): b:isovim_id is its workspace, b:isovim_agent the agent id.
local function chat_bufs()
  return vim.tbl_filter(function(buf)
    return vim.b[buf].isovim_id ~= nil and vim.bo[buf].buftype == "terminal"
  end, vim.api.nvim_list_bufs())
end

---@return integer? live, integer[] stale chats for the agent whose stream has ended
local function chat_buf(ws, agent)
  local live, stale = nil, {}
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      if stream.alive(buf) then
        live = buf
      else
        table.insert(stale, buf)
      end
    end
  end
  return live, stale
end

-- Whichever the sidebar is showing: Workspaces or the explorer.
local function focus_sidebar()
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if sidebar then
    vim.cmd.stopinsert()
    sidebar:focus("list")
  end
end

-- Claude runs no hook when Esc interrupts it, so its spinner would spin on until the next prompt.
-- Esc reaches it only through ctrl+q, so look for its "Interrupted" line then.
local function watch_interrupt(ws, agent)
  local tries = 0
  local function check()
    tries = tries + 1
    if status.state(ws, agent) ~= "working" then
      return
    elseif panes.capture(ws, agent, 0):find("Interrupted", 1, true) then
      status.set_state(ws, agent, "idle")
    elseif tries < 10 then
      vim.defer_fn(check, 300)
    end
  end
  vim.defer_fn(check, 300)
end

-- Esc leaves the chat like any other mode, to scroll and search it, unless a full-screen program has
-- the pane; ctrl+q (unbound in Claude Code) sends Claude its Esc. ctrl+h goes to the sidebar; ctrl+l
-- to a split on the right, if any.
-- The terminal flattens shift+enter to enter, so it goes as meta+enter, Claude's other newline.
-- A prompt (new workspace, rename, ...) without focus is a float no key can reach: cancel it.
local function close_stray_prompts()
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= current and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_input" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

-- {key, rhs or fn(buf), description}; `?` in the sidebar lists them too.
local CHAT_KEYS = {
  {
    "<Esc>",
    function(buf)
      close_stray_prompts()
      -- A full-screen program (Claude's ctrl+g editor) needs its Esc and has no scrollback to read.
      if stream.fullscreen(buf) then
        return stream.send(buf, "\27")
      end
      vim.cmd.stopinsert()
    end,
    "leave the chat to normal mode, or Esc to a full-screen program in it (and drop any stray prompt)",
  },
  {
    "<C-q>",
    function(buf)
      stream.send(buf, "\27")
      watch_interrupt(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main")
    end,
    "send Esc to the agent",
  },
  {
    "<S-CR>",
    function(buf)
      stream.send(buf, "\27\r")
    end,
    "newline in the chat",
  },
  {
    "<C-h>",
    function()
      focus_sidebar()
    end,
    "go to the sidebar",
  },
  { "<C-l>", [[<C-\><C-n><C-w>l]], "go to the right window" },
}

-- A file opens beside the chat rather than in place of it: in the other editing split, or a new
-- one on the right.
local function open_beside(chat_win, path, lnum)
  local chat = vim.api.nvim_win_get_buf(chat_win)
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= chat_win and not is_sidebar(win) and vim.api.nvim_win_get_buf(win) ~= chat then
      target = target or win
    end
  end
  local file_buf = vim.fn.bufadd(path)
  vim.bo[file_buf].buflisted = true
  if target then
    vim.api.nvim_win_set_buf(target, file_buf)
    vim.api.nvim_set_current_win(target)
  else
    vim.api.nvim_open_win(file_buf, true, { split = "right", win = chat_win })
  end
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), 0 })
    vim.cmd("normal! zz")
  end
end

-- A file the agent mentioned (src/x.py, src/x.py:12, src/x.py:12:5), beside its chat.
local function open_mentioned()
  local file = vim.fn.expand("<cfile>")
  local line = vim.api.nvim_get_current_line()
  local start = line:find(file, 1, true)
  local lnum = start and line:sub(start + #file):match("^:(%d+)")
  local path = vim.fn.findfile(file, ".;") ~= "" and vim.fn.fnamemodify(vim.fn.findfile(file, ".;"), ":p") or file
  if vim.fn.filereadable(path) == 0 then
    return Snacks.notify.warn("No file " .. file)
  end
  open_beside(vim.api.nvim_get_current_win(), path, lnum)
end

-- Normal mode in a chat; `?` lists them too.
local CHAT_NORMAL_KEYS = {
  { "gf", open_mentioned, "open file(:line) beside the chat" },
  { "gF", open_mentioned, "same as gf" },
}
M.chat_keys, M.chat_normal_keys = CHAT_KEYS, CHAT_NORMAL_KEYS

local function map_chat_keys(buf)
  for _, key in ipairs(CHAT_NORMAL_KEYS) do
    vim.keymap.set("n", key[1], function()
      key[2](buf)
    end, { buffer = buf, desc = "isovim: " .. key[3] })
  end
  for _, key in ipairs(CHAT_KEYS) do
    local rhs = key[2]
    if type(rhs) == "function" then
      local fn = rhs
      rhs = function()
        fn(buf)
      end
    end
    vim.keymap.set("t", key[1], rhs, { buffer = buf, desc = "isovim: " .. key[3] })
  end
end

-- Named "<workspace> · <agent>" for :ls and pickers; the ids keep same-named ones apart.
local function name_chat(buf)
  local ws, agent = vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main"
  local spec = store.agent(ws, agent)
  vim.b[buf].isovim_agent_name = spec and spec.name or agent
  vim.b[buf].isovim_agent_kind = spec and spec.kind or "claude"
  local name = store.name(ws):gsub("/", "-")
  vim.api.nvim_buf_set_name(buf, ("isovim://%s/%s/%s · %s"):format(ws, agent, name, vim.b[buf].isovim_agent_name))
end

-- The agent a workspace opens to: its first one you can see.
local function default_agent(ws)
  local agents = store.agents(ws)
  for _, agent in ipairs(agents) do
    if not agent.hidden then
      return agent.id
    end
  end
  return agents[1] and agents[1].id
end

---@param agent? string defaults to the workspace's first visible agent
---@param win? integer where to show it (default: the first editing window)
function M.open(ws, agent, win)
  agent = agent or default_agent(ws)
  local spec = store.agent(ws, agent)
  if not spec then
    Snacks.notify.error(("No agent %s in %s"):format(agent, store.name(ws)))
    return
  end
  if not panes.running(ws, agent) then
    local result = panes.start(ws, spec, store.dir(ws))
    if result.code ~= 0 then
      Snacks.notify.error("Could not start " .. spec.name .. ":\n" .. result.stderr)
      return
    end
  end
  -- Before the chat enters its window, so the statusline reads the project's git branch.
  enter_dir(ws)
  win = win or main_win()
  vim.api.nvim_set_current_win(win)
  local buf, stale = chat_buf(ws, agent)
  if buf then
    vim.api.nvim_win_set_buf(win, buf)
  else
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    -- After the swap, so wiping them can't close the window; before naming, which they'd clash with.
    for _, old in ipairs(stale) do
      vim.api.nvim_buf_delete(old, { force = true })
    end
    stream.attach(buf, ws, agent)
    vim.b[buf].isovim_id = ws
    vim.b[buf].isovim_ws = ws
    vim.b[buf].isovim_agent = agent
    name_chat(buf)
    map_chat_keys(buf)
  end
  status.mark_seen(ws, agent)
  select(ws)
  -- The workspace's splits may have come back around it; the chat opened is the one to focus.
  local shown = vim.fn.bufwinid(buf)
  if shown ~= -1 then
    vim.api.nvim_set_current_win(shown)
  end
end

-- A chat on screen counts as read, even while the sidebar has focus.
-- Only while you're in the TUI: a chat that finishes on screen while you're in another app stays
-- unread (and notifies) until you come back.
function M.mark_visible_seen()
  if not M.focused then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].isovim_id then
      status.mark_seen(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main")
    end
  end
end

-- Restarts an agent (Claude on the same conversation), e.g. to pick up new hooks.
-- The chat comes back on screen only if it was there.
function M.restart(ws, agent)
  agent = agent or default_agent(ws)
  panes.stop(ws, agent)
  local shown = false
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      shown = shown or vim.fn.bufwinid(buf) ~= -1
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if shown then
    M.open(ws, agent)
  else
    panes.start(ws, assert(store.agent(ws, agent)), store.dir(ws))
  end
end

-- An isovim toast for news from outside the TUI, e.g. a workspace moved in from another host.
function M.toast(message)
  Snacks.notify(message, { title = "isovim" })
end

-- Picks up changes made outside the TUI, e.g. by the `iso` CLI.
-- Workspaces archived or moved away (here or by the CLI) leave no chats or selection behind.
local function drop_gone()
  local here = {}
  for _, ws in ipairs(store.list()) do
    here[ws.id] = true
  end
  for _, buf in ipairs(chat_bufs()) do
    if not here[vim.b[buf].isovim_id] then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if M.current and not here[M.current] then
    select(nil)
  end
end

function M.refresh()
  drop_gone()
  for _, buf in ipairs(chat_bufs()) do
    name_chat(buf)
  end
  require("isovim.sidebar").refresh()
end

M.focused = true
local notified = {} ---@type table<string, isovim.Status>

-- A toast, and a desktop notification too while the TUI isn't focused.
local function notify(message, level)
  Snacks.notify(message, { level = level, title = "isovim" })
  if not M.focused then
    vim.system({ panes.hook_script, "desktop", message })
  end
end

-- Notifies when an agent off screen finishes or needs you. Hidden agents never notify. The first
-- pass after setup only records, so reloads stay quiet.
local function notify_changes(quiet)
  M.mark_visible_seen()
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local key = ws.id .. "/" .. agent.id
      local now = status.get(ws.id, agent.id)
      if not quiet and not agent.hidden and now ~= notified[key] and (now == "unread" or now == "attention") then
        local message = ("%s · %s %s"):format(ws.name, agent.name, now == "attention" and "needs you" or "finished")
        notify(message, now == "attention" and "warn" or "info")
      end
      notified[key] = now
    end
  end
end

-- Another host's agent that newly needs you toasts here too, as the sidebar lists it (its own
-- notification shows on that host's screen). A host's first listing only sets what counts as new.
local remote_notified = {} ---@type table<string, table<string, string|false>>
function M.notify_remote(host, rows)
  local first = remote_notified[host] == nil
  local seen = remote_notified[host] or {}
  remote_notified[host] = seen
  for _, row in ipairs(rows) do
    local now = (row.status == "unread" or row.status == "attention") and row.status or false
    if not first and not row.hidden and now and seen[row.id] ~= now then
      local message = ("%s · %s · %s %s"):format(host, row.workspace, row.agent, now == "attention" and "needs you" or "finished")
      notify(message, now == "attention" and "warn" or "info")
    end
    seen[row.id] = now
  end
end

-- Stops the agent, closes its chat and drops it from the workspace.
function M.remove_agent(ws, agent)
  panes.stop(ws, agent)
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == ws and vim.b[buf].isovim_agent == agent then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  store.remove_agent(ws, agent)
  M.refresh()
end

-- Terminals whose shell exited (panes.start's pane-exited hook): gone, with their chats.
local function drop_exited()
  local dropped = false
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local exited = status.state(ws.id, agent.id) == "exited"
      if exited and panes.running(ws.id, agent.id) then
        -- The hook can beat tmux closing the session; look again once it has.
        vim.defer_fn(function()
          if drop_exited() then
            M.refresh()
          end
        end, 500)
      elseif exited then
        for _, buf in ipairs(chat_bufs()) do
          if vim.b[buf].isovim_id == ws.id and vim.b[buf].isovim_agent == agent.id then
            -- Its split closes; the last window shows another buffer.
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
              local mains = vim.tbl_filter(function(w)
                return not is_sidebar(w)
              end, vim.api.nvim_tabpage_list_wins(0))
              if #mains > 1 then
                vim.api.nvim_win_close(win, true)
              end
            end
            Snacks.bufdelete({ buf = buf, force = true })
          end
        end
        vim.cmd.stopinsert()
        store.remove_agent(ws.id, agent.id)
        os.remove(store.state_file(ws.id, agent.id))
        dropped = true
      end
    end
  end
  return dropped
end

-- A pinned file opens beside the workspace's chat and the sidebar stays put; a pinned folder
-- becomes the explorer's root.
function M.reveal(ws, path)
  select(ws)
  if vim.fn.isdirectory(path) == 1 then
    return require("isovim.sidebar").show_explorer({ cwd = path })
  end
  local chat_win = vim.tbl_filter(function(win)
    return not is_sidebar(win) and vim.b[vim.api.nvim_win_get_buf(win)].isovim_id == ws
  end, vim.api.nvim_tabpage_list_wins(0))[1]
  open_beside(chat_win or main_win(), path)
end

---@param opts? {reload?: boolean}
function M.setup(opts)
  local reloading = opts and opts.reload
  local session = store.read_session()
  if session.current and vim.uv.fs_stat(store.path(session.current)) then
    M.current = session.current
  end
  M.sort = session.sort or M.sort
  M.show_hidden = session.show_hidden or false
  M.show_prs = session.show_prs or false
  M.show_ports = session.show_ports or false
  M.show_tasks = session.show_tasks or false
  M.explorer_roots = session.explorer_roots or {}
  M.recent = session.recent or {}
  M.expanded = session.expanded or {}

  local sidebar = require("isovim.sidebar")
  icons.setup()
  vim.keymap.set("n", "<leader>e", sidebar.toggle, { desc = "isovim: focus or close the sidebar" })
  for _, lhs in ipairs({ "<leader>E", "<leader>fe", "<leader>fE" }) do
    vim.keymap.set("n", lhs, sidebar.files, { desc = "isovim: the workspace's files in the sidebar" })
  end
  -- The sidebar's actions from anywhere, on the current workspace.
  local function on_current(action)
    return function()
      if not M.current then
        Snacks.notify.warn("No workspace selected")
        return
      end
      sidebar.actions[action](nil, { ws = M.current, ws_name = store.name(M.current), kind = "workspace" })
    end
  end
  for lhs, map in pairs({
    ["<leader>at"] = { on_current("isovim_terminal"), "new terminal" },
    ["<leader>aa"] = { on_current("isovim_add_agent"), "new agent" },
    ["<leader>am"] = { on_current("isovim_move"), "move the workspace to another host" },
    ["<leader>an"] = { sidebar.actions.isovim_add, "new workspace" },
    ["<leader>aj"] = { M.next_needs_you, "jump to what needs you" },
    ["<leader>ar"] = { M.run_script, "run the workspace's run script" },
    ["<leader>aw"] = { M.switch_workspace, "switch workspace" },
    ["<leader>ab"] = { M.last_workspace, "back to the last workspace" },
    ["<leader>au"] = { M.unarchive, "unarchive a workspace" },
    ["<leader>ad"] = { M.changes, "the workspace's changes since its base" },
    ["<leader>af"] = { function()
      M.find()
    end, "find the agent that was on something, on any host" },
    ["<leader>ao"] = { function()
      M.open_port(M.current)
    end, "open the workspace's dev server in the browser" },
  }) do
    vim.keymap.set("n", lhs, map[1], { desc = "isovim: " .. map[2] })
  end

  pcall(function()
    require("which-key").add({ { "<leader>a", group = "isovim" } })
  end)
  local group = vim.api.nvim_create_augroup("isovim", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local ws = vim.b[ev.buf].isovim_id
      if ws then
        status.mark_seen(ws, vim.b[ev.buf].isovim_agent or "main")
      end
      -- Reaching another workspace's buffer (e.g. with :b) selects that workspace.
      scope.tag(ev.buf, M.current)
      local tagged = vim.b[ev.buf].isovim_ws
      if tagged and tagged ~= "" and tagged ~= M.current then
        select(tagged)
      elseif ws then
        sidebar.follow()
      end
    end,
  })
  -- A chat scrolls no further down than its last line and never sideways. The window would scroll
  -- past the end, the terminal snap it back on its next refresh, and a trackpad's momentum would
  -- scroll it past again, over and over. The wheel over a chat at its end does nothing at all;
  -- the clamp below catches the keys that scroll.
  local function chat_under_mouse()
    local win = vim.fn.getmousepos().winid
    return win ~= 0 and vim.b[vim.api.nvim_win_get_buf(win)].isovim_agent_kind and win or nil
  end
  for _, key in ipairs({ "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
    vim.keymap.set({ "n", "x", "t" }, key, function()
      return chat_under_mouse() and "" or key
    end, { expr = true, desc = "isovim: no sideways scrolling in a chat" })
  end
  vim.keymap.set({ "n", "x", "t" }, "<ScrollWheelDown>", function()
    local win = chat_under_mouse()
    if not win then
      return "<ScrollWheelDown>"
    end
    local below = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - vim.fn.line("w$", win)
    local step = math.min(below, tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3)
    return step > 0 and ("<Cmd>lua vim.api.nvim_win_call(%d, function() vim.cmd('normal! %d\\5') end)<CR>"):format(win, step)
      or ""
  end, { expr = true, desc = "isovim: scroll a chat down, no further than its end" })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and vim.api.nvim_win_is_valid(win) and vim.b[vim.api.nvim_win_get_buf(win)].isovim_agent_kind then
          vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            local last = math.max(1, vim.api.nvim_buf_line_count(0) - vim.api.nvim_win_get_height(0) + 1)
            if view.topline > last or view.leftcol > 0 then
              vim.fn.winrestview({ topline = math.min(view.topline, last), leftcol = 0 })
            end
          end)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "WinResized", "WinEnter", "BufWinEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        layout.save(M.current, is_sidebar)
      end)
    end,
  })
  -- The sidebar never fills the screen alone: :q on the last editing window quits isovim as it would
  -- quit nvim (agents keep running), and losing it any other way (a chat wiped) puts back an empty one.
  local quitting = false
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      quitting = true
      vim.schedule(function()
        quitting = false
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      local by_quit = quitting
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if not is_sidebar(win) then
            return
          end
        end
        if by_quit then
          vim.cmd("confirm qall")
        else
          local sidebar_focused = is_sidebar(vim.api.nvim_get_current_win())
          local current = vim.api.nvim_get_current_win()
          main_win()
          if sidebar_focused then
            vim.api.nvim_set_current_win(current)
          end
        end
      end)
    end,
  })
  -- A prompt (new workspace, rename, ...) left behind is a float you can't reach: leaving one
  -- cancels it. (Snacks sets the prompt's filetype with events off, so FileType never fires.)
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "snacks_input" then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end)
    end,
  })
  -- Belt and braces: whenever focus lands anywhere, a prompt that doesn't have it is cancelled,
  -- even when focus moved without a WinLeave (noautocmd).
  vim.api.nvim_create_autocmd("WinEnter", { group = group, callback = close_stray_prompts })
  vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
    group = group,
    callback = function(ev)
      M.focused = ev.event == "FocusGained"
      if M.focused then
        M.refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      status.stop()
      store.release_lock()
    end,
  })

  -- The `iso` CLI and the agents' hooks find this instance by its socket.
  if not vim.tbl_contains(vim.fn.serverlist(), store.socket) then
    pcall(vim.fn.serverstart, store.socket)
  end

  enter_dir(M.current)
  scope.apply(M.current, is_sidebar)
  notify_changes(true)
  -- Files agents edit reload in their buffers (autoread) as an agent's state moves and, while one
  -- works, every second; nvim alone only looks on focus and buffer events.
  local function reload_files()
    if not vim.api.nvim_get_mode().mode:match("^[cr]") then
      pcall(vim.cmd.checktime)
    end
  end
  local ticks = 0
  drop_exited()
  status.start(function()
    if drop_exited() then
      return M.refresh()
    end
    notify_changes()
    reload_files()
    vim.cmd.redrawtabline()
    -- An agent that just went quiet has finished drawing: its chat must match its pane.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].isovim_id and status.state(vim.b[buf].isovim_id, vim.b[buf].isovim_agent or "main") ~= "working" then
        vim.defer_fn(function()
          stream.check(buf)
        end, 500)
      end
    end
    sidebar.refresh()
  end, function()
    ticks = ticks + 1
    if ticks % 10 == 0 then
      reload_files()
    end
    local picker = Snacks.picker.get({ source = "isovim" })[1]
    if picker then
      picker.list:update({ force = true })
    else
      status.animate(false)
    end
  end)

  -- PRs are watched in the background, not only in the P view, to tell you when checks finish
  -- or one merges.
  prs.on_news = function(ws, pr, news)
    local message = ("%s · #%s %s"):format(store.name(ws), pr.number or "?", news)
    notify(message, news == "checks failed" and "warn" or "info")
  end
  if not _G.isovim_pr_timer then
    _G.isovim_pr_timer = vim.uv.new_timer()
    _G.isovim_pr_timer:start(5000, 60000, vim.schedule_wrap(function()
      require("isovim").poll_prs()
    end))
  end
  -- Timers call through require, so after a hot reload they run the new code; one an older isovim
  -- started with its own closure is replaced.
  if _G.isovim_title_timer and not _G.isovim_title_timer_polls then
    _G.isovim_title_timer:close()
    _G.isovim_title_timer = nil
  end
  _G.isovim_title_timer_polls = true
  if not _G.isovim_title_timer then
    _G.isovim_title_timer = vim.uv.new_timer()
    _G.isovim_title_timer:start(3000, 3000, vim.schedule_wrap(function()
      require("isovim").poll()
    end))
  end
  if not _G.isovim_idle_timer then
    _G.isovim_idle_timer = vim.uv.new_timer()
    _G.isovim_idle_timer:start(60000, 60000, vim.schedule_wrap(function()
      require("isovim.hooks").check_idle()
    end))
  end
  if reloading then
    for _, buf in ipairs(chat_bufs()) do
      map_chat_keys(buf)
      name_chat(buf)
    end
    sidebar.reopen()
    return
  end
  require("isovim.reload").watch()
  if vim.fn.argc() == 0 then
    sidebar.open()
    vim.schedule(M.resume)
  end
end

-- Another host's agent, attached over ssh in a terminal here; reopening shows the same one.
function M.open_remote(host, ssh, id, ws_name, agent_name)
  local name = ("isovim://%s/%s · %s"):format(host, ws_name, agent_name)
  local buf = vim.fn.bufnr(name)
  local win = main_win()
  vim.api.nvim_set_current_win(win)
  if buf ~= -1 and vim.b[buf].terminal_job_id and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0)[1] == -1 then
    vim.api.nvim_win_set_buf(win, buf)
    return
  elseif buf ~= -1 then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)
  vim.fn.jobstart(remote.attach_cmd(ssh, id), { term = true })
  vim.api.nvim_buf_set_name(buf, name)
  vim.b[buf].isovim_agent_name = host .. " · " .. agent_name
  vim.b[buf].isovim_agent_kind = "host"
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { buffer = buf, desc = "isovim: leave the chat to normal mode" })
  vim.keymap.set("t", "<C-q>", function()
    vim.fn.chansend(vim.b[buf].terminal_job_id, "\27")
  end, { buffer = buf, desc = "isovim: send Esc to the agent" })
  vim.keymap.set("t", "<C-h>", focus_sidebar, { buffer = buf, desc = "isovim: go to the sidebar" })
  vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], { buffer = buf, desc = "isovim: go to the right window" })
end

-- ctrl+/ as in LazyVim, but the terminal is the workspace's own (it outlives the TUI and shows in
-- the sidebar): a bottom split shows it, or hides it if it's on screen. Without a workspace,
-- LazyVim's.
function M.toggle_terminal()
  local ws = M.current
  if not ws then
    return Snacks.terminal()
  end
  local is_terminal = function(kind)
    return kind == "terminal" or kind == "shell"
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].isovim_id == ws and is_terminal(vim.b[buf].isovim_agent_kind) and #vim.tbl_filter(function(w)
      return not is_sidebar(w)
    end, vim.api.nvim_tabpage_list_wins(0)) > 1 then
      vim.cmd.stopinsert()
      return vim.api.nvim_win_close(win, false)
    end
  end
  local agent
  for _, spec in ipairs(store.agents(ws)) do
    if is_terminal(spec.kind) and not agent then
      agent = spec.id
    end
  end
  agent = agent or store.add_agent(ws, { kind = "terminal" }).id
  local above = is_sidebar(vim.api.nvim_get_current_win()) and main_win() or vim.api.nvim_get_current_win()
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(placeholder, true, { split = "below", win = above, height = 15 })
  M.open(ws, agent, win)
  M.refresh()
end

-- Pick an archived workspace to bring back, and open it.
function M.unarchive()
  vim.ui.select(store.archived(), {
    prompt = "Unarchive",
    format_item = function(ws)
      return ws.name .. "  " .. os.date("%b %d %H:%M", ws.archived)
    end,
  }, function(ws)
    if not ws then
      return
    end
    local ok, err = store.unarchive(ws.id)
    if not ok then
      return Snacks.notify.error(err)
    elseif err then
      Snacks.notify.warn(err, { title = "isovim" })
    end
    M.open(ws.id)
    M.refresh()
  end)
end

-- m on another host's workspace: that host moves it here (iso move there, to this host's name),
-- and it opens once it lands.
function M.move_here(item)
  if not item.remote_ws then
    return
  end
  local me = remote.self()
  local function move(force)
    Snacks.notify.info(("Moving %s here from %s…"):format(item.ws_name, item.host), { title = "isovim" })
    local args = item.remote_ws .. " " .. me .. (force and " --force" or "")
    local cmd = ("%s %s %s"):format(remote.ssh, vim.fn.shellescape(item.ssh), vim.fn.shellescape(remote.remote_bin .. " move " .. args))
    vim.system({ "bash", "-c", cmd }, { text = true }, vim.schedule_wrap(function(result)
      local busy = (result.stderr or ""):match("iso: (.- is working)")
      if busy then
        return Snacks.picker.util.confirm(busy .. ". Move anyway?", function()
          move(true)
        end)
      elseif result.code ~= 0 then
        return Snacks.notify.error(vim.trim(result.stderr))
      end
      remote.invalidate(item.host)
      M.refresh()
      if vim.uv.fs_stat(store.path(item.remote_ws)) then
        M.open(item.remote_ws)
      end
    end))
  end
  move(false)
end

-- The workspace's changes: every hunk the workspace changed since its branch left the remote default
-- branch, committed or not, to read through and jump into; just the uncommitted ones without one.
---@param ws? string default: the current workspace
function M.changes(ws)
  ws = ws or M.current
  if not ws then
    return Snacks.notify.warn("No workspace selected")
  end
  local dir = store.dir(ws)
  local has_base = vim.system({ "git", "-C", dir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD" }):wait().code == 0
  Snacks.picker.git_diff({ cwd = dir, base = has_base and "origin/HEAD" or nil, title = store.name(ws) .. " changes" })
end

function M.new_workspace()
  require("isovim.sidebar").actions.isovim_add()
end

-- Fuzzy-pick a workspace to switch to, most recently selected first.
-- The workspace you were in before this one, splits and all; again flips back, like vim's <C-^>.
function M.last_workspace()
  for _, id in ipairs(M.recent) do
    if id ~= M.current and vim.uv.fs_stat(store.path(id)) then
      return M.open(id)
    end
  end
  Snacks.notify.info("No other workspace yet", { title = "isovim" })
end

function M.switch_workspace()
  local sessions = panes.sessions()
  local workspaces = store.list()
  for _, ws in ipairs(workspaces) do
    ws.active = ws.modified
    for _, at in pairs(sessions[ws.id] or {}) do
      ws.active = math.max(ws.active, at)
    end
  end
  -- Alt-tab order: the ones you selected, most recent first, then the rest by activity.
  local rank = {}
  for i, id in ipairs(M.recent) do
    rank[id] = i
  end
  table.sort(workspaces, function(a, b)
    local ra, rb = rank[a.id] or math.huge, rank[b.id] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a.active > b.active
  end)
  workspaces = vim.tbl_filter(function(ws)
    return ws.id ~= M.current
  end, workspaces)
  vim.ui.select(workspaces, {
    prompt = "Workspace",
    format_item = function(ws)
      return ws.name .. "  " .. vim.fn.fnamemodify(ws.dir, ":~")
    end,
  }, function(ws)
    if ws then
      M.open(ws.id)
    end
  end)
end

-- The repo's run script (.isovim or .superset config.json), in a "run" terminal; again restarts it.
function M.run_script()
  if not M.current then
    return Snacks.notify.warn("No workspace selected")
  end
  local agent = require("isovim.scripts").start(M.current, "run")
  if not agent then
    return Snacks.notify.warn("No run script in .isovim/config.json or .superset/config.json")
  end
  for _, buf in ipairs(chat_bufs()) do
    if vim.b[buf].isovim_id == M.current and vim.b[buf].isovim_agent == agent then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.open(M.current, agent)
  M.refresh()
end

-- Opens the agent that has waited longest for you: questions before finished work.
function M.next_needs_you()
  local best
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      agent.status = status.get(ws.id, agent.id)
      if require("isovim.sidebar").needs_you(agent) then
        local rank = agent.status == "attention" and 0 or 1
        local since = vim.fn.getftime(store.state_file(ws.id, agent.id))
        if not best or rank < best.rank or (rank == best.rank and since < best.since) then
          best = { ws = ws.id, agent = agent.id, rank = rank, since = since }
        end
      end
    end
  end
  if best then
    M.open(best.ws, best.agent)
  else
    Snacks.notify.info("Nothing needs you", { title = "isovim" })
  end
end

function M.poll_prs()
  for _, ws in ipairs(store.list()) do
    local branch = store.branch(ws.id)
    if branch and ws.dir ~= store.path(ws.id) then
      prs.discover(ws.id, ws.dir, branch, require("isovim.sidebar").refresh)
    end
    if #store.prs(ws.id) > 0 then
      prs.list(ws.id, require("isovim.sidebar").refresh)
    end
  end
end

-- iso find as a live picker, like <leader>/: each keystroke searches every host; the preview
-- shows the agent's transcript at the match, or where else the query turned up. iso find prints one JSON array; jq makes it a row per agent.
function M.find()
  local self = remote.self()
  Snacks.picker.pick({
    source = "isovim_find",
    title = "Find agents",
    -- Chat lines are long; the preview wraps them so the match's sentence reads whole.
    win = { preview = { wo = { wrap = true, linebreak = true } } },
    live = true,
    supports_live = true,
    finder = function(opts, ctx)
      if ctx.filter.search == "" then
        return function() end
      end
      return require("snacks.picker.source.proc").proc(
        ctx:opts({
          cmd = "sh",
          args = { "-c", '"$0" find --json "$1" | jq -c ".[]"', panes.bin, ctx.filter.search },
          notify = false,
          transform = function(item)
            local ok, row = pcall(vim.json.decode, item.text)
            if not ok or type(row) ~= "table" then
              return false
            end
            item.row = row
            item.text = ("%s %s %s"):format(row.workspace, row.agent, row.match or "")
            -- A local transcript previews at the match, highlighted; anything else shows the hit.
            if row.file and row.host == self then
              item.file, item.pos = row.file, { row.line, row.col - 1 }
            end
            item.preview = {
              ft = "markdown",
              text = ("# %s · %s\n\n%s, found in its %s\n\n> %s\n"):format(
                row.workspace,
                row.agent,
                row.host == self and "here" or ("on " .. row.host),
                row.where,
                (row.match or row.workspace):gsub("\n", " ")
              ),
            }
          end,
        }),
        ctx
      )
    end,
    format = function(item)
      local row = item.row
      local icon, hl = icons.get(row.kind)
      local line = { { icon, hl }, { " " } }
      if row.host ~= self then
        line[#line + 1] = { row.host .. ": ", "Comment" }
      end
      vim.list_extend(line, { { row.workspace .. " · " .. row.agent }, { "  " .. row.where, "Comment" } })
      return line
    end,
    preview = function(ctx)
      if ctx.item.file then
        return Snacks.picker.preview.file(ctx)
      end
      return Snacks.picker.preview.preview(ctx)
    end,
    confirm = function(picker, item)
      picker:close()
      local row = item and item.row
      if not row then
        return
      end
      local id = row.id:gsub("^[^:]+:", "")
      if row.host == self then
        local ws, agent = id:match("^([^/]+)/(.+)$")
        M.open(ws, agent)
      else
        M.open_remote(row.host, remote.host_of(row.host), id, row.host .. ":" .. row.workspace, row.agent)
      end
    end,
  })
end

-- http://localhost:<port> for what an agent (or any of the workspace's) listens on; with several,
-- pick one.
function M.open_port(ws, agent)
  if not ws then
    return Snacks.notify.warn("No workspace selected")
  end
  local ports = require("isovim.ports").of(ws, agent)
  local function open(port)
    if port then
      vim.ui.open("http://localhost:" .. port)
    end
  end
  if #ports == 0 then
    Snacks.notify.warn(("Nothing in %s listens on a port"):format(store.name(ws)))
  elseif #ports == 1 then
    open(ports[1])
  else
    vim.ui.select(ports, { prompt = "Open port", format_item = function(port)
      return "localhost:" .. port
    end }, open)
  end
end

-- In a worktree workspace the agents commit as they go, so a file's git signs compare it with where
-- the branch left the default branch: everything the workspace changed.
-- Set after gitsigns' first update of the buffer, which would otherwise put its own base back.
function M.review_base(buf)
  local ws = M.current
  if not ws or not store.branch(ws) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local dir = store.dir(ws)
  if not vim.startswith(vim.api.nvim_buf_get_name(buf), dir .. "/") then
    return
  end
  local base = vim.system({ "git", "-C", dir, "merge-base", "HEAD", "refs/remotes/origin/HEAD" }, { text = true }):wait()
  if base.code ~= 0 then
    return
  end
  vim.api.nvim_create_autocmd("User", {
    pattern = "GitSignsUpdate",
    callback = function(ev)
      if ev.data and ev.data.buffer == buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_call(buf, function()
          require("gitsigns").change_base(vim.trim(base.stdout))
        end)
        return true
      end
    end,
  })
end

-- What changes with no hook to say so: titles and terminals' commands, the ports they serve on,
-- and the current workspace's +/- after a commit made in a terminal. The sidebar redraws when any does.
local last_titles, ticks = nil, 0
function M.poll()
  ticks = ticks + 1
  local now = vim.json.encode(panes.titles())
  if now ~= last_titles then
    last_titles = now
    require("isovim.sidebar").refresh()
  end
  -- lsof is the costly part, and a dev server's port can show a few seconds late.
  if ticks % 3 == 1 then
    require("isovim.ports").poll(require("isovim.sidebar").refresh)
  end
  -- Only the workspace you're in: a git diff per workspace every few seconds adds up. The others
  -- catch up when their agents next report.
  if M.current then
    diffstat.get(store.dir(M.current), require("isovim.sidebar").refresh)
  end
end

-- How a layout.json leaf comes back in its window: the agent's chat, or the file.
function M.open_leaf(ws)
  return function(win, leaf)
    if leaf.agent and store.agent(ws, leaf.agent) then
      M.open(ws, leaf.agent, win)
    elseif leaf.file and vim.fn.filereadable(leaf.file) == 1 then
      vim.api.nvim_win_call(win, function()
        vim.cmd.edit(vim.fn.fnameescape(leaf.file))
      end)
    end
  end
end

-- A fresh start picks up where the last one left off: the selected workspace's splits, chats and
-- files, or at least its chat if its agent is still running.
function M.resume()
  local ws = M.current
  if not ws then
    return
  end
  local resumed = layout.resume(ws, is_sidebar, M.open_leaf(ws))
  if not resumed and panes.running(ws, default_agent(ws)) then
    M.open(ws)
  end
end

return M
