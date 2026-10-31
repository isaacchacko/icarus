-- Each workspace remembers its split layout: which buffers sit in which splits, their sizes and
-- the focused one. A snapshot is taken whenever the windows change while they all show the current
-- workspace, so the first buffer swap of a switch never overwrites the layout being left.
-- Kept in vim.g so hot reload keeps them, and in the workspace's layout.json (chats by agent, files
-- by path) so a fresh start, or another host after a move, rebuilds them (M.resume).
local store = require("isovim.store")

local M = {}

---@alias isovim.Layout {tree: table, focus: integer}

---@return table<string, isovim.Layout>
local function layouts()
  return vim.g.isovim_layouts or {}
end

-- winlayout() minus the sidebar and windows that belong to no workspace (the dashboard).
-- Returns false if a window shows another workspace's buffer.
local function prune(node, ws, is_sidebar)
  if node[1] == "leaf" then
    local win = node[2]
    local buf = vim.api.nvim_win_get_buf(win)
    local owner = vim.b[buf].isovim_ws
    if is_sidebar(win) or not owner then
      return nil
    end
    if owner ~= ws then
      return false
    end
    return { "leaf", { buf = buf, width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win) } }
  end
  local children = {}
  for _, child in ipairs(node[2]) do
    local kept = prune(child, ws, is_sidebar)
    if kept == false then
      return false
    end
    children[#children + 1] = kept
  end
  if #children <= 1 then
    return children[1]
  end
  return { node[1], children }
end

---@param is_sidebar fun(win: integer): boolean
function M.save(ws, is_sidebar)
  if not ws then
    return
  end
  local tree = prune(vim.fn.winlayout(), ws, is_sidebar)
  if not tree then
    return
  end
  local all = layouts()
  local focus = (all[ws] or {}).focus
  local current = vim.api.nvim_get_current_win()
  if not is_sidebar(current) and vim.b[vim.api.nvim_win_get_buf(current)].isovim_ws == ws then
    focus = vim.api.nvim_win_get_buf(current)
  end
  all[ws] = { tree = tree, focus = focus }
  vim.g.isovim_layouts = all
  M.persist(ws, tree, focus)
end

-- A buffer as layout.json names it: an agent's chat, or a file, relative to the workspace's dir
-- when in it, so the layout survives a move to another host or a recreated worktree.
local function describe(buf, root)
  if vim.b[buf].isovim_id then
    return { agent = vim.b[buf].isovim_agent or "main" }
  elseif vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
    local file = vim.api.nvim_buf_get_name(buf)
    if vim.startswith(file, root .. "/") then
      return { path = file:sub(#root + 2) }
    end
    return { file = file }
  end
end

local function to_disk(node, focus, root)
  if node[1] == "leaf" then
    local leaf = describe(node[2].buf, root)
    if leaf then
      leaf.width, leaf.height, leaf.focus = node[2].width, node[2].height, node[2].buf == focus or nil
      return { "leaf", leaf }
    end
    return nil
  end
  local children = {}
  for _, child in ipairs(node[2]) do
    children[#children + 1] = to_disk(child, focus, root)
  end
  if #children <= 1 then
    return children[1]
  end
  return { node[1], children }
end

local written = {} ---@type table<string, string>

function M.persist(ws, tree, focus)
  local disk = to_disk(tree, focus, vim.uv.fs_realpath(store.dir(ws)) or store.dir(ws))
  local json = disk and vim.json.encode(disk) or nil
  if json and json ~= written[ws] and vim.uv.fs_stat(store.path(ws)) then
    written[ws] = json
    vim.fn.writefile({ json }, store.path(ws) .. "/layout.json")
  end
end

-- Drops leaves whose buffer is gone, e.g. a removed agent's chat.
local function alive(node)
  if node[1] == "leaf" then
    return vim.api.nvim_buf_is_valid(node[2].buf) and node or nil
  end
  local children = vim.tbl_filter(function(child)
    return child ~= nil
  end, vim.tbl_map(alive, node[2]))
  if #children <= 1 then
    return children[1]
  end
  return { node[1], children }
end

local function first_buf(node)
  return node[1] == "leaf" and node[2].buf or first_buf(node[2][1])
end

-- Lays node out in win: splits it once per extra child, then recurses into each part.
local function build(node, win, leaves)
  if node[1] == "leaf" then
    vim.api.nvim_win_set_buf(win, node[2].buf)
    leaves[#leaves + 1] = { win = win, spec = node[2] }
    return
  end
  local wins, last = { win }, win
  for i = 2, #node[2] do
    last = vim.api.nvim_open_win(first_buf(node[2][i]), false, { split = node[1] == "row" and "right" or "below", win = last })
    wins[i] = last
  end
  for i, child in ipairs(node[2]) do
    build(child, wins[i], leaves)
  end
end

-- Rebuilds ws's layout in the editing area. want is a buffer that must end up on screen (the chat
-- being opened); it takes the focused split if the layout doesn't already show it.
---@param is_sidebar fun(win: integer): boolean
function M.restore(ws, is_sidebar, want)
  local saved = layouts()[ws]
  local tree = saved and alive(saved.tree)
  if not tree then
    return false
  end
  local current = vim.api.nvim_get_current_win()
  local wins = vim.tbl_filter(function(win)
    return not is_sidebar(win)
  end, vim.api.nvim_tabpage_list_wins(0))
  local keep = vim.tbl_contains(wins, current) and current or wins[1]
  if not keep then
    return
  end
  for _, win in ipairs(wins) do
    if win ~= keep then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  local leaves = {}
  build(tree, keep, leaves)
  for _, leaf in ipairs(leaves) do
    pcall(vim.api.nvim_win_set_width, leaf.win, leaf.spec.width)
    pcall(vim.api.nvim_win_set_height, leaf.win, leaf.spec.height)
  end
  local focus_win, want_win
  for _, leaf in ipairs(leaves) do
    if leaf.spec.buf == saved.focus then
      focus_win = leaf.win
    end
    if leaf.spec.buf == want then
      want_win = leaf.win
    end
  end
  focus_win = focus_win or leaves[1].win
  if want and vim.api.nvim_buf_is_valid(want) and not want_win then
    vim.api.nvim_win_set_buf(focus_win, want)
    want_win = focus_win
  end
  if not is_sidebar(current) then
    vim.api.nvim_set_current_win(want_win or focus_win)
  end
  return true
end

-- Rebuilds ws's layout.json around the editing area: open(win, leaf) puts each leaf's chat or
-- file in its window. False when there is nothing to rebuild.
---@param is_sidebar fun(win: integer): boolean
---@param open fun(win: integer, leaf: {agent?: string, file?: string}) (path leaves come as file)
---@param want? integer a buffer that must end up on screen, as in M.restore
function M.resume(ws, is_sidebar, open, want)
  local ok, lines = pcall(vim.fn.readfile, store.path(ws) .. "/layout.json")
  local decoded, tree = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  if not decoded or type(tree) ~= "table" then
    return false
  end
  local wins = vim.tbl_filter(function(win)
    return not is_sidebar(win)
  end, vim.api.nvim_tabpage_list_wins(0))
  local keep = wins[1]
  if not keep then
    return false
  end
  for _, win in ipairs(wins) do
    if win ~= keep then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  -- Windows first, around a placeholder; then each one gets its chat or file.
  local placeholder = vim.api.nvim_create_buf(false, true)
  local function placed(node)
    if node[1] == "leaf" then
      return { "leaf", vim.tbl_extend("force", node[2], { buf = placeholder }) }
    end
    return { node[1], vim.tbl_map(placed, node[2]) }
  end
  local leaves = {}
  build(placed(tree), keep, leaves)
  local focus
  for _, leaf in ipairs(leaves) do
    if leaf.spec.path then
      leaf.spec.file = store.dir(ws) .. "/" .. leaf.spec.path
    end
    pcall(open, leaf.win, leaf.spec)
    if leaf.spec.focus then
      focus = leaf.win
    end
  end
  for _, leaf in ipairs(leaves) do
    pcall(vim.api.nvim_win_set_width, leaf.win, leaf.spec.width)
    pcall(vim.api.nvim_win_set_height, leaf.win, leaf.spec.height)
  end
  if want and vim.api.nvim_buf_is_valid(want) and vim.fn.bufwinid(want) == -1 then
    vim.api.nvim_win_set_buf(focus or leaves[1].win, want)
  end
  if focus and vim.api.nvim_win_is_valid(focus) then
    vim.api.nvim_set_current_win(focus)
  end
  if vim.api.nvim_buf_is_valid(placeholder) and vim.fn.bufwinid(placeholder) == -1 then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  return true
end

return M
