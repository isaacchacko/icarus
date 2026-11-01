-- iso jump: a drill-down through everything isovim keeps on disk, one level at a time. The top level
-- is your config (~/.isovim), the owners under the work root (~/.iso), and the pseudo-repos Root and
-- General when they have a dir; then an owner's repos; then a repo's agents, its iso/, its config and
-- base clone; then an agent's dirs (its worktree w/). Each level starts with `.` (this dir) and `..`
-- (up a level). Picking `.` or a row with nothing below it ends the jump on that dir.
-- `iso jump` runs it in fzf (isovim.cli.lifecycle) and the shell function from `iso completion`
-- cds there; <leader>ij runs it in a picker in the TUI.
local store = require("isovim.store")
local icons = require("isovim.icons")

local M = {}

---@class isovim.JumpRow
---@field id string the row's short name, which a scripted pick matches: ".", "..", "o", "a3"
---@field path string the dir it stands for
---@field glyph string
---@field label string
---@field desc string
---@field node? isovim.JumpNode the level it opens; nil for a dir with nothing below it

---@class isovim.JumpNode
---@field path string
---@field title string
---@field rows fun(): isovim.JumpRow[]

local function lstat(path)
  return vim.uv.fs_lstat(path)
end

local function is_dir(path)
  local stat = lstat(path)
  return stat ~= nil and stat.type == "directory"
end

