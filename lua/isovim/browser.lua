-- Tidying isovim's Chrome (bin/iso-browser.mjs drives it): agents rarely close their tabs, and each
-- costs memory. Every ACP supervisor runs M.watch, and whichever finds the host's last sweep over
-- 5 minutes old claims the next one: it works out how each tab's owner stands, here where the
-- records and states are, and hands that to iso-browser.mjs's sweep, detached, which closes what's
-- due (a tab whose owner is gone, or one unused for browser_tab_idle while its owner isn't working)
-- and logs each to ~/.isovim/browser-tabs.log. So nothing depends on the TUI being open. Agents are
-- never touched: this is only about their tabs.
local store = require("isovim.store")

local M = {}

local EVERY = 300
local stamp = store.run .. "/browser-sweep"

-- A workspace's tabs live at run/<ws>/browser.json, ws being a repo key, a pseudo-repo, or a name
-- an agent gave --ws.
local function tab_files()
  local files = vim.fn.glob(store.run .. "/*/browser.json", false, true)
  return vim.list_extend(files, vim.fn.glob(store.run .. "/*/*/browser.json", false, true))
end

-- Every tab recorded on this host.
local function all_tabs()
  local tabs = {}
  for _, file in ipairs(tab_files()) do
    local ok, lines = pcall(vim.fn.readfile, file)
    local decoded, list = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
    if decoded and type(list) == "table" then
      vim.list_extend(tabs, list)
    end
  end
  return tabs
end

local function node(args)
  vim.system(vim.list_extend({ "node", vim.fs.dirname(require("isovim.panes").bin) .. "/iso-browser.mjs" }, args),
    { detach = true, stdin = false, stdout = false, stderr = false })
end

local function sweep()
  local owners, any = {}, false
  for _, tab in ipairs(all_tabs()) do
    any = true
    if type(tab) == "table" and type(tab.owner) == "string" and not owners[tab.owner] then
      owners[tab.owner] = require("isovim.status").owner_state(tab.owner)
    end
  end
  if any then
    node({ "sweep", vim.json.encode(next(owners) and owners or vim.empty_dict()),
      tostring(require("isovim.config").browser_tab_idle()) })
  end
end

-- Whether this process takes the next sweep: none for 5 minutes, and it got the lock to say so.
local function claim()
  local function due()
    local stat = vim.uv.fs_stat(stamp)
    return not stat or os.time() - stat.mtime.sec >= EVERY
  end
  if not due() then
    return false
  end
  local lock = stamp .. ".lock"
  if not vim.uv.fs_mkdir(lock, 448) then
    -- A holder that died: taking it takes a moment.
    local stat = vim.uv.fs_stat(lock)
    if stat and os.time() - stat.mtime.sec > 60 then
      vim.uv.fs_rmdir(lock)
    end
    return false
  end
  local mine = due()
  if mine then
    vim.fn.writefile({}, stamp)
  end
  vim.uv.fs_rmdir(lock)
  return mine
end

-- Called from a supervisor: looks once a minute, from a moment after it starts.
function M.watch()
  local tick = require("isovim.safe").schedule_wrap("the browser's sweep", function()
    if claim() then
      sweep()
    end
  end)
  assert(vim.uv.new_timer()):start(math.random(5000, 60000), 60000, tick)
end

-- A removed agent's tabs close (isovim.lifecycle), in whatever workspace it kept them. In the
-- background, as this mustn't wait on Chrome; nothing runs for an agent with none.
function M.close_agent(address)
  local has = vim.iter(all_tabs()):any(function(tab)
    return type(tab) == "table" and tab.owner == address
  end)
  if has then
    node({ "close-agent", address })
  end
end

return M
