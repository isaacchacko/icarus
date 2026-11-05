-- The sidebar: a column of two windows under its title in the tab line, and the file explorer that
-- can take its place. A footer, and the shown host's list: its Inbox, then the
-- project switcher's row and the current project's sections. A project is a repo, General or
-- Terminals, and the current one follows the focused tab (the current scope,
-- so on the root's chat it stays the one before).
-- init.lua requires this module only from inside functions, so requiring it back makes no cycle.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local icons = require("isovim.icons")
local diffstat = require("isovim.diffstat")
local remote = require("isovim.remote")
local repos = require("isovim.repos")
local meter = require("isovim.meter")
local scripts = require("isovim.scripts")
local scope = require("isovim.scope")
local isovim = require("isovim")

local M = {}

M.local_groups = {} ---@type table<string, table> this host's groups by key, from the last refresh
M.projects, M.project = {}, nil ---@type string[], string? the shown host's projects and the one the list shows

-- Only what waits on you: a raised decision or a question. A finished turn (the green dot) doesn't.
-- A hidden agent's counts too: hiding an agent never hides what needs you.
function M.needs_you(agent)
  return agent.status == "attention"
end

-- Whether the list shows the agent: hidden ones only while H shows them, or while they need you.
local function listed(agent)
  return not agent.hidden or isovim.show_hidden or agent.status == "attention"
end

-- The project switcher's row: the current project between ‹ ›, as the host's name is (the keys are
-- [ and ]); how many others have something that needs you, so nothing's hidden silently; how many
-- of its agents run.
function M.switcher_row(item, glyph, glyph_hl, label)
  local row = { { item.collapsed and "▸ " or "▾ ", "Comment" }, { "‹ ", "Comment" }, { glyph, glyph_hl }, { " " }, { label, glyph_hl }, { " ›", "Comment" } }
  if item.root_mode then
    row[#row + 1] = { "  " .. item.root_mode, "Special" }
  end
  if item.others > 0 then
    row[#row + 1] = { ("  +%d need you"):format(item.others), "DiagnosticWarn" }
  end
  row[#row + 1] = item.running_mark
  return row
end

-- A path as the sidebar names it: relative to the workspace's project dir when inside it.
local function short_path(ws, path)
  local dir = store.dir(ws)
  if dir and vim.startswith(path, dir .. "/") then
    return path:sub(#dir + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- What each kind of row does: how it's drawn, what Enter opens and d removes (nil: nothing), and
-- the fields that keep the cursor on it through refreshes. Another host's rows carry `host`.
local TASK_GLYPHS = {
  todo = { "○", "Comment" },
  doing = { "◐", "DiagnosticInfo" },
  waiting = { "\u{f051f}", "Comment" }, -- md-timer_sand
  blocked = { "⊘", "DiagnosticWarn" },
  done = { "✓", "DiagnosticOk" },
}
M.task_glyphs = TASK_GLYPHS

local KINDS = {
  -- A registered PR, in the jump (<leader><leader>): Enter opens its own view (isovim.pr_view).
  pr = {
    format = function(item)
      local icon, hl = require("isovim.prs").icon(item.pr)
      local label = item.pr.number and ("#%d %s"):format(item.pr.number, item.pr.title or "") or item.pr.url
      return { { icon, hl }, { " " }, { label } }
    end,
    open = function(item)
      require("isovim.pr_view").open(item.repo_key, item.pr.url)
    end,
    id = { "repo_key", "url" },
  },
  hint = {
    format = function(item)
      return { { "  " .. item.text, "Comment" } }
    end,
    id = {},
  },
  -- A repo's header (general's too): its glyph and name in its color, the chevron, and collapsed
  -- what its most urgent agent is up to and how many of its surfaces wait. Enter opens its router.
  repo = {
    format = function(item)
      local chevron = item.collapsed and "▸ " or "▾ "
      local glyph, glyph_hl = icons.get("workspace")
      local name_hl = item.running and "Directory" or "Comment"
      if item.mark then
        glyph, glyph_hl, name_hl = item.mark.glyph, item.mark.hl, item.mark.hl
      end
      local label = item.group_kind == "repo" and item.name:match("[^/]+$") or item.name
      if item.switcher then
        if item.group_kind == "general" then
          glyph, glyph_hl = icons.get("general")
          label = "General"
        end
        return M.switcher_row(item, glyph, glyph_hl, label)
      end
      local row = { { chevron, "Comment" } }
      if item.group_kind == "general" then
        glyph, glyph_hl = icons.get("general")
      end
      if item.group_kind == "repo" or item.group_kind == "general" then
        vim.list_extend(row, { { glyph, glyph_hl }, { " " } })
      end
      vim.list_extend(row, { { label, item.group_kind == "repo" and name_hl or "Comment" } })
      if item.collapsed and item.waiting and item.waiting > 0 then
        vim.list_extend(row, { { " " .. item.waiting, "DiagnosticWarn" } })
      end
      if item.status then
        local icon, hl = status.icon(item.status)
        vim.list_extend(row, { { " " }, { icon, hl } })
      end
      row[#row + 1] = item.running_mark
      return row
    end,
    open = function(item)
      if item.group_kind == "general" and not item.host then
        return require("isovim.keys").select_scope(scope.GENERAL)
      end
      M.open_router(item)
    end,
    id = { "host", "repo_key" },
  },
  -- Terminals, the list's last group, as General is one: its terminals and repo script panes under
  -- it. Enter or Tab collapses it.
  terminals = {
    format = function(item)
      local glyph, glyph_hl = icons.get("terminals")
      if item.switcher then
        return M.switcher_row(item, glyph, glyph_hl, "Terminals")
      end
      return { { item.collapsed and "▸ " or "▾ ", "Comment" }, { glyph, glyph_hl }, { " " }, { "terminals", "Comment" }, item.running_mark }
    end,
    open = function(item)
      M.set_collapsed(item.host, "terminals", nil, not item.collapsed)
      M.refresh()
    end,
    id = { "host" },
  },
  -- The host's Inbox, under the host's name at the list's top: a row for each surface waiting on you.
  -- Another host's says whose it is.
  host_inbox = {
    format = function(item)
      local row = { { item.collapsed and "▸ " or "▾ ", "Comment" }, { "Inbox", "Title" }, { " " .. item.count, item.count > 0 and "DiagnosticWarn" or "Comment" } }
      if item.host then
        row[#row + 1] = { " · " .. item.host, "Comment" }
      end
      if item.root_mode then
        row[#row + 1] = { "  root mode", "Special" }
      end
      return row
    end,
    open = function(item)
      M.set_collapsed(item.host, "inbox", nil, not item.collapsed)
      M.refresh()
    end,
    id = { "host" },
  },
  -- A surface waiting on you, in the host's Inbox: its repo's glyph in its color and short name, then
  -- the surface's own mark and title, and a question a root raised says why, dimmed. Cut to the
  -- window's width. Enter opens it, as in its repo's Inbox.
  waiting = {
    format = function(item, width)
      local mark = item.mark or { glyph = " ", hl = "Comment" }
      local row = { { item.guide or " ", "NonText" }, { mark.glyph, mark.hl }, { " " }, { item.label, mark.hl }, { " - ", "Comment" } }
      local chunks = M.surface_chunks(item.surface)
      -- Its mark and title; a thread has who posted last between them.
      vim.list_extend(row, vim.list_slice(chunks, 1, item.surface.type == "thread" and item.surface.last_glyph and 5 or 3))
      for _, chunk in ipairs(chunks) do
        if vim.startswith(chunk[1], "  ↑ ") then
          row[#row + 1] = { chunk[1], "Comment" }
        end
      end
      return width and M.fit(row, width) or row
    end,
    id = { "host", "repo_key", "name" },
  },
  -- Under the host's Inbox: open threads with only an unread post. They don't need you, so they're apart
  -- from it and not counted as it is; folded till you open it, and gone when there are none.
  host_unread = {
    format = function(item)
      return { { item.collapsed and "▸ " or "▾ ", "Comment" }, { "Unread", "Title" }, { " " .. item.count, "Comment" } }
    end,
    open = function(item)
      M.set_collapsed(item.host, "unread_open", nil, item.collapsed)
      M.refresh()
    end,
    id = { "host" },
  },
  -- A repo's own Inbox: its surfaces, the count those waiting on you.
  repo_inbox = {
    format = function(item)
      local row = { { "  " }, { item.collapsed and "▸ " or "▾ ", "Comment" }, { "Inbox", "Title" } }
      if item.count > 0 then
        row[#row + 1] = { " " .. item.count, "DiagnosticWarn" }
      end
      if item.root_mode then
        row[#row + 1] = { "  root mode", "Special" }
      end
      return row
    end,
    open = function(item)
      M.set_collapsed(item.host, "repo_inbox", item.repo_key, not item.collapsed)
      M.refresh()
    end,
    id = { "host", "repo_key" },
  },
  -- A section of a group (Threads, Surfaces, Files, Agents; its Inbox is repo_inbox): its fold, its
  -- name and count. Threads says when one waits on you or a reply unread, Agents how many run, at
  -- the right.
  -- Enter or Tab folds it.
  section = {
    format = function(item)
      local row = { { "  " }, { item.collapsed and "▸ " or "▾ ", "Comment" }, { item.section, "Title" }, { " " .. item.count, "Comment" } }
      if item.on_you then
        row[#row + 1] = { "  ● waiting on you", "DiagnosticWarn" }
      elseif item.unread then
        row[#row + 1] = { "  ● new reply", "DiagnosticWarn" }
      elseif item.resolved_unread then
        row[#row + 1] = { "  ● resolved", "DiagnosticWarn" }
      end
      row[#row + 1] = item.running_mark
      return row
    end,
    open = function(item)
      -- Threads opens its board (isovim.thread_board), <Tab> folding it as any section.
      local board = item.section == "Threads" and not item.host and M.surfaces().threads_entry(item.repo_key, true)
      if board then
        M.surfaces().open(board)
        return M.refresh()
      end
      -- Agents opens their graph (isovim.agent_graph), as Threads does its board.
      if item.section == "Agents" then
        require("isovim.agent_graph").open()
        return M.refresh()
      end
      M.set_section_folded(item.host, item.repo_key, item.section, not item.collapsed)
      M.refresh()
    end,
    id = { "host", "repo_key", "section" },
  },
  -- A task of the board's (isovim.board_tasks), one row with its threads' marks rolled up, as its threads
  -- aren't listed. Enter shows it in the board's buffer.
  thread_task = {
    format = function(item, width)
      local row = { { "  " }, { item.guide, "NonText" }, { "\u{f0ae} ", "Comment" }, { item.task_title, item.needs and "" or "Comment" } }
      vim.list_extend(row, item.marks or {})
      return width and M.fit(row, width) or row
    end,
    open = function(item)
      if item.host then
        return Snacks.notify.info(("That's on %s; switch there with > (or <)"):format(item.host), { title = "isovim" })
      end
      local task = M.surfaces().task_entry(item.repo_key, item.task_id)
      if task then
        M.surfaces().open(task)
      end
      M.refresh()
    end,
    id = { "host", "repo_key", "task_id" },
  },
  -- A surface: one format per type (markdown, question, file, folder, chat).
  surface = {
    format = function(item, width)
      -- In an Inbox, under a tree guide; else indented as its group's agents are.
      local lead = item.guide and { { "  " }, { item.guide, "NonText" } } or { { ("  "):rep(item.depth + 1) } }
      local row = vim.list_extend(lead, M.surface_chunks(item.surface))
      return width and M.fit(row, width) or row
    end,
    open = function(item)
      if item.host then
        return Snacks.notify.info(("That's on %s; switch there with > (or <)"):format(item.host), { title = "isovim" })
      end
      local mod = M.surfaces()
      if mod and mod.open then
        local ok, err = pcall(mod.open, item.surface)
        if not ok then
          Snacks.notify.error("Could not open " .. tostring(item.name) .. ":\n" .. tostring(err), { title = "isovim" })
        end
      end
      M.refresh()
    end,
    id = { "host", "repo_key", "name" },
  },
  -- An agent's task, under its row: subtasks one level further in; done ones dimmed. Enter opens the
  -- agent; the agent owns its tasks, so d leaves them alone.
  task = {
    format = function(item)
      local glyph, hl = unpack(TASK_GLYPHS[item.task.status] or TASK_GLYPHS.todo)
      local done = item.task.status == "done"
      local row = { { ("    " .. ("  "):rep(item.depth)) }, { glyph, hl }, { " " }, { item.task.title, done and "Comment" or nil } }
      for _, pr in ipairs(item.task.prs or {}) do
        row[#row + 1] = { " #" .. pr, "Comment" }
      end
      if item.task.detail and not done then
        row[#row + 1] = { "  " .. item.task.detail, "Comment" }
      end
      return row
    end,
    id = { "ws", "agent", "task_id" },
  },
  -- Under its repo's header with a status icon: the router and root by role, a worker by name
  -- with the size of its team (counted, not listed); the root pinned at the top. Anything not
  -- running is dimmed; hidden agents have an eye at the right edge, read-only ones a lock. In an Inbox the attention icon still marks a legacy
  -- agent that raised something, until the cutover.
  agent = {
    format = function(item)
      local icon, hl = status.icon(item.status)
      local kind_icon, kind_hl = icons.get(item.glyph or ((item.role == "router" or item.role == "dedicated") and "router") or item.agent_kind)
      local name_hl = item.hidden and "Comment" or (not item.running and "Comment" or nil)
      local label = item.label
      if not label and (item.role == "router" or item.role == "root") then
        label = item.v2 and item.role or (item.role .. " · " .. item.name)
      end
      local lead = item.guide and { { "  " }, { item.guide, "NonText" } } or { { ("  "):rep((item.depth or 0) + 1) } }
      local row = vim.list_extend(lead, { { icon, hl }, { " " }, { kind_icon, kind_hl }, { " " }, { label or item.name, name_hl } })
      if item.team and item.team > 0 then
        row[#row + 1] = { (" (+%d)"):format(item.team), "Comment" }
      end
      if item.added and item.added + item.removed > 0 then
        vim.list_extend(row, { { " +" .. item.added, "Added" }, { " −" .. item.removed, "Removed" } })
      end
      if item.trace then
        row[#row + 1] = { item.trace, hl or "Comment", right = true }
      end
      if item.hidden then
        row[#row + 1] = { "\u{f0209}", "Comment", right = true } -- md-eye_off
      end
      if item.read_only then
        row[#row + 1] = { "\u{f033e}", "Comment", right = true } -- md-lock
      end
      -- What it's on: the task title Claude gives its terminal, or the command a terminal runs.
      -- The ports it serves on first: the subtitle is often long enough to be cut off.
      if isovim.show_ports and item.ports and #item.ports > 0 then
        row[#row + 1] = { "  :" .. table.concat(item.ports, " :"), "Special" }
      end
      if item.subtitle and item.subtitle ~= item.name then
        row[#row + 1] = { "  " .. item.subtitle, "Comment" }
      end
      row[#row + 1] = item.running_mark
      return row
    end,
    open = function(item)
      if item.host then
        isovim.open_remote(item.host, item.ssh, item.agent, item.ws_name, item.name)
      else
        isovim.open(item.ws, item.agent)
      end
    end,
    delete = function(item)
      Snacks.picker.util.confirm(("Remove %s from %s?"):format(item.name, item.ws_name), function()
        isovim.remove_agent(item.ws, item.agent)
      end)
    end,
    id = { "ws", "agent" },
  },
  path = {
    format = function(item)
      local icon, hl = "\u{f07b}", "Directory"
      if not item.is_dir then
        local ok, mini = pcall(require, "mini.icons")
        icon, hl = "\u{f15b}", "Comment"
        if ok then
          icon, hl = mini.get("file", item.path)
        end
      end
      local lead = item.guide and { { "  " }, { item.guide, "NonText" } } or { { "  " }, { " " }, { " " } }
      return vim.list_extend(lead, { { icon, hl }, { " " }, { item.label, item.is_dir and "Directory" or nil } })
    end,
    open = function(item)
      isovim.reveal(item.ws, item.path)
    end,
    delete = function(item)
      store.unpin(item.ws, item.path)
      M.refresh()
    end,
    id = { "ws", "path" },
  },
}
-- A row under Unread, drawn as the Inbox's are.
KINDS.unread = KINDS.waiting
KINDS.task.open = KINDS.agent.open
KINDS.waiting.open = KINDS.surface.open

-- y in the command line to a one-key question, anything else no.
local function confirmed(question)
  vim.api.nvim_echo({ { question .. " y/n ", "Question" } }, false, {})
  local ok, key = pcall(vim.fn.getcharstr)
  vim.api.nvim_echo({ { "" } }, false, {})
  return ok and (key == "y" or key == "Y")
end

-- d on a surface: a file or folder surface only points, so it goes at once (what it names stays),
-- as does a chat's; the PRs surface, isovim's own view, hides until it changes;
-- anything holding content (markdown, a page and its comments, an answered question) goes after a
-- y; a question still waiting goes only if you say so, its asker waiting on it otherwise.
function M.delete_surface(item)
  local entry = item.surface
  if item.host then
    return Snacks.notify.info(("That's on %s; remove it there"):format(item.host), { title = "isovim" })
  end
  local surfaces, title = M.surfaces(), entry.title or entry.name
  local kind = entry.type
  if kind == "decisions" then
    return Snacks.notify.info("The decision log is kept: it's what your roots decided", { title = "isovim" })
  elseif kind == "prs" then
    surfaces.hide(entry)
  elseif kind == "thread" then
    -- Resolved by you, kept with its posts (iso <role> thread ls --all, show): it leaves the list.
    local status, err = require("isovim.threads").resolve(entry.repo, entry.name, "user")
    if not status then
      return Snacks.notify.warn(tostring(err), { title = "isovim" })
    end
    surfaces.scan(entry.repo)
    require("isovim.surfaces").recheck()
    return M.refresh()
  elseif (kind == "file" or kind == "folder" or kind == "link") and entry.needs_you then
    -- Not opened yet: one key too many shouldn't lose what an agent left for you.
    local stays = kind == "link" and "what it points at" or ("the " .. kind)
    if not confirmed(("You haven't opened %q yet. Remove it (%s stays)?"):format(title, stays)) then
      return
    end
    surfaces.remove(entry)
  elseif kind == "file" or kind == "folder" or kind == "link" or kind == "chat" then
    surfaces.remove(entry)
  elseif kind == "question" and not entry.answer then
    if not confirmed(("%q waits on your answer, and its asker on it. Remove it anyway?"):format(title)) then
      return Snacks.notify.info("Kept it: answer it, or its asker will wait", { title = "isovim" })
    end
    surfaces.remove(entry)
  else
    local what = kind == "page" and "page" or kind == "question" and "answered question" or "surface"
    local comments = kind == "page" and #(require("isovim.pages").comments(entry.repo, entry.name) or {}) or 0
    local tail = comments > 0 and (" and its %d comment%s"):format(comments, comments == 1 and "" or "s") or ""
    if not confirmed(("Remove %s %q%s?"):format(what, title, tail)) then
      return
    end
    surfaces.remove(entry)
  end
  require("isovim.surface_view").close(entry.repo, entry.name)
  M.refresh()
end
KINDS.surface.delete = M.delete_surface
KINDS.waiting.delete = M.delete_surface

-- A file's or folder's icon, from mini.icons when it's there.
local function path_icon(path, is_dir)
  if is_dir then
    return "\u{f07b}", "Directory"
  end
  local ok, mini = pcall(require, "mini.icons")
  if ok and path then
    return mini.get("file", path)
  end
  return "\u{f15b}", "Comment"
end

local SURFACE_GLYPHS = {
  markdown = { "\u{f48a}", "Special" }, -- oct-markdown
  page = { "\u{f15c}", "Special" }, -- fa-file-text
  thread = { "\u{f086}", "Special" }, -- fa-comments
  threads = { "\u{f0e8}", "Special" }, -- fa-sitemap
  link = { "\u{f0c1}", "Special" }, -- fa-link
  question = { "?", "DiagnosticWarn" },
  chat = { "●", "DiagnosticOk" },
  tasks = { "\u{f0ae}", "Special" }, -- fa-tasks
  prs = { "\u{f407}", "Special" }, -- oct-git-pull-request
  decisions = { "\u{f029b}", "Special" }, -- md-gavel
  broken = { "\u{f071}", "DiagnosticError" }, -- fa-warning
}

-- A surface's row, after its indent: one format per type. Whatever no longer waits on you (an
-- answered question, a consumable surface already opened) is dimmed.
function M.surface_chunks(entry)
  local kind = entry.type
  local title = entry.title or entry.name or "?"
  local dim = (not entry.needs_you and not entry.resolved_unread and (entry.consumed or entry.answer ~= nil or entry.resolved or entry.parked))
  local title_hl = dim and "Comment" or nil
  local glyph, hl
  if kind == "task" then
    local column = vim.iter(require("isovim.thread_board").COLUMNS):find(function(each)
      return each.key == entry.column
    end)
    return { { column and column.glyph or "\u{f0db}", column and column.hl or "Special" }, { " " }, { entry.name .. "  ", "Comment" }, { title } }
  elseif kind == "file" or kind == "folder" then
    glyph, hl = path_icon(entry.path or title, kind == "folder")
    if entry.exists == false then
      hl = "DiagnosticWarn"
    end
  elseif (kind == "markdown" or kind == "page") and type(entry.icon) == "string" and entry.icon ~= "" then
    glyph, hl = entry.icon, (entry.color and repos.highlight(entry.color)) or "Special"
  else
    glyph, hl = unpack(SURFACE_GLYPHS[kind] or SURFACE_GLYPHS.markdown)
  end
  if (kind == "markdown" or kind == "page") and entry.color and hl == "Special" then
    hl = repos.highlight(entry.color) or hl
  end
  local row = { { glyph, hl }, { " " }, { title, title_hl } }
  if kind == "thread" and entry.last_glyph then
    table.insert(row, 3, entry.last_glyph)
    table.insert(row, 4, { " " })
  end
  if kind == "question" then
    -- Asked in a thread: which one.
    if entry.thread then
      row[#row + 1] = { " · in " .. (entry.thread.title or entry.thread.id), "Comment" }
    end
    if entry.answer then
      row[#row + 1] = { "  answered", "Comment" }
    elseif entry.options then
      row[#row + 1] = { ("  %d options"):format(#entry.options), "Comment" }
    end
    -- Root mode: a root decides it first, quietly; one it raised to you says why.
    if entry.deciding then
      row[#row + 1] = { "  root deciding", "Comment" }
    elseif entry.raised and not entry.answer and entry.raised_by ~= "isovim" then
      row[#row + 1] = { "  ↑ " .. (entry.why or ("raised by " .. (entry.raised_by or "a root"))), "DiagnosticWarn" }
    end
  elseif kind == "decisions" then
    row[#row + 1] = { "  " .. tostring(entry.count or 0), "Comment" }
  elseif kind == "prs" then
    -- In the Inbox, how many wait on you; else how many it lists.
    if (entry.waiting or 0) > 0 then
      row[#row + 1] = { ("  %d waiting on you"):format(entry.waiting), "DiagnosticWarn" }
    else
      row[#row + 1] = { "  " .. tostring(entry.count or 0), "Comment" }
    end
  elseif kind == "link" then
    -- Its note, dim; a web page's chip says whether a local one is up.
    if entry.note then
      row[#row + 1] = { "  " .. entry.note, "Comment" }
    end
    local target = require("isovim.links").resolve(entry.address)
    if target and target.status then
      row[#row + 1] = { "  " .. target.status, target.status_hl or "Comment" }
    end
  elseif kind == "thread" then
    -- How many posts, then whose turn it is: a question or the thread waiting on you (a dot while a
    -- reply's unread), the router's turn on it, a reply you haven't read that needs nothing from you,
    -- the worker it waits on. A resolved one, its outcome, marked till you've read what an agent resolved.
    row[#row + 1] = { "  " .. tostring(entry.posts or 0), "Comment" }
    if entry.parked then
      row[#row + 1] = { (entry.parked_unread and "  ● " or "  ") .. "backburner", "Comment" }
    elseif entry.resolved then
      local outcome = entry.outcome and vim.trim((entry.outcome:gsub("%s+", " ")))
      row[#row + 1] = entry.resolved_unread and { "  ● resolved" .. (outcome and (": " .. outcome) or ""), "DiagnosticWarn" }
        or { "  ✓ " .. (outcome or "resolved"), "Comment" }
    elseif (entry.pending or 0) > 0 then
      row[#row + 1] = { "  ? waiting on you", "DiagnosticWarn" }
    elseif entry.working then
      row[#row + 1] = { "  working…", "Comment" }
    elseif entry.waiting_on == "user" then
      row[#row + 1] = { (entry.new_reply and "  ● " or "  ") .. "waiting on you", "DiagnosticWarn" }
    elseif entry.new_reply then
      row[#row + 1] = { "  new reply", "DiagnosticWarn" }
    elseif entry.waiting_on then
      row[#row + 1] = { "  waiting on " .. (entry.waiting_name or entry.waiting_on), "Comment" }
    end
  elseif kind == "page" then
    -- Its open comments; in the Inbox, how many of them wait on you.
    if (entry.waiting or 0) > 0 then
      row[#row + 1] = { ("  %d waiting on you"):format(entry.waiting), "DiagnosticWarn" }
    elseif (entry.comments_open or 0) > 0 then
      row[#row + 1] = { ("  \u{f075} %d"):format(entry.comments_open), "Comment" }
    end
    -- How many of its and its children's comments and questions are being answered.
    if (entry.moving or 0) > 0 then
      row[#row + 1] = { ("  %s %d being answered"):format(status.icon("working"), entry.moving), "DiagnosticInfo" }
    end
    -- How many pages are beneath it, as only a top-level one has a row.
    if (entry.beneath or 0) > 0 then
      row[#row + 1] = { ("  ↳ %d"):format(entry.beneath), "Comment" }
    end
  elseif (kind == "file" or kind == "folder") and entry.exists == false then
    row[#row + 1] = { "  missing", "DiagnosticWarn" }
  elseif kind == "broken" and entry.error then
    row[#row + 1] = { "  " .. entry.error, "DiagnosticError" }
  end
  if entry.marked_unread then
    row[#row + 1] = { "  unread", "DiagnosticWarn" }
  end
  -- A markdown surface that doesn't parse still opens, saying why.
  if entry.error and kind ~= "broken" then
    row[#row + 1] = { "  broken", "DiagnosticError" }
  end
  return row
end

-- The chunks cut to width cells, the last one cut ending in …
function M.fit(chunks, width)
  local fitted, used = {}, 0
  for _, chunk in ipairs(chunks) do
    local w = vim.api.nvim_strwidth(chunk[1])
    if used + w > width then
      fitted[#fitted + 1] = { vim.fn.strcharpart(chunk[1], 0, math.max(0, width - used - 1)) .. "…", chunk[2] }
      return fitted
    end
    fitted[#fitted + 1] = chunk
    used = used + w
  end
  return fitted
end

-- The chunks cut to leave room for mark at the right edge of width cells, and the mark.
local function with_right_mark(chunks, mark, width)
  local room = width - vim.api.nvim_strwidth(mark[1]) - 1
  local fitted, used = {}, 0
  for _, chunk in ipairs(chunks) do
    if used >= room then
      break
    end
    local text = chunk[1]
    if used + vim.api.nvim_strwidth(text) > room then
      text = vim.fn.strcharpart(text, 0, room - used)
    end
    fitted[#fitted + 1] = { text, chunk[2] }
    used = used + vim.api.nvim_strwidth(text)
  end
  fitted[#fitted + 1] = { (" "):rep(width - used - vim.api.nvim_strwidth(mark[1])) }
  fitted[#fitted + 1] = mark
  return fitted
end

-- A row under Terminals: a terminal, or a repo script's pane, named for its action and workspace (a
-- new-layout one's <repo>/<agent>) with the robot at the right. width: the window's.
KINDS.terminal = {
  format = function(item, width)
    local icon, hl = status.icon(item.status)
    local kind_icon, kind_hl = icons.get(item.agent_kind)
    local label = item.name
    if item.script then
      label = ("%s · %s%s"):format(item.name, item.ws_name, item.of and ("/" .. item.of) or "")
    end
    local row = { { "    " }, { icon, hl }, { " " }, { kind_icon, kind_hl }, { " " }, { label, not item.running and "Comment" or nil } }
    if isovim.show_ports and item.ports and #item.ports > 0 then
      row[#row + 1] = { "  :" .. table.concat(item.ports, " :"), "Special" }
    end
    if item.subtitle and item.subtitle ~= item.name then
      row[#row + 1] = { "  " .. item.subtitle, "Comment" }
    end
    if item.script and width then
      return with_right_mark(row, { icons.get("script") }, width)
    end
    return row
  end,
  open = KINDS.agent.open,
  delete = KINDS.agent.delete,
  id = { "host", "ws", "agent" },
}

-- What Terminals lists: terminals, and the panes repo scripts start. On another host,
-- what its `iso ls` says; hosts from before `script` was listed send their script panes as agents.
local function is_terminal(agent)
  return agent.kind == "terminal" or agent.kind == "shell" or agent.script ~= nil
end

local URGENCY = { attention = 1, unread = 2, working = 3, waiting = 4 }

-- The status a collapsed workspace shows for its agents: the one that most wants you.
local function most_urgent(agents)
  local found
  for _, agent in ipairs(agents) do
    if URGENCY[agent.status] and (not found or URGENCY[agent.status] < URGENCY[found]) then
      found = agent.status
    end
  end
  return found
end

-- An agent's tasks, in tree order: each one's subtasks right under it.
local function add_tasks(items, base, agent)
  if not isovim.show_tasks then
    return
  end
  local tasks = agent.tasks or {}
  local function under(parent, depth)
    for _, task in ipairs(tasks) do
      if task.parent == parent then
        items[#items + 1] = vim.tbl_extend("force", base, {
          kind = "task",
          agent = agent.id,
          name = agent.name,
          task = task,
          task_id = task.id,
          depth = depth,
        })
        under(task.id, depth + 1)
      end
    end
  end
  under(nil, 0)
end

-- How a repo header draws its repo, from repos.style here or from another host's `iso ls`; hosts
-- from before repos send none, and their rows keep the folder.
local function repo_mark(style)
  local hl = type(style) == "table" and type(style.glyph) == "string" and repos.highlight(style.color)
  return hl and { glyph = style.glyph, hl = hl } or nil
end

-- Surfaces (isovim.surfaces, lane L4): required once, and nil until that module exists, so the
-- Inboxes light up when it lands. Its watcher keeps M.list cheap; a hot reload stops the old
-- module's watcher before the new one starts.
local surfaces_mod
local function surfaces()
  if surfaces_mod == nil then
    local ok, mod = pcall(require, "isovim.surfaces")
    surfaces_mod = ok and type(mod) == "table" and type(mod.list) == "function" and mod or false
    if surfaces_mod and type(surfaces_mod.watch) == "function" then
      local old = rawget(_G, "isovim_surfaces_watching")
      if old and old ~= surfaces_mod and type(old.unwatch) == "function" then
        pcall(old.unwatch)
      end
      _G.isovim_surfaces_watching = surfaces_mod
      pcall(surfaces_mod.watch, function()
        require("isovim.sidebar").refresh()
      end)
    end
  end
  return surfaces_mod or nil
end
M.surfaces = surfaces

-- The keys a host's groups are under: a repo's key, "general" for general, as
-- store and isovim.surfaces name them. "_" is general's old key, which a host on an older isovim
-- still lists its agents under.
local GENERAL_KEY = store.GENERAL
local function group_key(surface_key)
  return store.canon_new(surface_key)
end

-- This host's surfaces by key, each list in the module's order.
---@return table<string, table[]>?
local function local_surfaces()
  local mod = surfaces()
  if not mod then
    return nil
  end
  local by_key = {}
  local ok, keys = pcall(function()
    return mod.repos and mod.repos() or {}
  end)
  for _, key in ipairs(ok and keys or {}) do
    local listed, list = pcall(mod.list, key)
    if listed and type(list) == "table" and #list > 0 then
      by_key[group_key(key)] = list
    end
  end
  return by_key
end

-- Another host's surfaces by key, from its `iso __surfaces`.
local function remote_surfaces(name, ssh)
  local list = remote.surfaces(name, ssh, function()
    require("isovim.sidebar").refresh()
  end)
  if not list then
    return nil
  end
  local by_key = {}
  for _, entry in ipairs(list) do
    if type(entry) == "table" and type(entry.repo) == "string" then
      local key = group_key(entry.repo)
      by_key[key] = by_key[key] or {}
      table.insert(by_key[key], entry)
    end
  end
  return by_key
end

local function waiting(list)
  local n = 0
  for _, entry in ipairs(list or {}) do
    if entry.needs_you then
      n = n + 1
    end
  end
  return n
end
M.waiting = waiting

-- The surfaces waiting on you on this host.
---@return integer
function M.inbox_count()
  local here = 0
  for _, list in pairs(local_surfaces() or {}) do
    here = here + waiting(list)
  end
  return here
end

-- A group's collapse state, per host, kept through hot reloads (isovim.collapsed). Repos and their
-- Inboxes start open; the host Inbox too.
local function collapse_key(host, what, key)
  return (host and host .. ":" or "") .. what .. (key and ":" .. key or "")
end
local function is_collapsed(host, what, key)
  return isovim.collapsed[collapse_key(host, what, key)] == true
end
local function set_collapsed(host, what, key, value)
  isovim.collapsed[collapse_key(host, what, key)] = value or nil
  isovim.remember("collapsed", isovim.collapsed)
end
M.is_collapsed, M.set_collapsed = is_collapsed, set_collapsed

local ROLE_ORDER = { root = 1, router = 2, worker = 3 }

-- One host's agents as the list groups them: each repo (legacy
-- workspaces folded under the repo their dir is a checkout of, a new-layout key under its repo),
-- then general (no repo). Each entry: {ws, agent, address, name, kind, role, parent, repo?, style?,
-- ...the row fields}.
---@return {key: string, kind: "repo"|"general", name: string, style?: table, agents: table[], spawn_ws?: string}[]
local function group(entries)
  local general = { key = GENERAL_KEY, kind = "general", name = "general", agents = {} }
  local by_repo, repo_list = {}, {}
  for _, entry in ipairs(entries) do
    local target
    if entry.repo then
      target = by_repo[entry.repo]
      if not target then
        target = { key = entry.repo, kind = "repo", name = entry.repo, style = entry.style, agents = {} }
        by_repo[entry.repo] = target
        repo_list[#repo_list + 1] = target
      end
      target.style = target.style or entry.style
    else
      target = general
    end
    table.insert(target.agents, entry)
    -- Where s spawns: the repo's new-layout key if it has one, else one of its workspaces.
    if not target.spawn_ws or (entry.v2 and not target.spawn_v2) then
      target.spawn_ws, target.spawn_v2 = entry.ws, entry.v2
    end
  end
  table.sort(repo_list, function(a, b)
    return a.name < b.name
  end)
  local groups = {}
  vim.list_extend(groups, repo_list)
  groups[#groups + 1] = general
  return groups, by_repo
end
M.group = group

-- A group's rows under its header: routers and roots, then the workers that aren't a worker's
-- (each with the size of the team behind it, which isn't listed); newest first, or most active.
local function listed_agents(agents)
  local by_address = {}
  for _, entry in ipairs(agents) do
    by_address[entry.address] = entry
  end
  local children = {}
  for _, entry in ipairs(agents) do
    if entry.parent and by_address[entry.parent] then
      children[entry.parent] = children[entry.parent] or {}
      table.insert(children[entry.parent], entry)
    end
  end
  local function team(entry, seen)
    local n = 0
    for _, child in ipairs(children[entry.address] or {}) do
      if not seen[child.address] then
        seen[child.address] = true
        n = n + 1 + team(child, seen)
      end
    end
    return n
  end
  local list = {}
  for _, entry in ipairs(agents) do
    local parent = entry.parent and by_address[entry.parent]
    if entry.role ~= "worker" or not parent or parent.role ~= "worker" then
      entry.team = entry.role == "worker" and team(entry, { [entry.address] = true }) or nil
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b)
    local ra, rb = ROLE_ORDER[a.role] or 3, ROLE_ORDER[b.role] or 3
    if ra ~= rb then
      return ra < rb
    end
    if (a.order or 0) ~= (b.order or 0) then
      return (a.order or 0) > (b.order or 0)
    end
    return a.address < b.address
  end)
  return list
end
M.listed_agents = listed_agents

-- The status a collapsed group shows for its agents: the one that most wants you.
local function group_status(agents)
  return most_urgent(agents)
end

-- How many of a group's agents run, at its header's right edge: in the working color while any
-- works, dim otherwise, nothing when none runs. Hidden ones count: they run, H only hides rows.
local function running_mark(agents)
  local n, working = 0, false
  for _, entry in ipairs(agents) do
    if entry.running then
      n = n + 1
      working = working or entry.status == "working"
    end
  end
  return n > 0 and { tostring(n), working and "DiagnosticInfo" or "Comment", right = true } or nil
end

-- Rows for the surfaces of an Inbox, one format per type (KINDS.surface).
local function surface_rows(items, base, list, depth)
  for _, entry in ipairs(list or {}) do
    items[#items + 1] = vim.tbl_extend("force", base, { kind = "surface", surface = entry, repo_key = group_key(entry.repo), name = entry.name, depth = depth })
  end
end

-- The sections a group's rows sit in, in this order: the Inbox (what needs you; questions only
-- ever here; a thread whose turn is yours too), Threads (a repo's open ones, marked while one
-- waits on you or has a reply you haven't read, then its last 5 resolved, dimmed), Surfaces
-- (the PRs, pages, write-ups), Files (file and folder surfaces, pinned paths), Root
-- (what its roots decided) and Agents. An empty one isn't shown, but for a repo's
-- Threads. The Inbox and Threads start open, the rest folded; each one's state is kept per repo and
-- host (isovim.collapsed, in the session). M.all_rows opens them all.
local FOLDED = { Surfaces = true, Files = true, Root = true, Agents = true }
local all_open = false

local function section_folded(host, key, name)
  if all_open then
    return false
  elseif name == "Inbox" then
    return is_collapsed(host, "repo_inbox", key)
  elseif FOLDED[name] then
    return not is_collapsed(host, "open_" .. name:lower(), key)
  end
  return is_collapsed(host, name:lower(), key)
end

local function set_section_folded(host, key, name, folded)
  if name == "Inbox" then
    set_collapsed(host, "repo_inbox", key, folded)
  elseif FOLDED[name] then
    set_collapsed(host, "open_" .. name:lower(), key, not folded)
  else
    set_collapsed(host, name:lower(), key, folded)
  end
end
M.set_section_folded = set_section_folded

-- A row's activity trace: this host's agents only, and only those on screen, as a jump needs none.
local function trace_of(host, entry)
  return not host and not all_open and require("isovim.activity").trace(entry.ws, entry.agent) or nil
end

-- A group's sections under its header, each child on a tree guide. threads: whether it has a
-- Threads section (a repo; General's threads, if any, are surfaces). pins: its pinned
-- paths' rows. agents: its listed agents, add_tasks: puts an agent's tasks under it.
local function group_sections(items, base, host, key, opts)
  local inbox, threads, resolved, boards, others, files = {}, {}, {}, {}, {}, {}
  local log
  for _, entry in ipairs(opts.list) do
    local kind = entry.type
    if kind == "decisions" then
      log = entry
    elseif kind == "thread" and entry.resolved then
      resolved[#resolved + 1] = opts.threads and entry or nil
      if opts.threads and entry.needs_you then
        inbox[#inbox + 1] = entry
      end
    elseif kind == "thread" and opts.threads then
      threads[#threads + 1] = entry
      if entry.needs_you then
        inbox[#inbox + 1] = entry
      end
    elseif entry.needs_you then
      inbox[#inbox + 1] = entry
    elseif kind == "file" or kind == "folder" or kind == "link" then
      files[#files + 1] = entry
    elseif kind == "prs" then
      boards[#boards + 1] = entry
    elseif kind ~= "question" and kind ~= "chat" then
      -- A page beneath another isn't a row but through its Inbox, its links and the jump picker.
      if not (kind == "page" and entry.parent and not all_open) then
        others[#others + 1] = entry
      end
    end
  end
  local function guide(i, n)
    return i == n and "└─ " or "├─ "
  end
  local function surface(entry, name, i, n, extra)
    return vim.tbl_extend("force", base, { kind = "surface", surface = entry, repo_key = group_key(entry.repo), name = entry.name, depth = 2,
      guide = guide(i, n), section = name, group_key = key }, extra or {})
  end
  if #inbox > 0 then
    local folded = section_folded(host, key, "Inbox")
    items[#items + 1] = vim.tbl_extend("force", base, { kind = "repo_inbox", repo_key = key, count = #inbox, root_mode = opts.root_mode, collapsed = folded })
    for i, entry in ipairs(folded and {} or inbox) do
      items[#items + 1] = surface(entry, "Inbox", i, #inbox, { in_inbox = true, group_key = false })
    end
  end
  local function section(name, count, children, extra)
    if count == 0 and not (extra and extra.always) then
      return
    end
    local folded = section_folded(host, key, name)
    items[#items + 1] = vim.tbl_extend("force", base, { kind = "section", section = name, repo_key = key, count = count, collapsed = folded }, extra or {})
    if not folded then
      children()
    end
  end
  -- A row per task, its threads' marks rolled up, in the order they come, then those with no thread listed but
  -- not Done; threads on no task after. The jump's list (all_open) still has every thread.
  local listed = vim.list_extend(vim.list_extend({}, threads), resolved)
  local groups, by_task, loose = {}, {}, {}
  for _, entry in ipairs(listed) do
    if entry.task then
      if not by_task[entry.task] then
        by_task[entry.task] = { id = entry.task, title = entry.task_title, repo = entry.repo, list = {} }
        groups[#groups + 1] = by_task[entry.task]
      end
      table.insert(by_task[entry.task].list, entry)
    else
      loose[#loose + 1] = entry
    end
  end
  if opts.threads and not host then
    local all = require("isovim.board_tasks").read(key)
    local ids = vim.tbl_keys(all)
    table.sort(ids, function(a, b)
      return (tonumber(a:sub(2)) or 0) > (tonumber(b:sub(2)) or 0)
    end)
    for _, id in ipairs(ids) do
      if not by_task[id] and all[id].column ~= "done" then
        by_task[id] = { id = id, title = all[id].title, repo = key, list = {} }
        groups[#groups + 1] = by_task[id]
      end
    end
  end
  section("Threads", #groups + #loose, function()
    local tops, top = #groups + #loose, 0
    local board = require("isovim.thread_board")
    for _, group in ipairs(groups) do
      top = top + 1
      local marks = {}
      for _, seg in ipairs(board.rolled_up(group.list)) do
        marks[#marks + 1] = { "  " .. seg.text, seg.marks[1] and seg.marks[1][3] }
      end
      items[#items + 1] = vim.tbl_extend("force", base, { kind = "thread_task", task_id = group.id, task_title = group.title,
        repo_key = group_key(group.repo), name = group.id, depth = 2, guide = guide(top, tops), section = "Threads", group_key = key,
        marks = marks, needs = vim.iter(group.list):any(function(entry)
          return entry.needs_you
        end) })
      for i, entry in ipairs(all_open and group.list or {}) do
        items[#items + 1] = surface(entry, "Threads", i, #group.list)
      end
    end
    for _, entry in ipairs(loose) do
      top = top + 1
      items[#items + 1] = surface(entry, "Threads", top, tops)
    end
  end, { count = #threads, always = opts.threads, unread = vim.iter(threads):any(function(entry)
    return entry.new_reply and not entry.marked_unread
  end), on_you = vim.iter(threads):any(function(entry)
    return entry.waiting_on == "user"
  end), resolved_unread = vim.iter(resolved):any(function(entry)
    return entry.resolved_unread
  end) })
  local surfaces_list = vim.list_extend(boards, others)
  section("Surfaces", #surfaces_list, function()
    for i, entry in ipairs(surfaces_list) do
      items[#items + 1] = surface(entry, "Surfaces", i, #surfaces_list)
    end
  end)
  local n_files = #files + #opts.pins
  section("Files", n_files, function()
    for i, entry in ipairs(files) do
      items[#items + 1] = surface(entry, "Files", i, n_files)
    end
    for i, pin in ipairs(opts.pins) do
      items[#items + 1] = vim.tbl_extend("force", pin, { guide = guide(#files + i, n_files), section = "Files" })
    end
  end)
  local function agent_rows(list, name, n)
    for i, entry in ipairs(list) do
      entry.group_key = key
      items[#items + 1] = vim.tbl_extend("force", entry, { kind = "agent", depth = 1, group_key = key, guide = guide(i, n), section = name, trace = trace_of(host, entry) })
      opts.add_tasks(entry)
    end
  end
  section("Root", log and 1 or 0, function()
    items[#items + 1] = surface(log, "Root", 1, 1)
  end, { count = log and log.count })
  section("Agents", #opts.agents, function()
    agent_rows(opts.agents, "Agents", #opts.agents)
  end, { running_mark = opts.running_mark })
end

-- A group's pinned paths, as rows: the files and folders its workspaces' agents pinned for you.
local function pin_rows(host, extra, key)
  local pins = {}
  for _, ws in ipairs(not host and extra and extra.workspaces_of[key] or {}) do
    for _, pin in ipairs(store.pinned(ws.id)) do
      pins[#pins + 1] = {
        kind = "path", group_key = key,
        ws = ws.id,
        ws_name = ws.name,
        path = pin.path,
        label = pin.label or short_path(ws.id, pin.path),
        is_dir = vim.fn.isdirectory(pin.path) == 1,
      }
    end
  end
  return pins
end

-- Which of a host's projects the list shows: here, the current scope or the one before it that's a
-- project (so it follows the focused tab and a restart keeps it); another host's as you left it.
local function current_project(host, keys)
  local tried = host and { isovim.host_projects[host] } or vim.list_extend({ isovim.current_scope }, isovim.recent_scopes)
  for _, name in ipairs(tried) do
    if vim.tbl_contains(keys, name) then
      return name
    end
  end
  return host and keys[1] or GENERAL_KEY
end

-- Makes key the project the list shows.
local function show_project(host, key)
  if not key then
    return
  elseif host then
    isovim.host_projects[host] = key
    isovim.remember("host_projects", isovim.host_projects)
  elseif current_project(nil, M.projects) ~= key then
    isovim.set_scope(key)
  end
end

-- One host's list and its Inbox for the list's top (a row per surface waiting on you): the
-- project switcher's row and that project's sections; with M.all_rows every
-- project's, each under a plain header. host/ssh are nil for this host. surfaces_by_key nil: no
-- surfaces module (or the host hasn't answered). terminals: its Terminals rows.
---@return table[] items, table[] inbox
local function host_rows(host, ssh, entries, surfaces_by_key, extra, terminals)
  local items, inbox = {}, {}
  local groups, by_repo = group(entries)
  if not host then
    M.local_groups = {}
    for _, g in ipairs(groups) do
      M.local_groups[g.key] = g
    end
  end
  local base_host = { host = host, ssh = ssh }
  -- Repos with surfaces but no agents still get a header.
  for key, list in pairs(surfaces_by_key or {}) do
    if key ~= GENERAL_KEY and not by_repo[key] and #list > 0 then
      local made = { key = key, kind = "repo", name = key, agents = {}, style = not host and repos.style(key) or nil }
      by_repo[key] = made
      table.insert(groups, #groups, made)
    end
  end
  -- And one made a project here with nothing in it yet (<leader>iC).
  for _, key in ipairs(not host and repos.projects() or {}) do
    if not by_repo[key] then
      local made = { key = key, kind = "repo", name = key, agents = {}, style = repos.style(key) }
      by_repo[key] = made
      table.insert(groups, #groups, made)
    end
  end
  -- Root mode, as iso rootmode set it here; another host's is guessed from its roots.
  local rootmode = not host and require("isovim.rootmode") or nil
  if surfaces_by_key then
    -- Exactly what needs you (needs_you: a question a root is still deciding has none), a row each,
    -- in the order <leader>in walks them (isovim.waiting_surfaces), as each repo's own Inbox has them
    -- too; then Unread, the open threads with only a post you haven't read.
    local waiting_on, unread = {}, {}
    for key, list in pairs(surfaces_by_key) do
      for i, entry in ipairs(list) do
        local into = entry.needs_you and waiting_on or entry.new_reply and unread
        if into then
          into[#into + 1] = { key = key, entry = entry, at = vim.list_extend(isovim.inbox_place(entry), { i }) }
        end
      end
    end
    local function by_place(a, b)
      for i = 1, 4 do
        if a.at[i] ~= b.at[i] then
          return a.at[i] < b.at[i]
        end
      end
      return false
    end
    local function add_rows(kind, list)
      for i, w in ipairs(list) do
        local key = w.key
        local mark = key == GENERAL_KEY and { icons.get("general") } or nil
        inbox[#inbox + 1] = vim.tbl_extend("force", base_host, {
          kind = kind,
          guide = i == #list and "└─ " or "├─ ",
          surface = w.entry,
          name = w.entry.name,
          repo_key = key,
          label = store.is_pseudo(key) and key or key:match("[^/]+$"),
          mark = mark and { glyph = mark[1], hl = mark[2] } or repo_mark(repos.style(key)),
        })
      end
    end
    table.sort(waiting_on, by_place)
    table.sort(unread, by_place)
    local collapsed = is_collapsed(host, "inbox")
    inbox[1] = vim.tbl_extend("force", base_host, { kind = "host_inbox", count = #waiting_on, collapsed = collapsed })
    add_rows("waiting", collapsed and {} or waiting_on)
    if #unread > 0 then
      local unread_open = is_collapsed(host, "unread_open")
      inbox[#inbox + 1] = vim.tbl_extend("force", base_host, { kind = "host_unread", count = #unread, collapsed = not unread_open })
      add_rows("unread", unread_open and unread or {})
    end
  end
  -- The projects, and how many besides the one shown have something that needs you.
  local project, others = nil, 0
  if not all_open then
    local keys = {}
    for _, g in ipairs(groups) do
      keys[#keys + 1] = g.key
    end
    keys[#keys + 1] = scope.TERMINALS
    project = current_project(host, keys)
    M.projects, M.project = keys, project
    for _, g in ipairs(groups) do
      if g.key ~= project and (waiting(surfaces_by_key and surfaces_by_key[g.key]) > 0 or vim.iter(g.agents):any(M.needs_you)) then
        others = others + 1
      end
    end
  end
  for _, g in ipairs(groups) do
    local agents = vim.tbl_filter(listed, g.agents)
    local list = surfaces_by_key and surfaces_by_key[g.key] or {}
    -- The current project always shows (General when empty, so s on it spawns a general/aN); with
    -- every project listed, those with something in them.
    if g.key == project or (all_open and (g.kind == "repo" or #agents > 0 or #list > 0 or (g.kind == "general" and not host))) then
      local collapsed = is_collapsed(host, "repo", g.key)
      items[#items + 1] = vim.tbl_extend("force", base_host, {
        kind = "repo",
        switcher = not all_open,
        others = others,
        repo_key = g.key,
        group_kind = g.kind,
        name = g.kind == "repo" and g.name or "general",
        mark = repo_mark(g.style),
        collapsed = collapsed,
        running = vim.iter(agents):any(function(entry)
          return entry.running
        end),
        status = collapsed and group_status(agents) or nil,
        waiting = waiting(list),
        ws = g.spawn_ws,
        ws_name = g.name,
        running_mark = running_mark(g.agents),
        root_mode = rootmode and rootmode.mode(g.key) or nil,
      })
      -- Its router, then its root, under the project's row whatever's folded, hidden or not; only
      -- a jump, which lists hidden agents when asked, leaves a hidden one out.
      for _, role in ipairs({ "router", "root" }) do
        for _, entry in ipairs(g.agents) do
          if entry.role == role and (not all_open or listed(entry)) then
            entry.group_key = g.key
            items[#items + 1] = vim.tbl_extend("force", entry, { kind = "agent", depth = 0, group_key = g.key, trace = trace_of(host, entry) })
            add_tasks(items, entry, { id = entry.agent, name = entry.name, tasks = entry.tasks })
          end
        end
      end
      if not collapsed then
        local root_mode = rootmode and rootmode.route(g.key) ~= nil or (not rootmode and vim.iter(agents):any(function(entry)
          return entry.role == "root"
        end))
        local function pinned(entry)
          return entry.role == "router" or entry.role == "root"
        end
        group_sections(items, base_host, host, g.key, {
          list = surfaces_by_key and list or {},
          threads = g.kind == "repo",
          pins = pin_rows(host, extra, g.key),
          agents = vim.tbl_filter(function(entry)
            return not pinned(entry)
          end, listed_agents(agents)),
          running_mark = running_mark(vim.tbl_filter(function(entry)
            return not pinned(entry)
          end, g.agents)),
          add_tasks = function(entry)
            add_tasks(items, entry, { id = entry.agent, name = entry.name, tasks = entry.tasks })
          end,
          root_mode = root_mode,
        })
        if g.kind == "general" and #agents == 0 and not host then
          items[#items + 1] = { kind = "hint", text = "no agents · s spawn" .. (#entries == 0 and " · ? keys" or ""), repo_key = GENERAL_KEY }
        end
      end
    end
  end
  if all_open or project == scope.TERMINALS then
    local collapsed = is_collapsed(host, "terminals")
    items[#items + 1] = vim.tbl_extend("force", base_host, { kind = "terminals", switcher = not all_open, others = others, count = #terminals, collapsed = collapsed,
      running_mark = running_mark(terminals) })
    vim.list_extend(items, collapsed and {} or terminals)
  end
  if host and #entries == 0 and #items <= 1 then
    items[#items + 1] = { kind = "hint", text = "no agents" }
  end
  -- The host's Inbox always has its title, even with no surfaces module to count.
  if #inbox == 0 then
    inbox[1] = vim.tbl_extend("force", base_host, { kind = "host_inbox", count = 0, collapsed = is_collapsed(host, "inbox") })
  end
  return items, inbox
end

-- This host's agents as list entries; terminals go under Terminals.
local function local_entries(workspaces)
  local titles = panes.titles()
  local entries = {}
  local workspaces_of = {}
  for _, ws in ipairs(workspaces) do
    local v2 = store.v2(ws.id)
    local repo = ws.repo or (not v2 and repos.of(ws.dir)) or nil
    local added, removed
    if not v2 then
      added, removed = diffstat.get(ws.dir, M.refresh)
    end
    for i, agent in ipairs(ws.agents) do
      local address = ws.id .. "/" .. agent.id
      local legacy_main = not v2 and (agent.id == "main" or #vim.tbl_filter(listed, ws.agents) == 1)
      entries[#entries + 1] = {
        ws = ws.id,
        ws_name = ws.name,
        agent = agent.id,
        address = address,
        name = v2 and agent.name or (legacy_main and ws.name or (ws.name .. " · " .. agent.name)),
        legacy_main = legacy_main or nil,
        agent_kind = agent.kind,
        acp = agent.acp,
        role = store.shown_role(agent),
        parent = agent.parent,
        status = agent.status,
        running = agent.running,
        hidden = agent.hidden,
        read_only = agent.read_only,
        tasks = agent.tasks,
        v2 = v2 or nil,
        repo = repo,
        style = repo and repos.style(repo) or nil,
        order = (isovim.sort == "active" and (ws.active or 0)) or agent.created or ws.created or 0,
        added = i == 1 and added or nil,
        removed = i == 1 and removed or nil,
        subtitle = agent.running and panes.subtitle(agent.kind, titles[address]) or nil,
        ports = agent.running and require("isovim.ports").of(ws.id, agent.id) or nil,
      }
    end
    local key = repo or GENERAL_KEY
    workspaces_of[key] = workspaces_of[key] or {}
    table.insert(workspaces_of[key], ws)
  end
  return entries, { workspaces_of = workspaces_of }
end

-- Another host's agent, from its row in that host's `iso ls`.
local function remote_agent(row)
  local state = row.status ~= "idle" and row.status ~= "stopped" and row.status or nil
  return { id = row.id, name = row.agent, kind = row.kind, script = row.script, status = state, running = row.status ~= "stopped", hidden = row.hidden, doing = row.doing, tasks = row.tasks }
end

-- Another host's agents as list entries, from its `iso ls`: grouped by the repo each row names.
local function remote_entries(name, ssh, rows)
  local entries = {}
  for _, row in ipairs(rows) do
    local agent = remote_agent(row)
    if not is_terminal(agent) then
      local ws_id, id = row.id:match("^(.+)/([^/]+)$")
      local repo = type(row.repo) == "table" and type(row.repo.name) == "string" and row.repo.name or nil
      local v2 = ws_id and store.v2(ws_id)
      entries[#entries + 1] = {
        host = name,
        ssh = ssh,
        ws = name .. ":" .. (ws_id or row.id),
        remote_ws = ws_id,
        ws_name = row.workspace,
        agent = row.id,
        address = row.id,
        name = v2 and row.agent or ((id == "main") and row.workspace or (row.workspace .. " · " .. row.agent)),
        agent_kind = row.kind,
        role = row.role or "worker",
        parent = row.parent,
        status = agent.status,
        running = agent.running,
        hidden = agent.hidden,
        read_only = row.read_only,
        tasks = agent.tasks,
        subtitle = agent.doing,
        v2 = v2 or nil,
        repo = repo,
        style = type(row.repo) == "table" and row.repo or nil,
        order = 0,
      }
    end
  end
  return entries
end

-- This host's Terminals rows, in the workspaces' order.
local function local_terminals(workspaces)
  local titles = panes.titles()
  local items = {}
  for _, ws in ipairs(workspaces) do
    for _, agent in ipairs(ws.terminals) do
      items[#items + 1] = {
        kind = "terminal",
        ws = ws.id,
        ws_name = ws.name,
        agent = agent.id,
        name = agent.name,
        agent_kind = agent.kind,
        script = agent.script,
        of = agent.of,
        status = agent.status,
        running = agent.running,
        subtitle = agent.running and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id]) or nil,
        ports = agent.running and require("isovim.ports").of(ws.id, agent.id) or nil,
      }
    end
  end
  return items
end

-- Another host's Terminals rows, from its `iso ls`.
local function remote_terminals(name, ssh, rows)
  local items = {}
  for _, row in ipairs(rows) do
    local agent = remote_agent(row)
    if is_terminal(agent) and (not agent.hidden or isovim.show_hidden) then
      local ws_id = row.id:match("^(.+)/[^/]+$") or row.id
      items[#items + 1] = {
        kind = "terminal",
        host = name,
        ssh = ssh,
        ws = name .. ":" .. ws_id,
        ws_name = row.workspace,
        agent = row.id,
        name = row.agent,
        agent_kind = row.kind,
        script = row.script,
        of = row.of,
        status = agent.status,
        running = agent.running,
        subtitle = row.doing,
      }
    end
  end
  return items
end

-- The hosts the list can show: this one first, then the others by name.
local function hosts()
  local names = vim.tbl_keys(remote.peers())
  table.sort(names)
  return vim.list_extend({ remote.self() }, names)
end

-- The other host the list shows, or nil for this one. In vim.g, so a hot reload keeps it.
local function shown_host()
  local name = vim.g.isovim_sidebar_host
  return name and remote.peers()[name] and name or nil
end

-- Whether some shown agent is working, so its spinner turns.
local spinning = false

-- What counts toward the style meter: a running agent that reports its state (claude, codex), an
-- ACP agent's supervisor among them.
local function is_live(agent)
  return agent.running and (agent.acp or panes.reports(agent.kind))
end
M.is_live = is_live

-- The shown host's list: its Inbox, repos, General, then Terminals with its terminals. Hidden
-- agents show only while show_hidden is on or while they need you; a hint counts the rest.
local function collect()
  isovim.mark_visible_seen()
  local sessions = panes.sessions()
  local workspaces = store.list()
  local shown = shown_host()
  local working = false
  local live = 0
  local hidden = 0
  for _, ws in ipairs(workspaces) do
    local running = sessions[ws.id] or {}
    ws.active = ws.modified
    ws.agents = {}
    ws.terminals = {}
    for _, agent in ipairs(store.agents(ws.id)) do
      agent.running = running[agent.id] ~= nil
      agent.script = scripts.of(agent)
      agent.status = status.get(ws.id, agent.id)
      -- The style meter counts agents at work, not every one with a process.
      if is_live(agent) and agent.status == "working" then
        live = live + 1
      end
      ws.active = math.max(ws.active, running[agent.id] or 0)
      -- A hidden router or root still shows, under the project's row.
      local role = store.role(agent)
      if not listed(agent) and not is_terminal(agent) and role ~= "router" and role ~= "root" then
        hidden = hidden + 1
      end
      -- Every agent goes on, as another host's do: host_rows leaves hidden ones out of the rows, not
      -- out of the running counts.
      if not is_terminal(agent) then
        ws.agents[#ws.agents + 1] = agent
      end
      if listed(agent) then
        if is_terminal(agent) then
          ws.terminals[#ws.terminals + 1] = agent
        else
          ws.running = ws.running or agent.running
        end
        working = working or (not shown and agent.status == "working")
      end
    end
  end
  local items, inbox
  local peers = remote.peers()
  for _, name in ipairs(vim.list_slice(hosts(), 2)) do
    local ssh = peers[name]
    local rows = remote.list(name, ssh, M.refresh)
    if rows then
      isovim.notify_remote(name, rows)
    end
    for _, row in ipairs(rows or {}) do
      working = working or (name == shown and remote_agent(row).status == "working")
    end
    if name == shown then
      local waiting_on = remote.down(name) and "unreachable" or not rows and "asking…"
      if waiting_on then
        items = { { kind = "hint", text = waiting_on } }
        inbox = { { kind = "hint", text = ("Inbox · %s %s"):format(name, waiting_on) } }
      else
        items, inbox = host_rows(name, ssh, remote_entries(name, ssh, rows), remote_surfaces(name, ssh), nil, remote_terminals(name, ssh, rows))
      end
    end
  end

  spinning = working
  meter.update(live)
  table.sort(workspaces, function(a, b)
    return a[isovim.sort] > b[isovim.sort]
  end)
  if not items then
    local entries, extra = local_entries(workspaces)
    items, inbox = host_rows(nil, nil, entries, local_surfaces(), extra, local_terminals(workspaces))
  end
  local list = vim.list_extend(vim.list_extend({}, inbox), items)
  -- So you know they're there.
  if not shown and hidden > 0 then
    list[#list + 1] = { kind = "hint", text = ("%d hidden · H"):format(hidden) }
  end
  return list
end

-- The column's windows by role (list, footer), found by their buffers' b:isovim_sidebar.
local function windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local role = vim.b[vim.api.nvim_win_get_buf(win)].isovim_sidebar
    if role then
      wins[role] = win
    end
  end
  return wins
end

local ns = vim.api.nvim_create_namespace("isovim_sidebar")

-- Each line is a list of {text, highlight} chunks; those with right = true are drawn at the window's
-- right edge, a space between them (virtual text, so it stays there as the width changes), not in
-- the line.
-- Cursors stay on their line numbers.
local function draw(win, chunk_lines)
  local buf = vim.api.nvim_win_get_buf(win)
  local lines, marks, rights = {}, {}, {}
  for i, chunks in ipairs(chunk_lines) do
    local text, col = {}, 0
    for _, chunk in ipairs(chunks) do
      -- A row is one line: a title or question with a newline in it (an agent's summary, a
      -- surface's question) would make nvim_buf_set_lines refuse the whole sidebar.
      local right = chunk.right
      chunk = { (tostring(chunk[1] or "")):gsub("[\r\n]+", " "), chunk[2] }
      if right then
        local line = rights[i] or { row = i - 1, chunks = {} }
        rights[i] = line
        if #line.chunks > 0 then
          line.chunks[#line.chunks + 1] = { " " }
        end
        line.chunks[#line.chunks + 1] = chunk
      else
        text[#text + 1] = chunk[1]
        if chunk[2] then
          marks[#marks + 1] = { i - 1, col, col + #chunk[1], chunk[2] }
        end
        col = col + #chunk[1]
      end
    end
    lines[i] = table.concat(text)
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  for _, right in pairs(rights) do
    vim.api.nvim_buf_set_extmark(buf, ns, right.row, 0, { virt_text = right.chunks, virt_text_pos = "right_align" })
  end
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(cursor[1], #lines)), 0 })
end

local function set_height(win, height)
  if vim.api.nvim_win_get_height(win) ~= height then
    vim.api.nvim_win_set_height(win, height)
  end
end

-- What each window's lines stand for, line by line: the actions take the one under the cursor.
local rows = { list = {}, footer = {} }

-- H, L and T show in the title as badges while they're on.
local TOGGLES = { { "show_hidden", "H" }, { "show_ports", "L" }, { "show_tasks", "T" } }

-- The column's title sits in the tab line, over the column (bufferline's offset for the sidebar's
-- filetype), so the column runs the screen's full height: the style meter, then the badges at the
-- right. A statusline string; width: the cells it has. Short of room, the badges close up, then
-- the meter's phrase is cut.
-- The tab line's title over the sidebar: the style meter and the toggles' badges, colored. Drawn
-- through M.offset_text, since bufferline cuts text by its raw length, highlight codes and all.
function M.title_colored(width)
  local on = {}
  for _, toggle in ipairs(TOGGLES) do
    if isovim[toggle[1]] then
      on[#on + 1] = toggle[2]
    end
  end
  local chunks = meter.chunks()
  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + vim.api.nvim_strwidth(chunk[1])
  end
  local badges = table.concat(on, " ")
  if #on > 0 and used + 1 + #badges > width then
    badges = table.concat(on)
  end
  local room = width - (#on > 0 and 1 + #badges or 0)
  if used > room then
    local phrase = chunks[#chunks]
    phrase[1] = vim.fn.strcharpart(phrase[1], 0, math.max(0, vim.fn.strchars(phrase[1]) - (used - room)))
    used = room
  end
  local line = {}
  for _, chunk in ipairs(chunks) do
    line[#line + 1] = "%#" .. chunk[2] .. "#" .. chunk[1]:gsub("%%", "%%%%")
  end
  return table.concat(line) .. "%#Title#" .. (" "):rep(width - used - #badges) .. badges
end

-- The same title as plain text, for a tab line set up before M.offset_text existed.
function M.title(width)
  return (M.title_colored(width):gsub("%%#[^#]*#", ""):gsub("%%%%", "%%"))
end

-- bufferline's offset text: a statusline expression whose source is padded to the width it draws.
_G.isovim_title = function(width)
  return require("isovim.sidebar").title_colored(width)
end
function M.offset_text(width)
  local call = ("%%{%%v:lua.isovim_title(%d)"):format(width)
  return call .. (" "):rep(width - #call - 2) .. "%}"
end

-- The shown host's name, with ‹ › when < and > have others to show.
local function host_bar()
  local name = shown_host() or remote.self()
  local bar = "%#Title# " .. icons.get("host") .. " " .. name:gsub("%%", "%%%%")
  if #hosts() > 1 then
    bar = "%#Comment# ‹" .. bar .. "%#Comment# ›"
  end
  return bar
end

local usage = {} ---@type table<string, {cpu: number, used: number, total: number, at: integer}|"busy"|false>
local version

-- How long ago, in its largest unit: "now", "5m", "2h", "3d".
local function age(at)
  local seconds = os.time() - at
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function footer_lines()
  local host = shown_host() or remote.self()
  local measured = usage[host]
  local first = { { "  cpu, ram: press u", "Comment" } }
  if measured == "busy" then
    first = { { "  measuring " .. host .. "…", "Comment" } }
  elseif measured == false then
    first = { { "  couldn't measure " .. host, "DiagnosticWarn" } }
  elseif measured then
    first = {
      { "  cpu " },
      { ("%d%%"):format(measured.cpu), measured.cpu >= 80 and "DiagnosticWarn" or "Special" },
      { "  ram " },
      { ("%.1f/%.0fG"):format(measured.used / 2 ^ 30, measured.total / 2 ^ 30), measured.used / measured.total >= 0.9 and "DiagnosticWarn" or "Special" },
      -- The short name, so the age fits: Mac.localdomain is Mac.
      { "  " .. host:match("^[^.]+") .. " " .. age(measured.at), "Comment" },
    }
  end
  rows.footer = { { kind = "usage" }, { kind = "settings" }, { kind = "about" } }
  local lines = {
    first,
    { { "  " }, { "\u{f013}", "Special" }, { " Settings" } }, -- fa-cog
    { { "  " }, { "ISOVIM", "Title" }, { " " .. (version or ""), "Comment" } },
  }
  -- Self-update can't pull (isovim.update): why, until it can; <CR> on it checks again.
  local blocked = require("isovim.update").blocked()
  if blocked then
    table.insert(rows.footer, { kind = "update" })
    table.insert(lines, { { "  not updating: " .. blocked, "DiagnosticWarn" } })
  end
  return lines
end

local shown_title

local function render(wins)
  -- A title window from before the title moved to the tab line, and the Inbox and Terminals windows
  -- from before they moved into the list (kept through a hot reload).
  for _, old in ipairs({ "title", "inbox", "terminals" }) do
    if wins[old] then
      pcall(vim.api.nvim_win_close, wins[old], true)
    end
  end
  local title = wins.list and M.title(vim.api.nvim_win_get_width(wins.list) - 2)
  if title ~= shown_title then
    shown_title = title
    vim.cmd.redrawtabline()
  end
  status.animate(spinning or meter.moving())
  if wins.list then
    local width = vim.api.nvim_win_get_width(wins.list)
    draw(wins.list, vim.tbl_map(function(item)
      return KINDS[item.kind].format(item, width)
    end, rows.list))
    vim.wo[wins.list].winbar = host_bar()
  end
  if wins.footer then
    local lines = footer_lines()
    draw(wins.footer, lines)
    set_height(wins.footer, #lines)
  end
end

-- The fields that keep a row of the footer through redraws (the list's are its kind's).
local ROW_ID = { footer = {} }

local function line_of(list, item, fields)
  for i, row in ipairs(list) do
    local same = row.kind == item.kind
    for _, field in ipairs(fields or KINDS[item.kind].id) do
      same = same and row[field] == item[field]
    end
    if same then
      return i
    end
  end
end

-- The list's cursor sits on what you're looking at: the agent in the focused window, or else the
-- current workspace. Left alone while you're moving around the sidebar yourself, or looking at
-- another host.
function M.follow()
  local list = windows().list
  if not list or shown_host() or isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    return
  end
  local shown = vim.api.nvim_get_current_buf()
  local agent = vim.b[shown].isovim_id == isovim.current and vim.b[shown].isovim_agent
  local target = agent and line_of(rows.list, { kind = "agent", ws = isovim.current, agent = agent })
    or (isovim.current and line_of(rows.list, { kind = "repo", repo_key = M.group_key(isovim.current) }))
  if target then
    vim.api.nvim_win_set_cursor(list, { target, 0 })
  end
end

-- Set by an action that wants the cursor on another row once the list redraws.
local keep

-- Where you last left the column (the role of its window and the row there) and the window you
-- came into it from (its buffer, whether you were typing, the cursor). Kept through hot reloads.
_G.isovim_sidebar_left = _G.isovim_sidebar_left or {}
local left = _G.isovim_sidebar_left

-- On leaving one of the column's windows (init.lua's WinLeave).
function M.remember_row()
  local role = vim.b.isovim_sidebar
  left.role, left.item = role, (rows[role] or {})[vim.api.nvim_win_get_cursor(0)[1]]
end

-- Leaving the main column for the sidebar: the window, mode and cursor <C-l> brings back.
local function leave_main()
  local win = vim.api.nvim_get_current_win()
  if not isovim.is_sidebar(win) then
    left.from = { win = win, buf = vim.api.nvim_win_get_buf(win), cursor = vim.api.nvim_win_get_cursor(win),
      insert = vim.api.nvim_get_mode().mode:match("^[it]") ~= nil }
  end
  vim.cmd.stopinsert()
end

-- Rows can shift (activity sort, the Inbox, subtitles), so a cursor keeps its row's item, not its
-- line number.
local function refresh_now()
  local wins = windows()
  if not wins.list then
    return
  end
  local wanted = keep
  local before = keep or rows.list[vim.api.nvim_win_get_cursor(wins.list)[1]]
  keep = nil
  rows.list = collect()
  render(wins)
  require("isovim.landing").refresh()
  -- The PRs surfaces open follow the PRs' cache.
  if package.loaded["isovim.surface_view"] then
    require("isovim.surface_view").refresh_boards()
  end
  -- The tab bar tidied: windows marked, no stray [No Name] tab (isovim.tabs).
  require("isovim.tabs").sync()
  if not isovim.is_sidebar(vim.api.nvim_get_current_win()) or not before then
    return M.follow()
  end
  local line = line_of(rows.list, before)
  if line then
    vim.api.nvim_win_set_cursor(wins.list, { line, 0 })
  elseif before == wanted and rows.list[1] and rows.list[1].kind == "hint" then
    -- Another host's list still on its way: the row wanted waits for it.
    keep = before
  end
end

-- The list's row kinds, line by line, for pilots.
function M.debug_kinds()
  return vim.tbl_map(function(row)
    return row.kind
  end, rows.list)
end

-- Bursts of refreshes (the poll, hooks, PR updates) run once.
local pending = false
function M.refresh()
  if pending or not windows().list then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    -- Under textlock it can't draw (E565): shortly.
    if require("isovim.safe").text_locked() then
      return M.refresh()
    end
    require("isovim.safe").wrap("the sidebar", refresh_now)()
  end, 30)
end

-- Redraws without rebuilding the rows, for the spinners. False when the column isn't open.
function M.redraw()
  local wins = windows()
  if wins.list then
    render(wins)
  end
  return wins.list ~= nil
end

-- CPU (percent busy over a second) and RAM in use and in all (bytes), on macOS or Linux.
local USAGE = [[
if [ "$(uname)" = Darwin ]; then
  cpu=$(top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { u = $3 + $5 } END { print u }')
  page=$(sysctl -n hw.pagesize)
  used=$(vm_stat | awk -v page="$page" '/Pages active|Pages wired|occupied by compressor/ { gsub(/\./, "", $NF); n += $NF } END { printf "%.0f", n * page }')
  total=$(sysctl -n hw.memsize)
else
  read -r _ a b c d e f g h _ < /proc/stat
  busy=$((a + b + c + f + g + h)) all=$((a + b + c + d + e + f + g + h))
  sleep 1
  read -r _ a b c d e f g h _ < /proc/stat
  cpu=$((100 * (a + b + c + f + g + h - busy) / (a + b + c + d + e + f + g + h - all)))
  used=$(awk '/^MemTotal/ { t = $2 } /^MemAvailable/ { a = $2 } END { printf "%.0f", (t - a) * 1024 }' /proc/meminfo)
  total=$(awk '/^MemTotal/ { printf "%.0f", $2 * 1024 }' /proc/meminfo)
fi
echo "$cpu $used $total"
]]

-- Only when asked (u): another host's is measured over ssh.
local function measure()
  local host = shown_host()
  local name = host or remote.self()
  if usage[name] == "busy" then
    return
  end
  local cmd = { "sh", "-c", USAGE }
  if host then
    local remote_cmd = vim.fn.shellescape("sh -c " .. vim.fn.shellescape(USAGE))
    cmd = { "bash", "-c", ("%s %s %s"):format(remote.ssh, vim.fn.shellescape(remote.peers()[host]), remote_cmd) }
  end
  usage[name] = "busy"
  M.redraw()
  vim.system(cmd, { text = true, timeout = 15000 }, require("isovim.safe").schedule_wrap("the CPU and RAM meter", function(result)
    local cpu, used, total = (result.stdout or ""):match("([%d.]+) (%d+) (%d+)")
    usage[name] = cpu and { cpu = tonumber(cpu), used = tonumber(used), total = tonumber(total), at = os.time() } or false
    M.redraw()
  end))
end

-- Once enforcement is on (iso cutover), the legacy layout's own ways of making things are refused,
-- as the CLI's are: a new workspace, a workspace's new agent, unarchiving. True when it refused.
function M.refuse_legacy(what)
  if not require("isovim.config").enforced() then
    return false
  end
  Snacks.notify.warn(what, { title = "isovim" })
  return true
end

local function add_agent(ws, spec)
  local agent = store.add_agent(ws, spec)
  isovim.open(ws, agent.id)
  isovim.refresh()
end

-- {key, action, description}: each window's keys, which `?` lists. COLUMN_KEYS work in all of them.
local COLUMN_KEYS = {
  { "<c-l>", "isovim_focus_chat", "back to the window you came from (<C-h> there), typing again if you were" },
  { "<", "isovim_prev_host", "the host list shows the previous host" },
  { ">", "isovim_next_host", "the host list shows the next host" },
  { "[", "isovim_prev_project", "the list shows the previous project" },
  { "]", "isovim_next_project", "the list shows the next project" },
  { "u", "isovim_usage", "measure the shown host's CPU and RAM (in the footer)" },
  { "?", "isovim_help", "this help" },
}
local LIST_KEYS = {
  { "<cr>", "isovim_open", "open the agent, terminal, surface or PR; on the project's row, its router (General's agent last open; on Terminals, collapse or expand it); on the Threads header, the thread board; on the Inbox, Root or another section (Surfaces, Files, Root, Agents), collapse or expand it; a pinned file as a tab" },
  { "<Tab>", "isovim_toggle_expand", "open or collapse the project, its Inbox or a section (from a row in one, collapse it)" },
  { "s", "isovim_spawn", "spawn a worker over ACP in its project (its worktree comes on its first edit), or in General" },
  { "D", "isovim_dismiss_thread", "the thread marked read, out of the Inbox without replying or resolving it, till the agent's next post (U does the same on one holding your attention)" },
  { "U", "isovim_toggle_read", "mark the surface, thread or agent's chat read if it's holding your attention, out of the Inbox till something new, else unread, until you open it. A waiting question, a page awaiting your reply or an agent blocked on a permission stays: it says so" },
  { "t", "isovim_new_thread", "a new thread with the project's router (isovim.threads): your first message, and the agent titles it; a post of only qqq asks for the agent's last post shorter, www for it as if you had no context" },
  { "n", "isovim_terminal", "new terminal (it opens in ~)" },
  { "r", "isovim_rename", "rename the workspace, agent, terminal or thread" },
  { "A", "isovim_attach_task", "on a thread's row, attach it to a task, picked: first a new task of its title if it's on none, or No task, taking it off, if it's on one" },
  { "d", "isovim_delete", "remove the agent, terminal, pinned path or surface (a file or folder one at once, what it names kept; one with content after y; the PRs hidden until they change; an open thread resolved, its posts kept), or archive the workspace" },
  { "R", "isovim_restart", "restart the agent (it resumes)" },
  { "m", "isovim_move", "send it to another host, picked from the peers: on the project's row, all its agents (the list follows it there); on an agent, that agent; on another host's agent, bring it here" },
  { "x", "isovim_root_mode", "root mode for the project, off to medic to sentry to off (on a surface in the Inbox, its project)" },
  { "o", "isovim_open_port", "open its dev server (the port it listens on) in the browser, an agent's or a terminal's; on a link to a PR, its view here" },
  { "c", "isovim_changes", "its changes since its base" },
  { "f", "isovim_find", "find the agent that was on something, on any host (iso find)" },
  { "S", "isovim_sort", "sort by creation or by recent activity" },
  { "H", "isovim_toggle_hidden", "show or hide hidden agents" },
  { "L", "isovim_toggle_ports", "show or hide the ports agents listen on" },
  { "E", "isovim_explorer", "file explorer (W comes back)" },
  { "C", "isovim_create_project", "make a project from a clone's dir, its glyph and color picked; on one that's set up, change them" },
  { "P", "isovim_open_prs", "the project's PRs surface" },
}
-- Keys on their way out: they still work, the first press in a session naming what replaced them.
-- {key, action, replacement, legacy}: a legacy one is refused once enforcement is on (its action
-- says so, in place of the hint).
local RETIRED_KEYS = {
  { "a", "isovim_add", "s spawns", legacy = true },
  { "A", "isovim_add_agent", "s spawns", legacy = true, on_thread = "isovim_attach_task" },
  { "b", "isovim_last_workspace", "<leader>ip" },
  { "T", "isovim_toggle_tasks", "agents' tasks are retired: threads and the thread board track work" },
}
local FOOTER_KEYS = {
  { "<cr>", "isovim_open_footer", "on Settings, open ~/.isovim/config.json as a tab; on cpu, ram, measure them; on not updating, check again" },
}
local ROLE_KEYS = { list = LIST_KEYS, footer = FOOTER_KEYS }
M.COLUMN_KEYS, M.LIST_KEYS = COLUMN_KEYS, LIST_KEYS

-- Keys that would edit, swallowed in the column's buffers where nothing else maps them: on a
-- read-only buffer they only flash an error (P, put before, did after the sidebar's P toggle went).
local SWALLOWED = { "p", "P", "i", "I", "a", "A", "o", "O", "x", "X", "d", "D", "c", "C", "s", "S", "J", "r", "R", ".", "~", "=", "<C-r>", "<Del>" }

local function map_keys(buf, role)
  local function on_row(action)
    return function()
      M.actions[action]((rows[role] or {})[vim.api.nvim_win_get_cursor(0)[1]])
    end
  end
  for _, key in ipairs(SWALLOWED) do
    vim.keymap.set("n", key, "<Nop>", { buffer = buf, nowait = true, desc = "which_key_ignore" })
  end
  for _, key in ipairs(vim.list_extend(vim.list_extend({}, COLUMN_KEYS), ROLE_KEYS[role] or {})) do
    vim.keymap.set("n", key[1], on_row(key[2]), { buffer = buf, nowait = true, desc = "isovim: " .. key[3] })
  end
  for _, key in ipairs(role == "list" and RETIRED_KEYS or {}) do
    local action = on_row(key[2])
    vim.keymap.set("n", key[1], function()
      -- On a thread's row it has a meaning of its own.
      local row = (rows[role] or {})[vim.api.nvim_win_get_cursor(0)[1]]
      if key.on_thread and row and row.kind == "surface" and row.surface and row.surface.type == "thread" then
        return M.actions[key.on_thread](row)
      end
      if not (key.legacy and require("isovim.config").enforced()) then
        require("isovim.keys").hint(key[1] .. " in the sidebar", key[3])
      end
      action()
    end, { buffer = buf, nowait = true, desc = "isovim: retiring, " .. key[3] })
  end
end

-- A float listing every isovim key, built from the tables above, the chats' and the live <leader> maps.
function M.help()
  local lines = {}
  local function section(title, keys)
    lines[#lines + 1] = "# " .. title
    for _, key in ipairs(keys) do
      lines[#lines + 1] = ("  %-17s %s"):format(key[1], key[#key])
    end
    lines[#lines + 1] = ""
  end
  section("Sidebar (any of its windows)", COLUMN_KEYS)
  section("Host list (its Inbox, the current project; a robot marks a repo script's pane)", LIST_KEYS)
  section("Footer", FOOTER_KEYS)
  section("Chat (terminal mode)", isovim.chat_keys)
  section("Chat (normal mode)", isovim.chat_normal_keys)
  local acp_keys = require("isovim.acp.chat").help_keys
  section("ACP chat", acp_keys.chat)
  section("Prompt queue (under the chat, while prompts wait)", acp_keys.queue)
  section("Composer (the chat's last lines, where you type)", acp_keys.composer)
  section("A page (comments on its lines)", require("isovim.pages").help_keys)
  section("A thread (a chat with the router about one thing)", acp_keys.thread)
  section("The agent graph (<CR> on Agents, <leader>iG)", require("isovim.agent_graph").help_keys)
  section("The board (<CR> on Threads, <leader>iO)", require("isovim.thread_board").help_keys)
  section("A task, in the board's buffer (<CR> on its card, <leader><leader>)", require("isovim.task_view").help_keys())
  section("A surface's view (markdown, a page, the PRs, a question)", {
    { "u", "mark it read if it's holding your attention, else unread until you open it again (a waiting question or a page awaiting your reply stays, and says so; a file's u is vim's undo: U on its row)" },
  })
  section("Links (iso: addresses, drawn as chips in chats, threads, pages and PRs)", {
    { "<Tab>", "on a link: open what it points at, as a tab (elsewhere, vim's jump forward)" },
    { "gf", "on a link: open it" },
    { "]l / [l", "the next or previous link, wrapping; in a chat or thread its images and waiting questions too" },
  })
  section("PRs surface (on a PR's line)", vim.tbl_map(function(key)
    return { key[1], key[2] }
  end, require("isovim.surface_view").prs_keys))
  section("PR view (one PR, read-only)", vim.tbl_map(function(key)
    return { key[1], key[2] }
  end, require("isovim.pr_view").keys))
  -- The live maps, so a key set elsewhere (the chat's own, LazyVim's ctrl+/) shows as it is; the
  -- <leader>i group under its own heading.
  local leader, group = {}, {}
  local prefix = vim.pesc(vim.g.mapleader or "\\")
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.desc and map.desc:match("^isovim: ") then
      local lhs = map.lhs:gsub("^" .. prefix, "<leader>"):gsub("^<leader>" .. prefix, "<leader><leader>")
      table.insert(vim.startswith(lhs, "<leader>i") and group or leader, { lhs, map.desc:sub(9) })
    end
  end
  for _, list in ipairs({ leader, group }) do
    table.sort(list, function(a, b)
      return a[1] < b[1]
    end)
  end
  section("Anywhere (normal mode)", leader)
  section("<leader>i: isovim", group)
  local retired = vim.tbl_map(function(key)
    return { key[1], key[3] }
  end, RETIRED_KEYS)
  for _, key in ipairs(require("isovim.keys").RETIRED) do
    retired[#retired + 1] = { "<leader>a" .. key[1], key[3] }
  end
  section(require("isovim.config").enforced() and "Retiring (since the cutover a, A, <leader>aa, <leader>an and <leader>au are refused; use instead)"
    or "Retiring (they still work for now; use instead)", retired)
  lines[#lines] = nil
  Snacks.win({
    text = lines,
    ft = "markdown",
    title = " isovim keys ",
    title_pos = "center",
    border = "rounded",
    width = math.min(80, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 4),
    wo = { wrap = false, conceallevel = 2 },
    keys = { q = "close", ["?"] = "close" },
  })
end

local function toggle(option)
  return function()
    isovim.remember(option, not isovim[option])
    M.refresh()
  end
end

local function step_host(by)
  local all = hosts()
  local at = 1
  for i, name in ipairs(all) do
    if name == (shown_host() or remote.self()) then
      at = i
    end
  end
  local name = all[(at - 1 + by) % #all + 1]
  vim.g.isovim_sidebar_host = name ~= remote.self() and name or nil
  if shown_host() then
    remote.invalidate(name)
  end
  vim.api.nvim_win_set_cursor(windows().list, { 1, 0 })
  refresh_now()
end

-- The column's windows, opened first when the explorer or nothing has the sidebar's place.
local function column()
  if not windows().list then
    local explorer = Snacks.picker.get({ source = "explorer" })[1]
    if explorer then
      explorer:close()
    end
    M.view = "workspaces"
    M.open({ enter = false })
  end
  return windows()
end

-- The list shows the project by places from the shown one ([ and ]), from anywhere, its row under
-- the cursor. It opens nothing: Enter on its row does.
function M.step_project(by)
  column()
  local all, at = M.projects, 1
  for i, name in ipairs(all) do
    if name == M.project then
      at = i
    end
  end
  local name = all[(at - 1 + by) % #all + 1]
  local host = shown_host()
  show_project(host, name)
  keep = name == scope.TERMINALS and { kind = "terminals", host = host } or { kind = "repo", host = host, repo_key = name }
  refresh_now()
end

-- The host list shows the host by places from the shown one (< and >), from anywhere.
function M.step_host(by)
  column()
  step_host(by)
end

-- Puts the list's cursor on a row of the shown host, entering the list.
local function land(want)
  local wins = column()
  refresh_now()
  if not wins.list then
    return false
  end
  vim.cmd.stopinsert()
  vim.api.nvim_set_current_win(wins.list)
  for i, row in ipairs(rows.list) do
    if want(row) then
      vim.api.nvim_win_set_cursor(wins.list, { i, 0 })
      return true
    end
  end
  return false
end

-- Every row the shown host's list can have (or, with here, this host's, whichever is shown), each
-- group open, hidden agents only with hidden: what <leader><leader> jumps to (isovim.keys.jump).
---@param hidden boolean
---@param here? boolean
function M.all_rows(hidden, here)
  local collapsed, show_hidden, shown = isovim.collapsed, isovim.show_hidden, vim.g.isovim_sidebar_host
  isovim.collapsed, isovim.show_hidden, all_open = {}, hidden, true
  if here then
    vim.g.isovim_sidebar_host = nil
  end
  local ok, list = pcall(collect)
  isovim.collapsed, isovim.show_hidden, all_open = collapsed, show_hidden, false
  vim.g.isovim_sidebar_host = shown
  return ok and list or error(list)
end

-- A row's chunks as the list draws them, at no width.
function M.row_chunks(item)
  return KINDS[item.kind].format(item)
end

-- Opens a row as <CR> on it would and puts the list's cursor on it, its group opened: the jump's
-- pick. Terminals and General have nothing to open, so the cursor only goes there (General's
-- becoming the scope, as <leader>ig does).
function M.open_row(item)
  local host = item.host
  if item.kind == "terminals" then
    return M.focus_window("terminals")
  elseif item.kind == "repo" and item.group_kind == "general" then
    require("isovim.keys").select_scope(scope.GENERAL)
  elseif KINDS[item.kind].open then
    KINDS[item.kind].open(item)
  end
  show_project(host, item.kind == "terminal" and scope.TERMINALS or item.group_key or item.repo_key)
  if item.kind == "waiting" then
    set_collapsed(host, "inbox", nil, false)
  elseif item.kind == "terminal" then
    set_collapsed(host, "terminals", nil, false)
  elseif item.group_key then
    set_collapsed(host, "repo", item.group_key, false)
    if item.section then
      set_section_folded(host, item.group_key, item.section, false)
    end
  end
  refresh_now()
  local wins = windows()
  local line = wins.list and line_of(rows.list, item)
  if line then
    vim.api.nvim_win_set_cursor(wins.list, { line, 0 })
  end
end

-- Into the list or the footer, from anywhere; "terminals" is the list on Terminals, expanded.
---@param role "list"|"footer"|"terminals"
function M.focus_window(role)
  leave_main()
  if role == "terminals" then
    local host = shown_host()
    show_project(host, scope.TERMINALS)
    if is_collapsed(host, "terminals") then
      set_collapsed(host, "terminals", nil, false)
    end
    return land(function(row)
      return row.kind == "terminals"
    end)
  end
  local win = column()[role]
  if win then
    vim.api.nvim_set_current_win(win)
  end
end

-- The list's group key a workspace (or repo key) is under: its repo, "general" for general.
function M.group_key(ws)
  local name = scope.of_workspace(ws)
  if name == scope.GENERAL then
    return GENERAL_KEY
  end
  return name
end


-- A host's repo (key) with its Inbox open, the cursor on that Inbox. host nil: this host.
function M.reveal_repo_inbox(host, key)
  if (host or nil) ~= shown_host() then
    vim.g.isovim_sidebar_host = host
    if host then
      remote.invalidate(host)
    end
  end
  show_project(host, key)
  for _, what in ipairs({ "repo", "repo_inbox" }) do
    if is_collapsed(host, what, key) then
      set_collapsed(host, what, key, false)
    end
  end
  local found = land(function(row)
    return row.kind == "repo_inbox" and row.repo_key == key
  end) or land(function(row)
    return row.kind == "repo" and row.repo_key == key
  end)
  -- Another host's list may still be on its way.
  if not found and host then
    keep = { kind = "repo_inbox", host = host, repo_key = key }
  end
end

-- Into an Inbox, expanded: the current repo's ("repo") or this host's ("host", at the list's top,
-- which then shows this host), on its first surface waiting on you; on its title when none is.
---@param which "repo"|"host"
function M.focus_inbox(which)
  local wins = column()
  vim.g.isovim_sidebar_host = nil
  if which == "host" then
    if is_collapsed(nil, "inbox") then
      set_collapsed(nil, "inbox", nil, false)
    end
    if not land(function(row)
      return row.kind == "waiting"
    end) then
      land(function(row)
        return row.kind == "host_inbox"
      end)
    end
    return
  end
  local current = isovim.current_scope
  local key = ({ [scope.GENERAL] = GENERAL_KEY })[current] or current
  if not key or current == scope.TERMINALS then
    key = isovim.current and M.group_key(isovim.current)
  end
  if not key then
    return Snacks.notify.info("No project selected", { title = "isovim" })
  end
  M.reveal_repo_inbox(nil, key)
  local here = vim.api.nvim_win_get_cursor(0)[1]
  for i = here + 1, #rows.list do
    local row = rows.list[i]
    if row.kind ~= "surface" or row.repo_key ~= key then
      break
    elseif row.surface.needs_you then
      return vim.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
end

-- Enter on a repo's header opens its router; a repo without one says so.
function M.open_router(item)
  if item.host then
    return Snacks.notify.info(("That's on %s; open its agents from their rows"):format(item.host), { title = "isovim" })
  end
  local g = M.local_groups[item.repo_key]
  for _, entry in ipairs(g and g.agents or {}) do
    if entry.role == "router" then
      return isovim.open(entry.ws, entry.agent)
    end
  end
  Snacks.notify.info(("No router in %s"):format(item.repo_key), { title = "isovim" })
end

-- A new workspace named name in dir ("" for its own dir): in a repo, a worktree of its own by
-- default, a worktree of a branch or PR, or the checkout itself.
local function new_workspace(name, dir)
  if dir == nil then
    return
  end
  dir = dir ~= "" and vim.fs.normalize(dir) or nil
  if dir and vim.fn.isdirectory(dir) == 0 then
    Snacks.notify.error(dir .. " is not a directory")
    return
  end
  local function create(worktree)
    -- Making a worktree fetches the default branch first, which can take a few seconds.
    if worktree then
      Snacks.notify.info("Making " .. name .. "'s worktree…", { title = "isovim", id = "isovim_worktree" })
      vim.cmd.redraw()
    end
    local id, err = store.create(name, dir, worktree)
    Snacks.notifier.hide("isovim_worktree")
    if not id then
      Snacks.notify.error("Could not make the worktree:\n" .. err)
      return
    end
    -- A fresh worktree runs the repo's setup script (deps, .env) in a terminal of its own.
    if worktree and require("isovim.scripts").start(id, "setup") then
      Snacks.notify.info("Running " .. name .. "'s setup script", { title = "isovim" })
    end
    isovim.open(id)
    isovim.refresh()
  end
  local worktree = require("isovim.worktree")
  if not dir or not worktree.is_repo(dir) then
    return create(false)
  end
  local choices = {
    "New worktree on " .. worktree.branch_for(name),
    "Worktree of a branch or PR…",
    "Work in " .. vim.fn.fnamemodify(dir, ":~") .. " itself",
  }
  vim.ui.select(choices, { prompt = name }, function(_, i)
    if i == 2 then
      vim.ui.input({ prompt = "Branch, or PR number or URL: " }, function(ref)
        if ref and vim.trim(ref) ~= "" then
          create(vim.trim(ref))
        end
      end)
    elseif i then
      create(i == 1)
    end
  end)
end

-- The repo a spawn from target goes to, and the clone it's made from: a repo or Inbox row's repo,
-- an agent's (a workspace's agent's, the repo its dir is a clone of), else General.
---@param target? table|string a sidebar row, or a workspace or repo key
---@return string key, string? checkout
local function spawn_target(target)
  local item = type(target) == "table" and target or { ws = target }
  if item.repo_key then
    return item.repo_key
  end
  local ws = item.ws
  if ws and store.v2(ws) then
    return ws
  end
  local project = ws and store.project(ws)
  local repo = project and require("isovim.repos").of(project)
  if repo then
    return repo, project
  end
  return item.repo or GENERAL_KEY
end

-- Spawns a worker over ACP, the next aN of the repo under the cursor (or of the shown agent; in
-- General when it's in no repo), and opens its chat, where its first prompt goes. It starts in aN/
-- and gets its worktree on its first edit.
function M.spawn(target)
  local key, checkout = spawn_target(target)
  return add_agent(key, { kind = "claude", acp = true, checkout = checkout })
end

-- The root mode goes with on a row (or, with none, on what's in focus); nil for none, as General
-- and the Inbox's title have no root.
---@param item? table a sidebar row
---@return string? repo
function M.root_mode_scope(item)
  local key
  if item then
    key = item.repo_key or item.group_key
    if not key and item.ws then
      key = M.group_key(item.ws)
    end
  else
    local current = isovim.current_scope
    if current and current ~= scope.TERMINALS then
      key = current
    elseif isovim.current then
      key = M.group_key(isovim.current)
    end
  end
  key = key and store.canon(key)
  if key and not store.is_pseudo(key) then
    return key
  end
end

-- x and <leader>ix: root mode for the scope, one step round off, medic, sentry (iso rootmode, which
-- spawns its root if it has none). It runs in the background; a toast says how it went.
---@param item? table a sidebar row, else what's in focus
function M.toggle_root_mode(item)
  if item and item.host then
    return Snacks.notify.info(("That's on %s; set root mode there"):format(item.host), { title = "isovim" })
  end
  local where = M.root_mode_scope(item)
  if not where then
    return Snacks.notify.info("Root mode is a repo's: General has no root", { title = "isovim" })
  end
  local mode = ({ medic = "sentry", sentry = "off" })[require("isovim.rootmode").mode(where)] or "medic"
  local label = where
  Snacks.notify.info(("Root mode %s for %s…"):format(mode, label), { title = "isovim" })
  vim.system({ panes.bin, "rootmode", mode, where }, { text = true }, require("isovim.safe").schedule_wrap("root mode's toggle", function(result)
    local text = vim.trim(result.code == 0 and result.stdout or (result.stderr or ""):gsub("^iso: ", ""))
    Snacks.notify(text ~= "" and text or ("root mode " .. mode .. " for " .. label),
      { title = "isovim", level = result.code == 0 and "info" or "warn" })
    M.refresh()
  end))
  return where, mode
end

M.actions = {
  isovim_open = function(item)
    return item and KINDS[item.kind].open and KINDS[item.kind].open(item)
  end,
  isovim_open_footer = function(row)
    if row and row.kind == "settings" then
      isovim.show(require("isovim.config").path)
    elseif row and row.kind == "usage" then
      measure()
    elseif row and row.kind == "update" then
      require("isovim.update").check(true)
    end
  end,
  isovim_usage = measure,
  isovim_next_project = function()
    M.step_project(1)
  end,
  isovim_prev_project = function()
    M.step_project(-1)
  end,
  isovim_next_host = function()
    step_host(1)
  end,
  isovim_prev_host = function()
    step_host(-1)
  end,
  isovim_add = function()
    if M.refuse_legacy("New workspaces were retired at the cutover: s spawns an agent in its repo") then
      return
    end
    vim.ui.input({ prompt = "New workspace: " }, function(name)
      if not name or name == "" then
        return
      end
      -- Where it works: the project you're in, then the ones workspaces used, a path, or none.
      local choices = {}
      local here = vim.fn.getcwd()
      local home = vim.fs.normalize("~")
      if here ~= home and not vim.startswith(here, store.root) then
        choices[1] = vim.fn.fnamemodify(here, ":~")
      end
      for _, project in ipairs(store.projects()) do
        if not vim.tbl_contains(choices, project) then
          choices[#choices + 1] = project
        end
      end
      local TYPE, NONE = "another dir…", "none: its own dir"
      vim.list_extend(choices, { TYPE, NONE })
      vim.ui.select(choices, { prompt = "Project for " .. name }, function(choice)
        if choice == TYPE then
          vim.ui.input({ prompt = "Project dir: ", completion = "dir" }, function(dir)
            new_workspace(name, dir)
          end)
        elseif choice == NONE then
          new_workspace(name, "")
        elseif choice then
          new_workspace(name, choice)
        end
      end)
    end)
  end,
  isovim_spawn = function(item)
    if item and item.host then
      return Snacks.notify.info(("That's on %s; spawn there"):format(item.host), { title = "isovim" })
    end
    M.spawn(item or isovim.current)
  end,
  isovim_root_mode = function(item)
    M.toggle_root_mode(item)
  end,
  isovim_add_agent = function(item)
    if M.refuse_legacy("A workspace's agents were retired at the cutover: s spawns an agent, t opens a terminal")
      or not item or not item.ws then
      return
    end
    local format = function(kind)
      return icons.get(kind) .. " " .. kind
    end
    vim.ui.select(panes.kinds, { prompt = "New agent in " .. item.ws_name, format_item = format }, function(kind)
      if kind == "command" then
        vim.ui.input({ prompt = "Command: " }, function(cmd)
          if cmd and cmd ~= "" then
            add_agent(item.ws, { kind = kind, name = cmd:match("^%S+"), cmd = cmd })
          end
        end)
      elseif kind then
        add_agent(item.ws, { kind = kind })
      end
    end)
  end,
  isovim_find = function()
    isovim.find()
  end,
  isovim_open_port = function(item)
    -- A link to a PR: its view here (Enter is its page in the browser).
    local target = item and item.surface and item.surface.type == "link" and not item.host and require("isovim.links").resolve(item.surface.address)
    if target and target.secondary then
      return target.secondary()
    elseif item and item.ws and not item.host then
      isovim.open_port(item.ws, item.agent)
    end
  end,
  isovim_changes = function(item)
    if item and item.ws and not item.host then
      isovim.changes(item.ws)
    end
  end,
  isovim_restart = function(item)
    if item and item.agent and not item.host then
      Snacks.picker.util.confirm(("Restart %s?"):format(item.name), function()
        isovim.restart(item.ws, item.agent)
        isovim.refresh()
      end)
    end
  end,
  -- t opens a new terminal, in ~, kept with the workspace under the cursor; it outlives the TUI like
  -- the agents.
  isovim_terminal = function(item)
    local ws = item and item.ws or isovim.current
    if ws then
      add_agent(ws, { kind = "terminal" })
    end
  end,
  isovim_attach_task = function(item)
    local thread = item and item.kind == "surface" and item.surface and item.surface.type == "thread" and item.surface
    if thread and not item.host then
      require("isovim.task_view").actions.thread_task(thread.repo, thread)
    end
  end,
  isovim_rename = function(item)
    -- A thread's row: its title (isovim.threads), appended to its file.
    local thread = item and item.kind == "surface" and item.surface and item.surface.type == "thread" and item.surface
    if thread and not item.host then
      return vim.ui.input({ prompt = "Rename thread: ", default = thread.title }, function(title)
        if title and title ~= "" then
          local ok, err = require("isovim.threads").rename(thread.repo, thread.name, "user", title)
          if not ok then
            return Snacks.notify.warn(tostring(err), { title = "isovim" })
          end
          require("isovim.surfaces").scan(thread.repo)
          require("isovim.surfaces").recheck()
          isovim.refresh()
        end
      end)
    elseif not item or not item.ws then
      return
    end
    -- On an agent or terminal row it renames the agent, e.g. a terminal after what runs in it; a
    -- legacy workspace's main agent goes by the workspace's name, so that's what it renames.
    if item.agent and not item.legacy_main then
      return vim.ui.input({ prompt = "Rename agent: ", default = item.name }, function(name)
        if name and name ~= "" then
          store.update_agent(item.ws, item.agent, { name = name })
          isovim.refresh()
        end
      end)
    end
    vim.ui.input({ prompt = "Rename workspace: ", default = item.ws_name }, function(name)
      if name and name ~= "" then
        store.rename(item.ws, name)
        isovim.refresh()
      end
    end)
  end,
  isovim_delete = function(item)
    local kind = item and KINDS[item.kind]
    return kind and kind.delete and kind.delete(item)
  end,
  -- m sends the row to another host, picked from the peers (iso move): on a repo's header every
  -- agent of the repo (iso move --all), on an agent's row that agent alone, on a legacy workspace
  -- the workspace. Its agents resume there. A repo that went whole is shown under that host.
  isovim_move = function(item)
    if not item or not item.ws then
      return
    elseif item.host then
      return isovim.move_here(item)
    end
    local peers = remote.peers()
    local hosts = vim.tbl_filter(function(name)
      return name ~= remote.self()
    end, vim.tbl_keys(peers))
    if #hosts == 0 then
      Snacks.notify.error("No other hosts in " .. require("isovim.config").path)
      return
    end
    local ws, name, all = item.ws, item.ws_name, false
    if store.v2(item.ws) then
      if item.kind == "repo" then
        all = true
        name = item.ws == GENERAL_KEY and "general" or item.ws
      elseif not item.agent or item.legacy_main then
        return
      else
        ws, name = item.ws .. "/" .. item.agent, item.name or (item.ws .. "/" .. item.agent)
      end
    end
    table.sort(hosts)
    vim.ui.select(hosts, { prompt = (all and "Send %s's agents to" or "Move %s to"):format(name) }, function(host)
      if not host then
        return
      end
      local function move(force)
        Snacks.notify.info(("Moving %s to %s…"):format(name, host), { title = "isovim" })
        local cmd = { panes.bin, "move", ws, peers[host], all and "--all" or (force and "--force") or nil }
        vim.system(cmd, { text = true }, require("isovim.safe").schedule_wrap("moving to a host", function(result)
          local busy = result.stderr:match("iso: (.- is working)")
          if busy then
            Snacks.picker.util.confirm(busy .. ". Move anyway?", function()
              move(true)
            end)
            return
          elseif result.code ~= 0 then
            Snacks.notify.error(vim.trim(result.stderr), { title = "isovim" })
            isovim.refresh()
            return
          end
          remote.invalidate(host)
          if all then
            local n = select(2, (result.stdout or ""):gsub(" as ", ""))
            isovim.toast(("%s moved to %s (%d agent%s)"):format(name, host, n, n == 1 and "" or "s"))
            -- Followed there: the list shows that host, the cursor on the repo once it's listed.
            vim.g.isovim_sidebar_host = host
            keep = { kind = "repo", host = host, repo_key = item.repo_key }
          else
            isovim.toast(("%s moved to %s"):format(name, host))
          end
          isovim.refresh()
        end))
      end
      move(false)
    end)
  end,
  -- Collapses or opens the repo (or Inbox) under the cursor; from a row inside one it collapses
  -- that, and the cursor goes up to its header. Kept per host through hot reloads.
  isovim_toggle_expand = function(item)
    if not item then
      return
    end
    local host = item.host
    if item.kind == "host_inbox" or item.kind == "waiting" then
      set_collapsed(host, "inbox", nil, item.kind ~= "host_inbox" or not item.collapsed)
      keep = { kind = "host_inbox", host = host }
    elseif item.kind == "host_unread" or item.kind == "unread" then
      set_collapsed(host, "unread_open", nil, item.kind == "host_unread" and item.collapsed)
      keep = { kind = "host_unread", host = host }
    elseif item.kind == "terminals" or item.kind == "terminal" then
      set_collapsed(host, "terminals", nil, item.kind ~= "terminals" or not item.collapsed)
      keep = { kind = "terminals", host = host }
    elseif item.kind == "repo_inbox" or (item.kind == "surface" and item.in_inbox) then
      set_collapsed(host, "repo_inbox", item.repo_key, item.kind == "surface" or not item.collapsed)
      keep = { kind = "repo_inbox", host = host, repo_key = item.repo_key }
    elseif item.kind == "section" then
      set_section_folded(host, item.repo_key, item.section, not item.collapsed)
      keep = { kind = "section", host = host, repo_key = item.repo_key, section = item.section }
    elseif item.section and item.group_key then
      set_section_folded(host, item.group_key, item.section, true)
      keep = { kind = "section", host = host, repo_key = item.group_key, section = item.section }
    elseif item.kind == "repo" then
      set_collapsed(host, "repo", item.repo_key, not item.collapsed)
      keep = { kind = "repo", host = host, repo_key = item.repo_key }
    elseif item.group_key then
      set_collapsed(host, "repo", item.group_key, true)
      keep = { kind = "repo", host = host, repo_key = item.group_key }
    else
      return
    end
    refresh_now()
  end,
  isovim_toggle_hidden = toggle("show_hidden"),
  -- P: the PRs surface of the row's repo, or the root's; from General, Terminals or a row of
  -- neither, the current scope's.
  isovim_create_project = function()
    require("isovim.keys").create_project()
  end,
  isovim_open_prs = function(item)
    local key = item and (item.repo_key or item.group_key or (item.ws and not item.host and M.group_key(item.ws)))
    if not key or key == GENERAL_KEY or item.kind == "terminals" or item.kind == "terminal" then
      key = nil
    end
    require("isovim.keys").prs(key)
  end,
  -- D: the row's thread marked read. U: the row's surface, thread or agent, read or unread.
  isovim_dismiss_thread = function(item)
    local thread = item and item.surface and item.surface.type == "thread" and item.surface
    if not thread then
      return vim.api.nvim_echo({ { "D takes a thread out of the Inbox", "Comment" } }, false, {})
    elseif item.host then
      return Snacks.notify.info(("That's on %s; dismiss it there"):format(item.host), { title = "isovim" })
    elseif thread.resolved and not thread.resolved_unread then
      return vim.api.nvim_echo({ { "it's resolved: it's not in the Inbox", "Comment" } }, false, {})
    end
    M.surfaces().mark_read(thread)
    M.refresh()
  end,
  isovim_toggle_read = function(item)
    if not (item and (item.surface or item.kind == "agent")) then
      return vim.api.nvim_echo({ { "U marks a surface, thread or agent's chat read or unread", "Comment" } }, false, {})
    elseif item.host then
      return Snacks.notify.info(("That's on %s; mark it there"):format(item.host), { title = "isovim" })
    elseif item.surface then
      M.surfaces().toggle_read(item.surface)
    else
      status.toggle_read(item.ws, item.agent)
    end
    M.refresh()
  end,
  -- t: a new thread in the row's repo, an agent's row's too (none in General or Terminals).
  isovim_new_thread = function(item)
    local key = item and (item.repo_key or item.group_key or (item.ws and not item.host and M.group_key(item.ws)))
    require("isovim.acp.chat").new_thread(key ~= GENERAL_KEY and key or nil)
  end,
  isovim_toggle_ports = toggle("show_ports"),
  isovim_toggle_tasks = toggle("show_tasks"),
  isovim_explorer = function()
    M.show_explorer()
  end,
  -- Back to the window you came from, typing again where you were if you were; one that shows
  -- something else since, the main window.
  isovim_focus_chat = function()
    local from = left.from
    if not (from and vim.api.nvim_win_is_valid(from.win) and vim.api.nvim_win_get_buf(from.win) == from.buf) then
      return vim.api.nvim_set_current_win(isovim.main_win())
    end
    vim.api.nvim_set_current_win(from.win)
    if from.insert then
      pcall(vim.api.nvim_win_set_cursor, from.win, from.cursor)
      vim.cmd.startinsert({ bang = from.cursor[2] >= #vim.api.nvim_get_current_line() })
    end
  end,
  isovim_last_workspace = function()
    isovim.last_workspace()
  end,
  isovim_help = function()
    M.help()
  end,
  isovim_sort = function()
    isovim.remember("sort", isovim.sort == "created" and "active" or "created")
    Snacks.notify.info("Sorted by " .. (isovim.sort == "created" and "creation time" or "recent activity"))
    M.refresh()
  end,
}

-- Another host's rows only open; changing them is that host's business.
for _, name in ipairs({ "isovim_add_agent", "isovim_terminal", "isovim_rename", "isovim_delete" }) do
  local action = M.actions[name]
  M.actions[name] = function(item)
    if item and item.host then
      return Snacks.notify.info(("That's on %s; change it there"):format(item.host), { title = "isovim" })
    end
    return action(item)
  end
end

-- What every window of the column sets: read-only, nothing in the margins, its width and buffer fixed.
local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  statuscolumn = "",
  foldcolumn = "0",
  wrap = false,
  list = false,
  spell = false,
  winbar = "",
  fillchars = "eob: ",
  winfixwidth = true,
  winfixbuf = true,
}

local function column_buffer(role)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "isovim_sidebar"
  vim.b[buf].isovim_sidebar = role
  map_keys(buf, role)
  -- The list's cursor shows what you're on wherever you are; the other windows' only in them.
  if role ~= "list" then
    vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
      buffer = buf,
      callback = function(ev)
        vim.wo.cursorline = ev.event == "WinEnter"
      end,
    })
  end
  return buf
end

-- The column on the left, top to bottom: the host list and the footer, under its title in the tab
-- line. Only the host list changes height with the screen.
---@param opts? {enter?: boolean}
function M.open(opts)
  local wins = windows()
  local made = {}
  if not wins.list then
    made.list = vim.api.nvim_open_win(column_buffer("list"), false, { split = "left", win = -1, width = 40 })
    made.footer = vim.api.nvim_open_win(column_buffer("footer"), false, { split = "below", win = made.list, height = 3 })
    wins = made
  end
  for role, win in pairs(made) do
    for option, value in pairs(WINDOW_OPTIONS) do
      vim.wo[win][option] = value
    end
    vim.wo[win].winfixheight = role ~= "list"
    vim.wo[win].cursorline = role == "list"
  end
  if not version then
    vim.system({ "git", "-C", vim.fs.dirname(panes.bin), "rev-parse", "--short", "HEAD" }, { text = true }, require("isovim.safe").schedule_wrap("the sidebar's version", function(result)
      version = result.code == 0 and vim.trim(result.stdout) or "?"
      M.redraw()
    end))
  end
  refresh_now()
  if not opts or opts.enter ~= false then
    vim.api.nvim_set_current_win(wins.list)
  end
end

function M.close()
  for _, win in pairs(windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

-- Into the sidebar: the host list, or the explorer in its place. The column's window you were last
-- in (the list at first), on the row you left there, found again by what it stands for, since rows
-- move as the list refreshes and follow() moves the list's cursor while you're away. A row that's
-- gone gives way to the agent's in the window you came from, then to its repo's.
function M.focus()
  if isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    return
  end
  leave_main()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    return explorer:focus("list")
  end
  local wins = windows()
  local role = wins[left.role] and left.role or "list"
  if not wins[role] then
    return
  end
  vim.api.nvim_set_current_win(wins[role])
  local line = left.role == role and left.item and line_of(rows[role], left.item, ROW_ID[role])
  if not line and role == "list" then
    local buf = left.from and vim.api.nvim_buf_is_valid(left.from.buf) and left.from.buf
    local ws = buf and (vim.b[buf].isovim_ws or vim.b[buf].isovim_id) or isovim.current
    local agent = buf and vim.b[buf].isovim_agent
    line = (agent and line_of(rows.list, { kind = "agent", ws = ws, agent = agent }))
      or (ws and line_of(rows.list, { kind = "repo", repo_key = M.group_key(ws) }))
  end
  if line then
    vim.api.nvim_win_set_cursor(wins[role], { line, 0 })
  end
end

-- The sidebar shows the column (W) or a file explorer rooted at the current workspace (E).
-- Opening is deferred a tick: snacks errors if a picker opens while the closed one is still resizing.
---@param opts? {cwd?: string, reveal?: string, enter?: boolean} reveal: a file to select once it's open
function M.show_explorer(opts)
  opts = opts or {}
  M.view = "explorer"
  M.close()
  local open = Snacks.picker.get({ source = "explorer" })[1]
  if open then
    open:close()
  end
  require("isovim.safe").schedule("the explorer", function()
    -- Each workspace's explorer reopens where it was left: its root (a jump, <BS>, .) and the item
    -- the cursor was on; a workspace never moved around in opens at its dir.
    local key = isovim.current or ""
    local last = type(isovim.explorer_roots[key]) == "table" and isovim.explorer_roots[key] or {}
    if last.cwd and vim.fn.isdirectory(last.cwd) == 0 then
      last = {}
    end
    local reveal = opts.reveal or (not opts.cwd and last.file and vim.uv.fs_stat(last.file) and last.file) or nil
    Snacks.explorer({
      enter = opts.enter ~= false,
      cwd = opts.cwd or last.cwd or (isovim.current and store.dir(isovim.current)) or store.workspaces,
      on_close = function(picker)
        local item = picker:current()
        isovim.explorer_roots[key] = { cwd = picker:cwd(), file = item and item.file }
        isovim.remember("explorer_roots", isovim.explorer_roots)
      end,
      actions = {
        isovim_workspaces = M.show_workspaces,
        isovim_focus_chat = M.actions.isovim_focus_chat,
      },
      win = { list = { keys = { ["W"] = "isovim_workspaces", ["<c-l>"] = "isovim_focus_chat" } } },
      on_show = reveal and function(picker)
        require("snacks.explorer.tree"):open(reveal)
        require("snacks.explorer.actions").update(picker, { target = reveal, refresh = true })
      end or nil,
    })
  end)
end

function M.show_workspaces()
  M.view = "workspaces"
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    explorer:close()
  end
  require("isovim.safe").schedule("the sidebar", M.open)
end

-- Focuses the sidebar (the column or the file explorer), or closes it when already there.
-- Reopening shows the view it had.
function M.toggle()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer and not windows().list then
    if M.view == "explorer" then
      M.show_explorer()
    else
      M.open()
    end
  elseif not isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    M.focus()
  elseif explorer then
    explorer:close()
  else
    M.close()
  end
end

-- The sidebar's file explorer, focused; from inside it, back to the column. LazyVim's own explorer
-- keys come here too, rather than opening a second explorer beside the sidebar.
function M.files()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer then
    M.show_explorer()
  elseif isovim.is_sidebar(vim.api.nvim_get_current_win()) then
    M.show_workspaces()
  else
    explorer:focus("list")
  end
end

-- After a hot reload the sidebar's keys and the explorer's actions still point at the old code.
-- The column keeps its windows and takes the new keys. The explorer reopens (its W would bring
-- back the old column), and so does the picker an isovim from before the column had; reopening
-- must not move the cursor: put back the window and mode (terminal/insert) the reload interrupted.
function M.reopen()
  local wins = windows()
  for role, win in pairs(wins) do
    map_keys(vim.api.nvim_win_get_buf(win), role)
  end
  if wins.list then
    return M.open({ enter = false })
  end
  local sidebar = Snacks.picker.get({ source = "isovim" })[1] or Snacks.picker.get({ source = "explorer" })[1]
  if not sidebar then
    return
  end
  local win = vim.api.nvim_get_current_win()
  -- Only the sidebar's own windows; a prompt you're typing in keeps the cursor.
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  local in_sidebar = ft:match("^snacks_picker") ~= nil or ft == "snacks_layout_box"
  local typing = vim.api.nvim_get_mode().mode:match("^[ti]") ~= nil
  local explorer = sidebar.opts.source == "explorer"
  sidebar:close()
  local function put_back_cursor()
    if not in_sidebar and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      if typing then
        vim.cmd.startinsert()
      end
    end
  end
  require("isovim.safe").schedule("the sidebar's close", function()
    if explorer then
      -- The old explorer saved where it was as it closed.
      isovim.explorer_roots = store.read_session().explorer_roots or {}
      M.show_explorer({ enter = in_sidebar })
      require("isovim.safe").schedule("the sidebar's close", put_back_cursor)
    else
      M.open({ enter = in_sidebar })
      put_back_cursor()
    end
  end)
end

return M
