-- What a restart onto an update (isovim.update) brings back: every open view, in its project, the
-- tab bar as it was. Most become stubs: a listed, empty buffer that draws its tab and builds nothing,
-- so a restart costs the same with fifty tabs as with one (a chat's journal runs to tens of MB, a PR's
-- view fetches), and a chat you haven't looked at stays unread. Shown in a window, however that
-- happens (its tab, <S-h>, <leader>,), a stub opens its view there, by its kind, and goes; a view
-- that opens some other way (its sidebar row, a chip) takes its stub's place. Only the view on
-- screen opens at start. A view whose thing has gone since isn't brought back.
local store = require("isovim.store")

local M = {}

local GROUP = vim.api.nvim_create_augroup("isovim_restore", { clear = true })

local function stub_name(key)
  return "isovim-restored://" .. vim.fn.sha256(key):sub(1, 16)
end

-- What buf is a view of, as restart.json keeps it; nil for what can't come back (a question being
-- written, a thread not started yet).
local function describe(buf)
  local tabs = require("isovim.tabs")
  local key, scope_name = tabs.view_key(buf), vim.b[buf].isovim_scope
  if vim.b[buf].isovim_restored then
    return vim.b[buf].isovim_restored
  elseif not key or not scope_name then
    return nil
  end
  local view
  local ws, agent = tabs.agent_of(buf)
  local surface = vim.b[buf].isovim_surface
  if ws then
    view = { kind = "agent", ws = ws, agent = agent, label = vim.b[buf].isovim_agent_name or agent }
  elseif vim.b[buf].isovim_pr then
    view = { kind = "pr", repo = scope_name, url = vim.b[buf].isovim_pr }
  elseif vim.b[buf].isovim_agent_kind == "thread" then
    local repo, id = surface:match("^(.*)/(t%d+)$")
    view = id and { kind = "thread", repo = repo, id = id }
  elseif surface then
    local shown = require("isovim.surface_view").views[surface]
    view = shown and { kind = "surface", repo = shown.repo, name = shown.name, task = shown.task_open }
  else
    view = { kind = "file", path = key }
  end
  if not view then
    return nil
  end
  view.key, view.scope = key, scope_name
  view.label = view.label or tabs.name(buf) or vim.fn.fnamemodify(key, ":t")
  view.icon, view.hl = tabs.icon(vim.api.nvim_buf_get_name(buf))
  local chat = vim.b[buf].isovim_acp and require("isovim.acp.chat").of_buf(buf)
  if chat and chat.lines then
    local lines = require("isovim.acp.chat").draft(chat)
    if vim.trim(table.concat(lines, "\n")) ~= "" then
      view.draft = lines
    end
  end
  return view
end

