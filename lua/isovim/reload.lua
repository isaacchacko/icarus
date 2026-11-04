-- Watches isovim's own source and swaps in new code: lua/isovim/ and every directory under it
-- (acp/, cli/), and starter/. A change under lua/isovim/ unloads every isovim module, this one
-- included, and runs setup again (init.lua's reload path re-binds the open chats, composers,
-- surface views and sidebar to the new code); one whose files don't compile keeps the old code.
-- starter/ is LazyVim's config, which lazy.nvim reads once at startup: config/keymaps.lua runs
-- again, and any other change there says to restart. A save or a git pull fires many events: they
-- are taken together, once git is done with its index. The watchers live in _G, so a reload of
-- this file closes the old ones. A reload that fails while running setup goes in errors.log and to
-- isovim's router, and tries again by itself, the files it was for still counted.
local M = {}

local lua_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local repo = vim.fs.dirname(vim.fs.dirname(lua_dir))
local ROOTS = { lua = lua_dir, starter = repo .. "/starter" }
local KEYMAPS = "lua/config/keymaps.lua"
-- Run only by the agents' supervisors (nvim -l agent_host.lua), which keep the code they started on.
local SUPERVISOR = {}
for _, name in ipairs({ "agent_host", "host", "client", "adapter", "transport", "asks", "handover", "imports", "sessions", "log" }) do
  SUPERVISOR["acp/" .. name .. ".lua"] = true
end
-- libuv's recursive watch is macOS and Windows only; inotify watches one directory.
local RECURSIVE = vim.fn.has("mac") == 1 or vim.fn.has("win32") == 1

_G.isovim_reload = _G.isovim_reload or { watchers = {}, changed = { lua = {}, starter = {} } }
local state = _G.isovim_reload

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

-- Unloads every isovim module and runs setup on the new code; on an error, the old code again.
-- files: what changed, relative to lua/isovim/ (setup draws the chats again only if their drawing did).
local function swap(files)
  local old = {}
  for name, mod in pairs(package.loaded) do
    if name == "isovim" or name:match("^isovim%.") then
      old[name] = mod
      package.loaded[name] = nil
    end
  end
  local ok, err = pcall(function()
    require("isovim").setup({ reload = true, changed = files })
  end)
  if ok then
    return true
  end
  for name in pairs(package.loaded) do
    if name == "isovim" or name:match("^isovim%.") then
      package.loaded[name] = nil
    end
  end
  for name, mod in pairs(old) do
    package.loaded[name] = mod
  end
  pcall(old.isovim.setup, { reload = true, changed = files })
  return false, err
end

-- Timers and the supervisors' pushes wait it out (isovim.safe.ticker).
local function reload(files)
  _G.isovim_reloading = true
  local ok, done, err = pcall(swap, files)
  _G.isovim_reloading = false
  if not ok then
    return false, done
  end
  return done, err
end

-- Pilots call this instead of touching files, which would reload every running isovim.
M.reload = reload

local function describe(files)
  return #files <= 4 and table.concat(files, ", ") or (#files .. " files")
end

-- Says it to isovim's router on this host, if it has one, as isovim's own message.
local function tell_router(text)
  local key = require("isovim.repos").of(repo)
  local router = key and require("isovim.store").router(key)
  local ws, id = (router or ""):match("^(.*)/([^/]+)$")
  if ws then
    require("isovim.acp").call(ws, id, "prompt", { text = text, kind = "from", message = text, publish = true })
  end
end

-- After a reload that failed: waits while you're typing, as a reload redraws what you're in.
local RETRY_MS = { 3000, 15000, 60000 }

local function retry(flush, wait)
  state.timer:start(wait, 0, require("isovim.safe").schedule_wrap("hot reload", function()
    if vim.fn.mode():match("^[icR]") then
      return retry(flush, 2000)
    end
    flush()
  end))
end

