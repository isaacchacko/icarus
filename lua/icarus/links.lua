-- Links, in a chat or a file: underlined where they're drawn, and <Tab> on one opens it. <Tab>
-- anywhere else does what it does in vim (forward in the jump list).
--
--   https://...                      opens in the browser
--   icarus://task/<slug>             the task's screen
--   icarus://task/<slug>/<file>      the task's screen with that file (under the task's folder) open
--   icarus://agent/<chat id>         that agent's chat, on its task's screen
--   /an/absolute/path[:line]         a file that exists: on its task's screen if it's in one, else
--                                    in the right column
--   [text](any of the above)         the same, from anywhere on the text or the target
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_links")

vim.api.nvim_set_hl(0, "IcarusLink", { underline = true, fg = "#61afef", default = true })
vim.api.nvim_set_hl(0, "IcarusLinkIcarus", { underline = true, fg = "#c678dd", default = true })

-- Whether path is a file, asked of the disk at most every few seconds per path, as drawing asks often.
local exists = {}
local function is_file(path)
  local now = vim.uv.now()
  local seen = exists[path]
  if not seen or now - seen.at > 5000 then
    seen = { at = now, yes = vim.fn.filereadable(path) == 1 }
    exists[path] = seen
  end
  return seen.yes
end

local function trim(target)
  return (target:gsub("[%.,;:!%?%)%]'\"`>]+$", ""))
end