-- What a restart keeps: the open views in buffer order (the tab bar's sort does the rest), the one on
-- screen and where it was scrolled, and how many windows you edit in.
---@return table
function M.snapshot()
  local isovim, tabs = require("isovim"), require("isovim.tabs")
  local views = {}
  for _, info in ipairs(vim.fn.getbufinfo()) do
    local view = info.loaded == 1 and tabs.owner(info.bufnr) == info.bufnr and describe(info.bufnr)
    if view then
      views[#views + 1] = view
    end
  end
  local current = vim.api.nvim_get_current_win()
  local in_sidebar = isovim.is_sidebar(current)
  local win = in_sidebar and isovim.main_win() or current
  local on_screen = tabs.owner(vim.api.nvim_win_get_buf(win))
  local plain = not vim.b[on_screen].isovim_acp
  return {
    views = views,
    view = tabs.view_key(on_screen),
    pos = plain and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil,
    windows = #tabs.editing_windows(),
    sidebar = in_sidebar,
  }
end

-- The surface a view shows as it is now; nil when it's gone. The PRs surface, the board and the
-- decision log aren't files in iso/.
local function surface_entry(view)
  local surfaces = require("isovim.surfaces")
  local own = ({ PRs = surfaces.prs_entry, Threads = surfaces.threads_entry, Decisions = surfaces.decisions_entry })[view.name]
  if own then
    return own(view.repo, true)
  end
  return surfaces.get(view.repo, view.name)
end

-- Whether what a view shows is still there, without building it. names: a repo's surfaces, read once.
local function stands(view, names)
  if view.kind == "agent" then
    return store.agent(view.ws, view.agent) ~= nil
  elseif view.kind == "thread" then
    return vim.uv.fs_stat(require("isovim.threads").file(view.repo, view.id)) ~= nil
  elseif view.kind == "file" then
    return vim.uv.fs_stat(view.path) ~= nil
  elseif view.kind == "pr" then
    return true
  elseif view.name == "PRs" or view.name == "Threads" or view.name == "Decisions" then
    return true
  end
  if not names[view.repo] then
    names[view.repo] = {}
    for _, entry in ipairs(require("isovim.surfaces").read(view.repo)) do
      names[view.repo][entry.name] = true
    end
  end
  return names[view.repo][view.name] == true
end

local function make_stub(view)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  pcall(vim.api.nvim_buf_set_name, buf, stub_name(view.key))
  vim.bo[buf].modifiable = false
  vim.b[buf].isovim_restored = view
  vim.b[buf].isovim_scope = view.scope
  local icon, hl = view.icon, view.hl
  if view.kind == "file" then
    -- Its own buffer now, unlisted, so opened it keeps its place among the file tabs, which sort by
    -- buffer number.
    vim.fn.bufadd(view.path)
    local ok, icons = pcall(require, "mini.icons")
    if ok then
      icon, hl = icons.get("file", view.path)
    end
  elseif view.kind == "agent" then
    vim.b[buf].isovim_agent_name = view.label
  else
    vim.b[buf].isovim_surface = view.key
  end
  vim.b[buf].isovim_tab = { name = view.label, icon = icon, hl = hl }
end

-- A stub for each saved view still there. Returns which came back, by key.
---@return table<string, table>
function M.stubs(saved)
  local back, names = {}, {}
  for _, view in ipairs(saved.views or {}) do
    if stands(view, names) then
      make_stub(view)
      back[view.key] = view
    end
  end
  return back
end

-- Opens a view by its kind, in win, as its sidebar row or chip does, and gives it back its draft.
local function open(view, win)
  local isovim = require("isovim")
  vim.api.nvim_set_current_win(win)
  if view.kind == "agent" then
    isovim.open(view.ws, view.agent, win)
  elseif view.kind == "thread" then
    require("isovim.acp.chat").open_thread(view.repo, view.id)
  elseif view.kind == "pr" then
    require("isovim.pr_view").open(view.repo, view.url)
  elseif view.kind == "file" then
    vim.b[vim.fn.bufadd(view.path)].isovim_scope = view.scope
    -- A file another nvim has open opens read-only, rather than ask where nothing can answer.
    local swap = vim.api.nvim_create_autocmd("SwapExists", {
      callback = function()
        vim.v.swapchoice = "o"
      end,
    })
    pcall(isovim.show, view.path)
    vim.api.nvim_del_autocmd(swap)
  elseif view.task and require("isovim.board_tasks").read(view.repo)[view.task] then
    require("isovim.thread_board").open_task(view.repo, view.task)
  else
    local entry = surface_entry(view)
    if not entry then
      return false
    end
    require("isovim.surfaces").open(entry)
  end
  if view.draft then
    local chat = require("isovim.acp.chat")
    local opened = chat.get(view.ws or view.repo, view.agent or ("thread:" .. tostring(view.id)))
    if opened then
      chat.set_draft(opened, view.draft)
    end
  end
  vim.cmd.stopinsert()
  return true
end

local function open_stub(buf)
  local win = vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) or -1
  -- In a queue's or an input box's window: isovim.tabs is moving it to the main one.
  if win == -1 or vim.w[win].isovim_slot then
    return
  end
  local view = vim.b[buf].isovim_restored
  if not open(view, win) then
    vim.notify("isovim: " .. view.label .. " is gone")
    require("isovim.tabs").bufdelete(buf)
  end
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = GROUP,
  callback = require("isovim.safe").wrap("a restored tab", function(ev)
    if vim.b[ev.buf].isovim_restored then
      return require("isovim.safe").schedule("opening a restored tab", function()
        open_stub(ev.buf)
      end)
    end
    local key = require("isovim.tabs").view_key(ev.buf)
    local stub = key and vim.fn.bufnr(stub_name(key)) or -1
    if stub > 0 and #vim.fn.win_findbuf(stub) == 0 then
      pcall(vim.api.nvim_buf_delete, stub, { force = true })
    end
  end),
})

-- The view on screen, in the window you're in, as it was; the drafts of chats that opened by other
-- means (the layout's splits).
function M.finish(saved, back)
  local isovim, tabs = require("isovim"), require("isovim.tabs")
  local current = vim.api.nvim_get_current_win()
  local win = isovim.is_sidebar(current) and isovim.main_win() or current
  local view = back[saved.view]
  if view and tabs.view_key(vim.api.nvim_win_get_buf(win)) ~= saved.view then
    open(view, win)
  end
  for _, each in pairs(back) do
    local chat = require("isovim.acp.chat")
    local opened = each.draft and chat.get(each.ws or each.repo, each.agent or ("thread:" .. tostring(each.id)))
    if opened and vim.fn.bufnr(stub_name(each.key)) == -1 then
      chat.set_draft(opened, each.draft)
    end
  end
  if saved.pos then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(saved.pos)
    end)
  end
end

return M