local function subdirs(path)
  local list = {}
  for name, kind in vim.fs.dir(path) do
    if kind == "directory" and not vim.startswith(name, ".") then
      list[#list + 1] = name
    end
  end
  table.sort(list)
  return list
end

local function number(id)
  return tonumber(id:match("^a(%d+)$"))
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function git_branch(dir)
  local result = vim.system({ "git", "-C", dir, "branch", "--show-current" }, { text = true }):wait()
  local branch = result.code == 0 and vim.trim(result.stdout) or ""
  return branch ~= "" and branch or nil
end

local function leaf(id, path, glyph, label, desc)
  return { id = id, path = path, glyph = glyph, label = label, desc = desc }
end

local agent_node

-- A repo key's level: its agents (orphan dirs too), iso/, its config and base clone.
local function repo_node(key, title)
  local dir = store.key_dir(key)
  return {
    path = dir,
    title = title or key,
    rows = function()
      local rows = {}
      local ids = vim.tbl_filter(function(name)
        return number(name) ~= nil
      end, subdirs(dir))
      table.sort(ids, function(a, b)
        return number(a) < number(b)
      end)
      for _, id in ipairs(ids) do
        local record = store.agent(key, id)
        local glyph = record and icons.agent(record) or icons.get("command")
        local desc
        if record then
          local parts = { record.role or "worker" }
          if record.name and record.name ~= id then
            parts[#parts + 1] = record.name
          end
          if record.script then
            parts[#parts + 1] = record.script .. " script" .. (record.of and (" of " .. record.of) or "")
          end
          if record.branch then
            parts[#parts + 1] = record.branch
          end
          if record.read_only then
            parts[#parts + 1] = "read-only"
          end
          desc = table.concat(parts, " · ")
        else
          desc = "no record (the reaper's)"
        end
        rows[#rows + 1] = { id = id, path = dir .. "/" .. id, glyph = glyph, label = id, desc = desc, node = agent_node(key, id) }
      end
      if is_dir(dir .. "/iso") then
        local surfaces = #vim.fn.glob(dir .. "/iso/*.surface", false, true) + #vim.fn.glob(dir .. "/iso/*.md", false, true)
        rows[#rows + 1] = leaf("iso", dir .. "/iso", icons.get("workspace"), "iso", ("isovim's files: %s, journals, transcripts"):format(plural(surfaces, "surface")))
      end
      if not store.is_pseudo(key) then
        local repos = require("isovim.repos")
        local config = repos.dir(key)
        if is_dir(config) then
          rows[#rows + 1] = leaf("config", config, "\u{f013}", "config", "the repo's config and scripts (" .. store.home_relative(config) .. ")")
        end
        if is_dir(config .. "/base-clone") then
          rows[#rows + 1] = leaf("base-clone", config .. "/base-clone", icons.get("repo"), "base-clone", "origin's default branch; read-only agents work here")
        end
      end
      return rows
    end,
  }
end

-- An agent's level: its worktree and any other dirs in aN/.
function agent_node(key, id)
  local dir = store.key_dir(key) .. "/" .. id
  local names = subdirs(dir)
  if #names == 0 then
    return nil
  end
  return {
    path = dir,
    title = key .. "/" .. id,
    rows = function()
      local rows = {}
      for _, name in ipairs(subdirs(dir)) do
        local path = dir .. "/" .. name
        -- Its worktree, by its own name (aN/w is a symlink to it), or an old one's w/.
        if name == "w" or name == store.worktree_name(key, id) then
          local branch = git_branch(path)
          rows[#rows + 1] = leaf(name, path, "\u{e725}", name, "its worktree" .. (branch and (", on " .. branch) or ""))
        else
          rows[#rows + 1] = leaf(name, path, icons.get("workspace"), name, "")
        end
      end
      return rows
    end,
  }
end

-- Whether a dir under the work root is a repo key's: it has an iso/.
local function is_key(path)
  return is_dir(path .. "/iso")
end

-- The repo keys under dir (a key's prefix, like an owner), as rows that open them; a deeper level
-- for each part of a longer key (host/group/repo).
local function group_node(prefix)
  local dir = store.work .. "/" .. prefix
  return {
    path = dir,
    title = prefix,
    rows = function()
      local rows = {}
      for _, name in ipairs(subdirs(dir)) do
        local key = store.folder_key(prefix .. "/" .. name)
        local path = dir .. "/" .. name
        if is_key(path) then
          local agents = #vim.tbl_filter(function(n)
            return number(n) ~= nil
          end, subdirs(path))
          local config = require("isovim.repos").config(key) or {}
          local glyph = type(config.glyph) == "string" and config.glyph ~= "" and config.glyph or icons.get("repo")
          rows[#rows + 1] = { id = name, path = path, glyph = glyph, label = name, desc = key .. " · " .. plural(agents, "agent"), node = repo_node(key) }
        elseif #subdirs(path) > 0 then
          rows[#rows + 1] = { id = name, path = path, glyph = icons.get("workspace"), label = name, desc = key, node = group_node(prefix .. "/" .. name) }
        end
      end
      return rows
    end,
  }
end

-- ~/.isovim: its repos' configs, and its other dirs.
local function config_node()
  local root = store.root
  return {
    path = root,
    title = "config",
    rows = function()
      local rows = {}
      local repos = root .. "/repos"
      for _, owner in ipairs(is_dir(repos) and subdirs(repos) or {}) do
        for _, name in ipairs(subdirs(repos .. "/" .. owner)) do
          local key = owner .. "/" .. name
          rows[#rows + 1] = leaf(key, repos .. "/" .. key, "\u{f013}", key, "its config and scripts")
        end
      end
      for _, name in ipairs(subdirs(root)) do
        if name ~= "repos" then
          rows[#rows + 1] = leaf(name, root .. "/" .. name, icons.get("workspace"), name, "")
        end
      end
      return rows
    end,
  }
end

-- The top: config, the owners, Root and General.
function M.top()
  local work = store.work
  return {
    path = work,
    title = "iso",
    rows = function()
      local rows = {
        { id = "config", path = store.root, glyph = "\u{f013}", label = "config", desc = "isovim's config, " .. store.home_relative(store.root), node = config_node() },
      }
      local pseudo = { root = { "root", "Root, the host root's" }, general = { "general", "General, agents in no repo" } }
      for _, name in ipairs(subdirs(work)) do
        local path = work .. "/" .. name
        local special = pseudo[name]
        if special and is_key(path) then
          rows[#rows + 1] = { id = special[1], path = path, glyph = icons.get(special[1]), label = special[1], desc = special[2], node = repo_node(name, special[1]) }
        elseif not is_key(path) and #subdirs(path) > 0 then
          local repos = #vim.tbl_filter(function(n)
            return is_key(path .. "/" .. n)
          end, subdirs(path))
          rows[#rows + 1] = { id = name, path = path, glyph = icons.get("workspace"), label = name, desc = "owner · " .. plural(repos, "repo"), node = group_node(name) }
        end
      end
      return rows
    end,
  }
end

-- A level's rows with `.` and `..` first. `..` at the top is the work root's parent dir.
---@param stack isovim.JumpNode[] the levels down to this one
---@return isovim.JumpRow[]
function M.level(stack)
  local node = stack[#stack]
  local up = stack[#stack - 1]
  local rows = {
    { id = ".", path = node.path, glyph = "\u{f07c}", label = ".", desc = "here: " .. store.home_relative(node.path) },
    { id = "..", path = up and up.path or vim.fs.dirname(node.path), glyph = "\u{f062}", label = "..",
      desc = up and ("up: " .. up.title) or store.home_relative(vim.fs.dirname(node.path)) },
  }
  vim.list_extend(rows, node.rows())
  return rows
end

-- Every row below the top, flattened, with its path from the top as its label: what `iso jump
-- <text>` searches.
---@return isovim.JumpRow[]
function M.flat()
  local list = {}
  local function walk(node, prefix, depth)
    for _, row in ipairs(node.rows()) do
      local name = prefix and (prefix .. "/" .. row.id) or row.id
      list[#list + 1] = vim.tbl_extend("force", row, { id = name, label = name })
      if row.node and depth < 6 then
        walk(row.node, name, depth + 1)
      end
    end
  end
  walk(M.top(), nil, 0)
  return list
end

-- In the TUI (<leader>ij): the same drill-down in a picker, each level its own; the dir it ends on
-- becomes the explorer's root. on_pick replaces that, for pilots.
---@param stack? isovim.JumpNode[]
function M.picker(stack, on_pick)
  stack = stack or { M.top() }
  on_pick = on_pick or M.on_pick or function(path)
    require("isovim.sidebar").show_explorer({ cwd = path })
  end
  local node = stack[#stack]
  Snacks.picker.pick({
    source = "isovim_jump",
    title = "Jump · " .. node.title,
    layout = { preset = "select" },
    items = vim.tbl_map(function(row)
      return vim.tbl_extend("force", row, { text = row.label .. " " .. (row.desc or "") })
    end, M.level(stack)),
    format = function(item)
      return { { item.glyph, "Directory" }, { " " }, { item.label }, { "  " .. (item.desc or ""), "Comment" } }
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end
      vim.schedule(function()
        if item.id == "." then
          on_pick(node.path)
        elseif item.id == ".." then
          if #stack == 1 then
            on_pick(item.path)
          else
            M.picker(vim.list_slice(stack, 1, #stack - 1), on_pick)
          end
        elseif item.node then
          M.picker(vim.list_extend(vim.list_slice(stack, 1, #stack), { item.node }), on_pick)
        else
          on_pick(item.path)
        end
      end)
    end,
  })
end

-- A row as a line for fzf: id, path, then what's shown, the glyph and label (field 3) and what it is
-- (field 4).
function M.line(row)
  return ("%s\t%s\t%s %s\t%s"):format(row.id, row.path, row.glyph, row.label, row.desc or "")
end

return M