-- The links on line: {from, to (byte columns, 1-based, inclusive), target}, in order.
function M.find(line)
  local found = {}
  local function taken(from, to)
    for _, link in ipairs(found) do
      if from <= link[2] and to >= link[1] then
        return true
      end
    end
  end
  local function add(from, to, target)
    if not taken(from, to) then
      found[#found + 1] = { from, to, target }
    end
  end
  for from, target, after in line:gmatch("()%[[^%]]-%]%(([^%)%s]+)%)()") do
    add(from, after - 1, target)
  end
  for from, target in line:gmatch("()(https?://[%w%-%._~:/%?#@!%$&'%*%+,;=%%]+)") do
    target = trim(target)
    add(from, from + #target - 1, target)
  end
  for from, target in line:gmatch("()(icarus://[%w%-%._/]+)") do
    target = trim(target)
    add(from, from + #target - 1, target)
  end
  for from, target in line:gmatch("()(~?/[%w%-%._/]+[%w%-_/]:?%d*)") do
    local path = vim.fn.expand(target:gsub(":%d*$", ""))
    local before = from > 1 and line:sub(from - 1, from - 1) or ""
    if not before:match("[%w:/]") and path:find("/", 2, true) and is_file(path) then
      add(from, from + #target - 1, target)
    end
  end
  table.sort(found, function(a, b)
    return a[1] < b[1]
  end)
  return found
end

-- The link under the cursor, if there's one.
function M.at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for _, link in ipairs(M.find(line)) do
    if col >= link[1] and col <= link[2] then
      return link[3]
    end
  end
end

-- The task the absolute path is in, and the path under its folder.
local function task_of(path)
  local root = require("icarus.tasks").ROOT .. "/tasks/"
  if vim.startswith(path, root) then
    local slug, rest = path:sub(#root + 1):match("^([^/]+)/?(.*)$")
    return slug, rest
  end
end

local function open_in_task(slug, file, line)
  local tasks = require("icarus.tasks")
  local task = tasks.read(slug)
  if not task then
    return vim.notify("No task " .. slug, vim.log.levels.WARN)
  end
  require("icarus").open_task(task)
  if file and file ~= "" then
    local win = require("icarus.explorer").open_file(task.dir .. "/" .. file)
    vim.api.nvim_set_current_win(win)
    if line then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    end
  end
end

-- Opens target, whatever kind of link it is.
function M.open(target)
  target = target:gsub("^<", ""):gsub(">$", "")
  if target:match("^https?://") then
    return vim.ui.open(target)
  end
  local slug, file = target:match("^icarus://task/([^/]+)/?(.*)$")
  if slug then
    return open_in_task(slug, file)
  end
  local id = target:match("^icarus://agent/(.+)$")
  if id then
    local record = require("icarus.chats").get(id)
    if not record then
      return vim.notify("No agent " .. id, vim.log.levels.WARN)
    end
    local task = require("icarus.tasks").read(record.task or require("icarus.tasks").SENTINEL)
    if task then
      return require("icarus.task_page").open(task, record)
    end
    return require("icarus").open(record)
  end
  local path, line = target:match("^(.-):(%d+)$")
  path = vim.fn.expand(path or target)
  line = tonumber(line)
  if path:sub(1, 1) == "/" and vim.fn.filereadable(path) == 1 then
    local in_task, rest = task_of(path)
    if in_task then
      return open_in_task(in_task, rest, line)
    end
    local win = require("icarus.explorer").open_file(path)
    vim.api.nvim_set_current_win(win)
    if line then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    end
    return
  end
  vim.notify("Can't open " .. target, vim.log.levels.WARN)
end

-- <Tab>: the link under the cursor, else vim's <Tab>.
function M.tab()
  local target = M.at_cursor()
  if target then
    return M.open(target)
  end
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "n", false)
end

-- How links look. In a file you edit (a buffer with a file), as typed, coloured and underlined. In
-- what icarus draws (chats, threads, the PRs, floats: buffers without a file), rendered: a bare link
-- hidden behind a label (a PR as "⇄ app#123", a ticket as "◆ ABC-123", a task or an agent by its
-- title, a file by its short path, any other page by its site), and a markdown link as its text
-- after the same mark. Labels are extmarks put on the lines in view after each redraw that finds
-- them stale (inline text can't be drawn as it's drawn), so they follow the text as it streams.
local LABELS = vim.api.nvim_create_namespace("icarus_link_labels")

vim.api.nvim_set_hl(0, "IcarusLinkMark", { link = "Comment", default = true })

local function short(text, n)
  return vim.fn.strchars(text) > n and vim.fn.strcharpart(text, 0, n - 1) .. "…" or text
end

-- A link's mark and label: what it is, briefly.
local function describe(target)
  local repo, kind, n = target:match("^https://github%.com/[%w%-%._]+/([%w%-%._]+)/(%a+)/(%d+)")
  if repo and (kind == "pull" or kind == "issues") then
    return kind == "pull" and "⇄" or "◇", ("%s#%s"):format(repo, n)
  end
  local ticket = target:match("^https://linear%.app/[%w%-]+/issue/(%w+%-%d+)")
  if ticket then
    return "◆", ticket
  end
  local slug, file = target:match("^icarus://task/([^/]+)/?(.*)$")
  if slug then
    local seen = require("icarus.tasks").seen(slug)
    return "⧉", short((seen and seen.title or slug) .. (file ~= "" and (" / " .. file) or ""), 40)
  end
  local id = target:match("^icarus://agent/(.+)$")
  if id then
    local record = require("icarus.chats").get(id)
    return "◉", short(record and record.title or id, 40)
  end
  local host, path = target:match("^https?://([^/]+)(.*)$")
  if host then
    path = path:gsub("[?#].*$", ""):gsub("/$", "")
    return "↗", short(host:gsub("^www%.", "") .. path, 48)
  end
  local file_path, line = target:match("^(.-):(%d+)$")
  file_path = file_path or target
  local parts = vim.split(vim.fn.fnamemodify(file_path, ":~"), "/", { plain = true })
  local tail = #parts > 2 and ("…/" .. parts[#parts - 1] .. "/" .. parts[#parts]) or table.concat(parts, "/")
  return "▤", tail .. (line and (":" .. line) or "")
end

local function group(target)
  return target:match("^icarus://") and "IcarusLinkIcarus" or "IcarusLink"
end

local function rendered(buf)
  return vim.bo[buf].buftype ~= "" and vim.api.nvim_buf_is_loaded(buf)
end

-- Labels the links on rows top..bot of buf.
local function label(buf, top, bot)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, LABELS, top, bot + 1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, top, bot + 1, false)) do
    row = top + row - 1
    if line:find("[/%]]") then
      for _, link in ipairs(M.find(line)) do
        local from, to, target = link[1] - 1, link[2], link[3]
        local mark, text = describe(target)
        local md_text_end = line:sub(from + 1, to):match("^%[(.-)%]%(") and (from + 1 + #line:sub(from + 1, to):match("^%[(.-)%]%("))
        if md_text_end then
          -- [text](target): "[" and "](target)" hidden, the mark before the text.
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, from, { end_col = from + 1, conceal = "" })
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, from, { virt_text = { { mark .. " ", "IcarusLinkMark" } },
            virt_text_pos = "inline" })
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, from + 1, { end_col = md_text_end, hl_group = group(target) })
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, md_text_end, { end_col = to, conceal = "" })
        else
          -- Hidden, so the cursor's highlight (icarus.link_cursor) can't show on it: the label takes it.
          local lit = package.loaded["icarus.link_cursor"] and package.loaded["icarus.link_cursor"].lit()
          local hover = lit and lit.buf == buf and lit.row == row and lit.from == from
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, from, { end_col = to, conceal = "" })
          vim.api.nvim_buf_set_extmark(buf, LABELS, row, from, { virt_text = { { mark .. " ", "IcarusLinkMark" },
            { text, hover and "IcarusLinkHover" or group(target) } }, virt_text_pos = "inline" })
        end
      end
    end
  end
end

-- Which rows of each buffer were labelled, as of which change.
local labelled = {}

-- Labels buf again on its next redraw (the link under the cursor changed).
function M.relabel(buf)
  labelled[buf] = nil
end

vim.api.nvim_set_decoration_provider(NS, {
  on_win = function(_, win, buf, top, bot)
    if rendered(buf) and vim.wo[win].conceallevel > 0 then
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local was = labelled[buf]
      if not (was and was.tick == tick and was.top <= top and was.bot >= bot) then
        labelled[buf] = { tick = tick, top = top, bot = bot }
        vim.schedule(function()
          label(buf, top, bot)
        end)
      end
      return false
    end
    return vim.bo[buf].buftype == ""
  end,
  -- In a file: as typed, coloured and underlined.
  on_line = function(_, _, buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line or not line:find("[/%]]") then
      return
    end
    for _, link in ipairs(M.find(line)) do
      vim.api.nvim_buf_set_extmark(buf, NS, row, link[1] - 1, { end_col = link[2], ephemeral = true,
        hl_group = group(link[3]), priority = 150 })
    end
  end,
})

return M
