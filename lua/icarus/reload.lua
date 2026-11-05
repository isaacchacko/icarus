-- Watches icarus's own source, lua/icarus/ and the directories under it, and swaps in new code
-- without a restart: every icarus module is unloaded, this one included, and setup runs again with
-- reload = true, which binds the sidebar, home and open chats to the new code. A file that doesn't
-- compile, or a setup that fails, keeps the old code, and the next change tries again. A save or a
-- git pull fires many events: they're taken together, once git is done with its index. The watchers
-- live in _G, so a reload of this file closes the old ones.
local M = {}

local lua_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local repo = vim.fs.dirname(vim.fs.dirname(lua_dir))
-- libuv's recursive watch is macOS and Windows only; inotify watches one directory.
local RECURSIVE = vim.fn.has("mac") == 1 or vim.fn.has("win32") == 1

_G.icarus_reload = _G.icarus_reload or { watchers = {}, changed = {} }
local state = _G.icarus_reload

local function git_dir()
  local dot = repo .. "/.git"
  local stat = vim.uv.fs_stat(dot)
  if stat and stat.type == "file" then
    local file = io.open(dot)
    local dir = file and file:read("*l"):match("^gitdir: (.+)$")
    if file then
      file:close()
    end
    return dir and (dir:sub(1, 1) == "/" and dir or repo .. "/" .. dir)
  end
  return dot
end

local function icarus_module(name)
  return name == "icarus" or name:match("^icarus%.")
end

-- Unloads every icarus module and runs setup on the new code; on an error, the old code again.
local function swap()
  local old = {}
  for name, mod in pairs(package.loaded) do
    if icarus_module(name) then
      old[name], package.loaded[name] = mod, nil
    end
  end
  local ok, err = pcall(function()
    require("icarus").setup({ reload = true })
  end)
  if ok then
    return true
  end
  for name in pairs(package.loaded) do
    if icarus_module(name) then
      package.loaded[name] = nil
    end
  end
  for name, mod in pairs(old) do
    package.loaded[name] = mod
  end
  pcall(old.icarus.setup, { reload = true })
  return false, err
end

local function describe(files)
  return #files <= 4 and table.concat(files, ", ") or (#files .. " files")
end

local function flush()
  if vim.uv.fs_stat(git_dir() .. "/index.lock") then
    return state.timer:start(200, 0, vim.schedule_wrap(flush))
  end
  local files = vim.tbl_keys(state.changed)
  table.sort(files)
  state.changed = {}
  local errors = {}
  for _, rel in ipairs(files) do
    local path = lua_dir .. "/" .. rel
    local _, err = loadfile(path)
    if err and vim.uv.fs_stat(path) then
      errors[#errors + 1] = err
    end
  end
  local ok, err = #errors == 0, table.concat(errors, "\n")
  if ok then
    ok, err = swap()
  end
  if ok then
    vim.notify("icarus reloaded: " .. describe(files))
  else
    vim.notify("icarus reload failed, kept the old code:\n" .. tostring(err), vim.log.levels.ERROR)
  end
end

local function changed(rel)
  if rel:match("%.lua$") then
    state.changed[rel] = true
    state.timer:stop()
    state.timer:start(200, 0, vim.schedule_wrap(flush))
  end
end

local function watch_dir(root, dir)
  if state.watchers[dir] then
    return
  end
  local prefix = dir == root and "" or dir:sub(#root + 2) .. "/"
  local handle = assert(vim.uv.new_fs_event())
  local started = handle:start(dir, { recursive = RECURSIVE }, vim.schedule_wrap(function(err, name)
    if err or not name then
      return
    end
    local path = dir .. "/" .. name
    local stat = not RECURSIVE and vim.uv.fs_stat(path)
    if stat and stat.type == "directory" then
      -- A directory made since (a git pull's new one): watched now, and its files taken as changed,
      -- as they may have been written before its watcher started.
      watch_dir(root, path)
      for each, kind in vim.fs.dir(path, { depth = 20 }) do
        if kind == "directory" then
          watch_dir(root, path .. "/" .. each)
        else
          changed(prefix .. name .. "/" .. each)
        end
      end
      return
    end
    changed(prefix .. name)
  end))
  if started then
    state.watchers[dir] = handle
  else
    handle:close()
  end
end

function M.watch()
  for _, handle in pairs(state.watchers) do
    if not handle:is_closing() then
      handle:close()
    end
  end
  state.watchers = {}
  if state.timer and not state.timer:is_closing() then
    state.timer:close()
  end
  state.timer = assert(vim.uv.new_timer())
  local root = vim.uv.fs_realpath(lua_dir)
  watch_dir(root, root)
  if not RECURSIVE then
    for each, kind in vim.fs.dir(root, { depth = 20 }) do
      if kind == "directory" then
        watch_dir(root, root .. "/" .. each)
      end
    end
  end
end

return M
