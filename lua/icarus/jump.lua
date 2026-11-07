-- The g commands on a task's screen: gt task.md, gm<name> a markdown file by name, and ga, gv, gp and
-- gl the outline's agents, visuals, PRs and Linear tickets. Off a task's screen they're vim's own.
local tasks = require("icarus.tasks")

local M = {}

local NOT_FILES = { agents = true, org = true }
local ESC, CTRL_C, CR = "\27", "\3", "\r"

-- The task on screen, if the screen is a task's.
local function here()
  local view = require("icarus").view()
  local task = view and view.kind == "task" and tasks.read(view.task)
  return task and not task.sentinel and task or nil
end

local function native(keys)
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- gt.
function M.task_md()
  local task = here()
  if not task then
    return native("gt")
  end
  require("icarus.task_page").show(task, { file = task.file })
end

-- ga, gv, gp, gl: the cursor to that section of the outline.
function M.section(keys, group, what)
  if not here() then
    return native(keys)
  end
  if not require("icarus.outline").jump(group) then
    vim.notify("No " .. what .. " on this task", vim.log.levels.INFO)
  end
end

-- The task's markdown files, by the path under its folder.
local function markdown(task)
  local files = {}
  for name, kind in vim.fs.dir(task.dir, { depth = 8 }) do
    local top = name:match("^[^/]+")
    if kind == "file" and name:match("%.md$") and not NOT_FILES[top] and not top:match("^%.") then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  return files
end

-- The files whose name has typed in it, whatever the case. Not the .md: they all have that.
local function matching(files, typed)
  return vim.tbl_filter(function(name)
    return name:gsub("%.md$", ""):lower():find(typed:lower(), 1, true) ~= nil
  end, files)
end

-- gm: lights every markdown file in the outline, and each key narrows them by name until one is left,
-- which opens. <CR> takes the first, <Esc> leaves, and a key that would match nothing is ignored.
function M.markdown()
  local task = here()
  if not task then
    return native("gm")
  end
  local outline = require("icarus.outline")
  local files, typed = markdown(task), ""
  while true do
    local left = matching(files, typed)
    if #left == 1 then
      break
    end
    local keys = {}
    for _, name in ipairs(left) do
      keys["file:" .. task.dir .. "/" .. name] = true
    end
    outline.light(keys)
    vim.api.nvim_echo({ { "gm " .. typed, "Normal" } }, false, {})
    vim.cmd.redraw()
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok or key == ESC or key == CTRL_C then
      files = {}
      break
    elseif key == CR then
      files = { left[1] }
      typed = ""
      break
    elseif key == "\8" or key == vim.api.nvim_replace_termcodes("<BS>", true, false, true) then
      typed = vim.fn.strcharpart(typed, 0, vim.fn.strchars(typed) - 1)
    elseif #key == 1 and #matching(files, typed .. key) > 0 then
      typed = typed .. key
    end
  end
  outline.light(nil)
  vim.api.nvim_echo({ { "", "Normal" } }, false, {})
  local left = matching(files, typed)
  if #left == 1 then
    require("icarus.task_page").show(task, { file = task.dir .. "/" .. left[1] })
  end
end

return M
