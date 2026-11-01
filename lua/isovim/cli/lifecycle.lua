-- iso jump, iso reap and iso sync: getting around what isovim keeps (isovim.jump), the reaper
-- (isovim.lifecycle) and config sync to the other hosts (isovim.sync).
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local flag = c.flag

local commands = {}

-- Runs fzf (ISOVIM_FZF stands in for it in pilots) on rows; the row picked, or nil when it was
-- cancelled. fzf draws on the terminal itself, so its output can be captured.
local function pick(rows, prompt, query)
  local jump = require("isovim.jump")
  local input, output = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.writefile(vim.tbl_map(jump.line, rows), input)
  local cmd = { vim.env.ISOVIM_FZF or "fzf", "--delimiter", "\t", "--with-nth", "3..", "--no-sort", "--layout", "reverse",
    "--height", "~60%", "--prompt", prompt .. " > " }
  if query then
    -- A search matches where a row is, not what it says, as filter does.
    vim.list_extend(cmd, { "--nth", "1", "--query", query, "--select-1" })
  end
  local line = table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ")
  os.execute(("%s < %s > %s"):format(line, vim.fn.shellescape(input), vim.fn.shellescape(output)))
  local ok, lines = pcall(vim.fn.readfile, output)
  vim.fn.delete(input)
  vim.fn.delete(output)
  local id = ok and lines[1] and lines[1]:match("^([^\t]*)\t")
  if not id then
    return nil
  end
  return vim.iter(rows):find(function(row)
    return row.id == id
  end)
end

-- The rows fzf --filter keeps for text, as a search with no screen.
local function filter(rows, text)
  local jump = require("isovim.jump")
  local result = vim.system({ "fzf", "--delimiter", "\t", "--with-nth", "3..", "--nth", "1", "--filter", text },
    { stdin = table.concat(vim.tbl_map(jump.line, rows), "\n") .. "\n", text = true }):wait()
  local kept = {}
  for line in vim.gsplit(result.stdout or "", "\n", { plain = true, trimempty = true }) do
    local id = line:match("^([^\t]*)\t")
    kept[#kept + 1] = id and vim.iter(rows):find(function(row)
      return row.id == id
    end) or nil
  end
  return kept
end

-- The dir picked, printed. With text: a search of every level at once, which jumps straight to the
-- one match; else the drill-down from the top.
local function jump(args)
  local lifejump = require("isovim.jump")
  if vim.fn.executable(vim.env.ISOVIM_FZF or "fzf") == 0 then
    fail("iso jump needs fzf on PATH")
  end
  local text = table.concat(args, " ")
  if text ~= "" then
    local rows = lifejump.flat()
    local matches = filter(rows, text)
    if #matches == 0 then
      fail(("nothing to jump to matches %q"):format(text))
    elseif #matches == 1 then
      return out(matches[1].path)
    end
    local row = pick(rows, "jump", text)
    if not row then
      os.exit(130)
    end
    return out(row.path)
  end
  local stack = { lifejump.top() }
  while true do
    local node = stack[#stack]
    local row = pick(lifejump.level(stack), node.title)
    if not row then
      os.exit(130)
    elseif row.id == "." then
      return out(node.path)
    elseif row.id == ".." then
      if #stack == 1 then
        return out(row.path)
      end
      stack[#stack] = nil
    elseif row.node then
      stack[#stack + 1] = row.node
    else
      return out(row.path)
    end
  end
end

commands.jump = jump
commands.__jump = jump

-- iso reap [--dry-run|--live]: one reaper pass now, printing what the log gets.
function commands.reap(args)
  local live = flag(args, "--live")
  flag(args, "--dry-run")
  local result = require("isovim.lifecycle").reap({ live = live })
  for _, line in ipairs(result.lines) do
    out(line)
  end
end

-- iso sync: your config to every other host now, after the sync that's running (if one is) ends.
function commands.sync()
  local results = require("isovim.sync").run({ wait = 120 })
  if not results then
    return out("a sync is still running after two minutes; it goes round once more for this")
  end
  local failed = false
  local names = vim.tbl_keys(results)
  table.sort(names)
  if #names == 0 then
    return out("no other hosts to sync to (hosts in " .. require("isovim.config").path .. ")")
  end
  for _, name in ipairs(names) do
    local result = results[name]
    out(result == true and ("synced to " .. name) or ("FAILED " .. name .. ": " .. result))
    failed = failed or result ~= true
  end
  if failed then
    os.exit(1)
  end
end

-- What a write starts in the background.
function commands.__sync()
  pcall(require("isovim.sync").run)
end

return commands
