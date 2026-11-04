-- A fuzzy search over tasks and threads, across every project on this host: <leader>i/, and F on the board.
-- Each opening reads what it needs once, into memory, and what's typed only searches that: an id, title,
-- labels and assignee match fuzzily, while a description or a thread's posts must hold each word as
-- typed, as a long text holds almost any letters in order, and those rank below. Posts are decoded only for a
-- thread whose file changed since the last search. On a tie, open above resolved or Done, then the
-- current project's, then the most recent.
local surfaces = require("isovim.surfaces")
local threads = require("isovim.threads")
local tasks = require("isovim.board_tasks")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_board_find")
local RECENT_POSTS = 8

-- A thread's posts by its file, kept as long as its size and mtime stay.
local posts_cache = {} ---@type table<string, {size: integer, mtime: integer, posts: table[], body: string}>

local function thread_posts(repo, id)
  local path = threads.file(repo, id)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return { posts = {}, body = "" }
  end
  local cached = posts_cache[path]
  if cached and cached.size == stat.size and cached.mtime == stat.mtime.sec then
    return cached
  end
  local posts, texts = {}, {}
  for _, entry in ipairs(threads.read(repo, id) or {}) do
    if entry.kind == "post" and type(entry.text) == "string" then
      posts[#posts + 1] = { by = entry.by, at = entry.at, text = entry.text }
      texts[#texts + 1] = entry.text
    end
  end
  cached = { size = stat.size, mtime = stat.mtime.sec, posts = posts, body = table.concat(texts, "\n") }
  posts_cache[path] = cached
  return cached
end

-- Everything searchable, read once.
local function build_index()
  local items = {}
  local store = require("isovim.store")
  for _, repo in ipairs(surfaces.repos()) do
    if not store.is_pseudo(repo) then
      for id, task in pairs((tasks.read(repo))) do
        local assignee = task.assignee and tasks.assignee_name(task.assignee) or ""
        items[#items + 1] = { kind = "task", repo = repo, id = id, title = task.title, task = task,
          head = table.concat({ id, task.title, table.concat(task.labels, " "), assignee }, " "),
          raw = task.description or "", open = task.column ~= "done", last_at = task.last_at or 0 }
      end
      for id, entry in pairs(surfaces.thread_rows(repo)) do
        local posts = thread_posts(repo, id)
        items[#items + 1] = { kind = "thread", repo = repo, id = id, title = entry.title or id, entry = entry, posts = posts.posts,
          head = id .. " " .. (entry.title or ""), raw = posts.body, open = not entry.resolved, last_at = entry.last_at or 0 }
      end
    end
  end
  for _, item in ipairs(items) do
    item.lower = item.raw:lower()
    item.text = item.head
  end
  return items
end

-- A bit of raw around byte at, on one line, cut on whole characters.
local function snippet(raw, at, length)
  local text = raw:sub(math.max(1, at - 10), at + length + 40):gsub("%s+", " ")
  return "…" .. text:gsub("^[\128-\191]+", ""):gsub("[\192-\255][\128-\191]*$", "") .. "…"
end

-- The items that match query, best first, each with how it did: score, and for one found only in its
-- text, a snippet.
local function search(index, query, current)
  query = vim.trim(query or "")
  local found = {}
  local function add(item, tier, score, hit)
    found[#found + 1] = vim.tbl_extend("force", item, { tier = tier, score_of = score, snippet = hit, query = query })
  end
  if query == "" then
    for _, item in ipairs(index) do
      add(item, 1, 0)
    end
  else
    local lowered = query:lower()
    local by_head, heads = {}, {}
    for _, item in ipairs(index) do
      if not by_head[item.head] then
        by_head[item.head] = {}
        heads[#heads + 1] = item.head
      end
      table.insert(by_head[item.head], item)
    end
    local result = vim.fn.matchfuzzypos(heads, query)
    local in_head = {}
    for i, head in ipairs(result[1]) do
      for _, item in ipairs(by_head[head]) do
        in_head[item] = true
        -- A score costs 5 per letter of the text, which says nothing about the match here, so that's
        -- put back and those near each other are a tie. Its very id comes first.
        local score = math.floor(((result[3][i] or 0) + 5 * vim.fn.strchars(head)) / 100)
        add(item, 1, score + (item.id:lower() == lowered and 100000 or 0))
      end
    end
    local words = vim.split(lowered, "%s+", { trimempty = true })
    for _, item in ipairs(index) do
      if not in_head[item] then
        local first
        for _, word in ipairs(words) do
          local at = item.lower:find(word, 1, true)
          first = at and (first or at) or false
          if not at then
            break
          end
        end
        if first then
          add(item, 2, 0, snippet(item.raw, first, #words[1]))
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.tier ~= b.tier then
      return a.tier < b.tier
    elseif a.score_of ~= b.score_of then
      return a.score_of > b.score_of
    elseif a.open ~= b.open then
      return a.open
    elseif (a.repo == current) ~= (b.repo == current) then
      return a.repo == current
    elseif a.last_at ~= b.last_at then
      return a.last_at > b.last_at
    end
    return a.id < b.id
  end)
  return found
end

-- A title's chunks, the letters a query matched lit.
local function title_chunks(item)
  local dim = not item.open and "Comment" or nil
  local result = item.query ~= "" and not item.snippet and vim.fn.matchfuzzypos({ item.title }, item.query)
  local positions = result and result[2][1]
  if not positions then
    return { { item.title, dim } }
  end
  local lit, chunks = {}, {}
  for _, position in ipairs(positions) do
    lit[position] = true
  end
  for i = 0, vim.fn.strchars(item.title) - 1 do
    chunks[#chunks + 1] = { vim.fn.strcharpart(item.title, i, 1), lit[i] and "SnacksPickerMatch" or dim }
  end
  return chunks
end

-- A row: what it is, its id, project, title and state.
local function format(item)
  local board = require("isovim.thread_board")
  local row = item.kind == "task" and { { "\u{f0ae}", "DiagnosticInfo" } } or { { "\u{f086}", "Special" } }
  vim.list_extend(row, { { " " }, { item.id .. " ", "Comment" }, { item.repo .. "  ", "Comment" } })
  vim.list_extend(row, title_chunks(item))
  row[#row + 1] = { "  " }
  if item.kind == "task" then
    local column = vim.iter(board.COLUMNS):find(function(each)
      return each.key == item.task.column
    end)
    if column then
      vim.list_extend(row, { { column.glyph .. " ", column.hl }, { column.name, "Comment" } })
    end
  else
    for _, seg in ipairs(board.thread_marks(item.entry)) do
      row[#row + 1] = { seg.text .. " ", seg.marks[1] and seg.marks[1][3] }
    end
  end
  if item.snippet then
    row[#row + 1] = { "  " .. item.snippet, "Comment" }
  end
  return row
end

-- A task's view as text, its chips as they'd read.
function M.task_lines(repo, id)
  local links = require("isovim.links")
  return vim.tbl_map(function(line)
    return (line:gsub("iso:%a+/%S+", function(addr)
      return links.chip(addr)
    end))
  end, require("isovim.task_view").lines(repo, id))
end

-- A thread as text: the posts holding what's searched, then its recent ones.
local function thread_lines(item)
  local lines = { ("%s  %s"):format(item.id, item.title), item.repo .. (item.open and "" or "  · resolved"), "" }
  local function post(each)
    lines[#lines + 1] = ("%s, %s:"):format(tasks.assignee_name(each.by) or "?", os.date("%m-%d %H:%M", each.at or 0))
    vim.list_extend(lines, vim.split(each.text, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  local words = vim.split((item.query or ""):lower(), "%s+", { trimempty = true })
  local first = RECENT_POSTS
  if item.snippet then
    local shown = 0
    for _, each in ipairs(item.posts) do
      local lower = each.text:lower()
      if shown < 3 and vim.iter(words):any(function(word)
        return lower:find(word, 1, true) ~= nil
      end) then
        shown = shown + 1
        post(each)
      end
    end
    first = math.max(0, RECENT_POSTS - shown)
    lines[#lines + 1] = "── recent ──"
  end
  for i = math.max(1, #item.posts - first + 1), #item.posts do
    post(item.posts[i])
  end
  if #item.posts == 0 then
    lines[#lines + 1] = "No posts yet."
  end
  return lines
end

-- The words searched lit in a preview, and it scrolled to the first.
local function light(ctx, query, lines)
  local buf = ctx.buf or (ctx.preview and ctx.preview.win and ctx.preview.win.buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local first
  for _, word in ipairs(vim.split((query or ""):lower(), "%s+", { trimempty = true })) do
    for row, line in ipairs(lines) do
      local lower, from = line:lower(), 1
      while true do
        local at, to = lower:find(word, from, true)
        if not at then
          break
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, at - 1, { end_col = to, hl_group = "Search" })
        first = first and math.min(first, row) or row
        from = to + 1
      end
    end
  end
  local win = ctx.win or (ctx.preview and ctx.preview.win and ctx.preview.win.win)
  if first and win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
  end
end

function M.open()
  local index = build_index()
  local current = require("isovim").current_scope
  Snacks.picker.pick({
    source = "isovim_board_find",
    title = "Find tasks and threads",
    layout = { preset = "default" },
    live = true,
    finder = function(_, ctx)
      return search(index, ctx.filter.search, current)
    end,
    format = format,
    preview = function(ctx)
      local item = ctx.item
      local ok, lines = pcall(function()
        return item.kind == "task" and M.task_lines(item.repo, item.id) or thread_lines(item)
      end)
      lines = ok and lines or { item.title }
      ctx.preview:reset()
      ctx.preview:set_lines(lines)
      light(ctx, item.query, lines)
    end,
    confirm = function(picker, item)
      picker:close()
      if item and item.kind == "task" then
        local entry = surfaces.task_entry(item.repo, item.id)
        if entry then
          surfaces.open(entry)
        end
      elseif item then
        surfaces.open(item.entry)
      end
    end,
  })
end

return M