local function flush()
  if vim.uv.fs_stat(git_dir() .. "/index.lock") then
    return state.timer:start(200, 0, require("isovim.safe").schedule_wrap("hot reload", flush))
  end
  local lua_files, starter_files = vim.tbl_keys(state.changed.lua), vim.tbl_keys(state.changed.starter)
  table.sort(lua_files)
  table.sort(starter_files)
  state.changed = { lua = {}, starter = {} }
  local lines, level = {}, "info"
  if #lua_files > 0 then
    local errors = {}
    for _, rel in ipairs(lua_files) do
      local path = lua_dir .. "/" .. rel
      local _, err = loadfile(path)
      if err and vim.uv.fs_stat(path) then
        table.insert(errors, err)
      end
    end
    local ok, err = #errors == 0, table.concat(errors, "\n")
    if ok then
      ok, err = reload(lua_files)
    end
    if ok then
      table.insert(lines, "isovim reloaded: " .. describe(lua_files))
      if (state.tries or 0) > 0 then
        pcall(tell_router, ("[isovim: the TUI's hot reload worked on try %d, after failing.]"):format(state.tries + 1))
      end
      state.tries = 0
    else
      level = "error"
      table.insert(lines, "isovim reload failed, kept the old code:\n" .. err)
      require("isovim.safe").log_error("hot reload", ("%s\nfor %s"):format(err, table.concat(lua_files, ", ")))
      -- The next try is for these too, so what they changed gets redrawn. One that doesn't compile
      -- waits for its fix, and that change brings the rest along.
      for _, rel in ipairs(lua_files) do
        state.changed.lua[rel] = true
      end
      if #errors == 0 then
        state.tries = (state.tries or 0) + 1
        local wait = RETRY_MS[state.tries]
        if state.tries == 1 or not wait then
          pcall(tell_router, ("[isovim: the TUI's hot reload failed and kept the old code (%s): %s %s]")
            :format(describe(lua_files), err, wait and "It tries again by itself." or "It has stopped trying; the next change to isovim's files tries again."))
        end
        if wait then
          retry(flush, wait)
        end
      end
    end
    local supervisor = vim.tbl_filter(function(rel)
      return SUPERVISOR[rel]
    end, lua_files)
    if #supervisor > 0 then
      table.insert(lines, describe(supervisor) .. ": the agents' supervisors run it, and each restarts onto it once it's idle")
    end
  end
  local restart = {}
  -- A self-update (isovim.update) that brought it restarts onto it by itself.
  local coming = (_G.isovim_update or {}).restart ~= nil
  for _, rel in ipairs(starter_files) do
    if rel == KEYMAPS then
      local ok, err = pcall(dofile, ROOTS.starter .. "/" .. rel)
      table.insert(lines, ok and ("starter/%s ran again"):format(rel) or ("starter/%s failed: %s"):format(rel, err))
    elseif rel == "lazy-lock.json" then
      table.insert(lines, "starter/lazy-lock.json changed: " .. (coming and "isovim restores the plugins and restarts once you're idle"
        or "restart to apply (isovim restores the plugins as it starts)"))
    else
      table.insert(restart, rel)
    end
  end
  if #restart > 0 then
    table.insert(lines, ("starter/ changed (%s): %s"):format(describe(restart),
      coming and "isovim restarts onto it once you're idle" or "restart to apply"))
  end
  if #starter_files > 0 and level == "info" then
    level = "warn"
  end
  Snacks.notify(table.concat(lines, "\n"), { level = level, title = "isovim" })
end

local function changed(root_name, rel)
  local wanted = rel:match("%.lua$") or (root_name == "starter" and rel == "lazy-lock.json")
  if not wanted then
    return
  end
  state.changed[root_name][rel] = true
  state.timer:stop()
  state.timer:start(200, 0, require("isovim.safe").schedule_wrap("hot reload", flush))
end

local function watch_dir(root_name, root, dir)
  if state.watchers[dir] then
    return
  end
  local prefix = dir == root and "" or dir:sub(#root + 2) .. "/"
  local handle = assert(vim.uv.new_fs_event())
  local started = handle:start(dir, { recursive = RECURSIVE }, require("isovim.safe").schedule_wrap("hot reload's watch", function(err, name)
    if err or not name then
      return
    end
    local path = dir .. "/" .. name
    local stat = not RECURSIVE and vim.uv.fs_stat(path)
    if stat and stat.type == "directory" and not state.watchers[path] then
      -- A directory made since (a git pull's new one): watched now, and its files taken as changed,
      -- as they may have been written before its watcher started.
      watch_dir(root_name, root, path)
      for each, kind in vim.fs.dir(path, { depth = 20 }) do
        if kind == "directory" then
          watch_dir(root_name, root, path .. "/" .. each)
        else
          changed(root_name, prefix .. name .. "/" .. each)
        end
      end
      return
    end
    changed(root_name, prefix .. name)
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
  for root_name, root in pairs(ROOTS) do
    root = vim.uv.fs_realpath(root)
    if root then
      watch_dir(root_name, root, root)
      if not RECURSIVE then
        for each, kind in vim.fs.dir(root, { depth = 20 }) do
          if kind == "directory" then
            watch_dir(root_name, root, root .. "/" .. each)
          end
        end
      end
    end
  end
end

return M
