-- How an ACP agent's chat (isovim.acp.chat) looks, as Claude Code draws its own screen: the
-- palette and highlight groups for dark and light backgrounds, a tool call's header (Claude's
-- display name and its arguments: "Update(app.py)", "Bash(./count.sh)") and the rows under it (a
-- read's line count, a diff with line numbers and word-level changes, a command's output and exit
-- code), markdown's inline marks in the agent's text, and the spinner's words. Everything here is a
-- pure function of what it's given (the journal's entries, the agent's dir), so a chat replayed
-- from its journal draws exactly what it drew live.
local M = {}

-- Claude's bullet: ⏺ on macOS, ● elsewhere (where ⏺ often draws as an emoji, two cells wide).
M.DOT = vim.fn.has("mac") == 1 and "⏺" or "●"
M.FIRST, M.REST = "  ⎿  ", "     "
-- Output lines shown under a collapsed tool call, as Claude shows the first few.
M.PREVIEW = 3
-- A diff opens by default up to this many lines; a longer one shows its summary until za.
M.DIFF_OPEN = 80
M.MAX_BODY = 400

-- Claude Code's own colors, from its dark and light themes.
local PALETTE = {
  dark = {
    accent = "#D77757", -- Claude's orange: the spinner and its verb
    shimmer = "#EB9F7F",
    dim = "#999999", -- secondary text: ⎿, results' notes, hints, the turn's summary
    rule = "#888888",
    text = "#FFFFFF",
    prompt_bg = "#373737",
    code = "#B1B9F9", -- inline code, and the permission/question boxes
    success = "#4EBA65",
    error = "#FF6B80",
    add_bg = "#022800",
    add_word = "#044700",
    add_nr = "#50C850",
    del_bg = "#3D0100",
    del_word = "#5C0200",
    del_nr = "#DC5A5A",
    dash = "#505050",
    chip_fg = "#000000",
  },
  light = {
    accent = "#D77757",
    shimmer = "#C25E3F",
    dim = "#666666",
    rule = "#8A8A8A",
    text = "#000000",
    prompt_bg = "#F0F0F0",
    code = "#5769F7",
    success = "#2C7A39",
    error = "#AB2B3F",
    add_bg = "#DCFFDC",
    add_word = "#B2FFB2",
    add_nr = "#2C7A39",
    del_bg = "#FFDCDC",
    del_word = "#FFC7C7",
    del_nr = "#CF222E",
    dash = "#C8C8C8",
    chip_fg = "#FFFFFF",
  },
}

M.palette = PALETTE

---@return table<string, vim.api.keyset.highlight>
function M.groups(background)
  local c = PALETTE[background == "light" and "light" or "dark"]
  return {
    IsovimAcpPrompt = { fg = c.text, bg = c.prompt_bg },
    IsovimAcpPromptGlyph = { fg = c.dim, bg = c.prompt_bg },
    IsovimAcpMessage = { link = "Normal" },
    IsovimAcpCode = { fg = c.code },
    IsovimAcpBold = { bold = true },
    IsovimAcpHeading = { bold = true, underline = false },
    IsovimAcpThought = { fg = c.dim, italic = true },
    IsovimAcpToolTitle = { bold = true },
    IsovimAcpToolPending = { fg = c.dim },
    IsovimAcpToolRunning = { fg = c.dim },
    IsovimAcpToolDone = { fg = c.success },
    IsovimAcpToolFailed = { fg = c.error },
    IsovimAcpResult = { link = "Normal" },
    IsovimAcpResultGlyph = { fg = c.dim },
    IsovimAcpResultNote = { fg = c.dim },
    IsovimAcpError = { fg = c.error },
    IsovimAcpDiffAdd = { bg = c.add_bg },
    IsovimAcpDiffDelete = { bg = c.del_bg },
    IsovimAcpDiffAddWord = { bg = c.add_word },
    IsovimAcpDiffDeleteWord = { bg = c.del_word },
    IsovimAcpDiffAddNr = { fg = c.add_nr, bg = c.add_bg },
    IsovimAcpDiffDeleteNr = { fg = c.del_nr, bg = c.del_bg },
    IsovimAcpDiffNr = { fg = c.dim },
    IsovimAcpNotice = { fg = c.dim },
    IsovimAcpDenied = { fg = c.error },
    IsovimAcpQueued = { fg = c.dim },
    IsovimAcpSpinner = { fg = c.accent },
    IsovimAcpSpinnerVerb = { fg = c.accent },
    IsovimAcpSpinnerNote = { fg = c.dim },
    IsovimAcpIdle = { fg = c.dim },
    IsovimAcpAsk = { fg = c.code },
    IsovimAcpAskTitle = { fg = c.code, bold = true },
    IsovimAcpAskRule = { fg = c.code },
    IsovimAcpAskDash = { fg = c.dash },
    IsovimAcpAskChip = { fg = c.chip_fg, bg = c.code },
    IsovimAcpOptionNr = { fg = c.dim },
    IsovimAcpOption = { link = "Normal" },
    IsovimAcpOptionNote = { fg = c.dim },
    IsovimAcpPlanDone = { fg = c.dim, strikethrough = true },
    IsovimAcpPlanActive = { bold = true },
    IsovimAcpPlanPending = { link = "Normal" },
    IsovimAcpRule = { fg = c.rule },
    IsovimAcpComposerGlyph = { fg = c.text, bold = true },
    IsovimAcpHint = { fg = c.dim },
    IsovimAcpTurnDone = { fg = c.dim },
  }
end

-- The groups as last set here, so a colorscheme or background change redefines ours and keeps
-- any you set yourself.
local set_by_us = {}

function M.highlights()
  for name, spec in pairs(M.groups(vim.o.background)) do
    local now = vim.api.nvim_get_hl(0, { name = name, link = true })
    if next(now) == nil or vim.deep_equal(now, set_by_us[name]) then
      vim.api.nvim_set_hl(0, name, spec)
      set_by_us[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
    end
  end
end

-- Words

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end
M.plural = plural

-- Claude's spinner verbs, and the past tense it says a turn ended with.
M.VERBS = { "Accomplishing", "Baking", "Beboppin'", "Booping", "Brewing", "Calculating", "Cerebrating", "Channelling",
  "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Computing", "Concocting", "Conjuring",
  "Considering", "Contemplating", "Cooking", "Crafting", "Crunching", "Deciphering", "Deliberating", "Discombobulating",
  "Divining", "Elucidating", "Enchanting", "Envisioning", "Fermenting", "Finagling", "Flibbertigibbeting", "Forging",
  "Frolicking", "Gallivanting", "Generating", "Germinating", "Hatching", "Herding", "Honking", "Hustling", "Ideating",
  "Imagining", "Incubating", "Inferring", "Jiving", "Manifesting", "Marinating", "Meandering", "Moseying", "Mulling",
  "Musing", "Mustering", "Noodling", "Percolating", "Perusing", "Philosophising", "Pondering", "Pontificating",
  "Processing", "Puttering", "Puzzling", "Reticulating", "Ruminating", "Scheming", "Schlepping", "Shimmying",
  "Simmering", "Smooshing", "Spelunking", "Spinning", "Stewing", "Sussing", "Synthesizing", "Thinking", "Tinkering",
  "Transmogrifying", "Transmuting", "Unfurling", "Unravelling", "Vibing", "Wandering", "Whirring", "Wibbling",
  "Wizarding", "Working", "Wrangling" }
M.PAST = { "Baked", "Brewed", "Churned", "Cogitated", "Cooked", "Crunched", "Sautéed", "Worked" }

local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 2147483647
  end
  return h
end

-- A turn's verb (and its past tense), the same for the same turn wherever it's drawn.
function M.verb(id)
  local h = hash(tostring(id or ""))
  return M.VERBS[h % #M.VERBS + 1], M.PAST[h % #M.PAST + 1]
end

function M.duration(secs)
  secs = math.max(0, math.floor(secs + 0.5))
  if secs < 60 then
    return secs .. "s"
  elseif secs < 3600 then
    return ("%dm %ds"):format(math.floor(secs / 60), secs % 60)
  end
  return ("%dh %dm"):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

-- "1.2k" for tokens, as Claude counts them.
function M.count(n)
  if n < 1000 then
    return tostring(n)
  end
  return (("%.1fk"):format(n / 1000):gsub("%.0k$", "k"))
end

-- Tool calls

-- Claude's names for its tools, as its screen shows them.
M.NAMES = {
  Edit = "Update", MultiEdit = "Update", Write = "Write", Read = "Read", Bash = "Bash", Grep = "Search", Glob = "Search",
  WebFetch = "Fetch", WebSearch = "Web Search", Task = "Task", Agent = "Task", NotebookEdit = "Update Notebook",
  NotebookRead = "Read Notebook", TodoWrite = "Update Todos", KillShell = "Kill Shell", BashOutput = "Bash Output",
  ExitPlanMode = "Plan",
}
-- Tools isovim draws another way: AskUserQuestion as its question box, TodoWrite as its plan.
M.HIDDEN = { AskUserQuestion = true, TodoWrite = true }

-- The tool's own name, from the adapter's _meta (claude-agent-acp), else read off its title.
---@return string? name
function M.tool_name(call)
  if call.tool then
    return call.tool
  end
  local title = call.title or ""
  local word = title:match("^(%u%a+)[%s:]") or title:match("^(%u%a+)$")
  if word and (M.NAMES[word] or M.HIDDEN[word]) then
    return word
  end
  if call.kind == "execute" and title:match("^`.*`$") then
    return "Bash"
  end
end

local function first_line(text)
  text = tostring(text or "")
  local first = text:match("^([^\n]*)\n")
  return first and (first .. " …") or text
end

local function quote(value)
  if type(value) == "string" then
    return ('"%s"'):format(first_line(value))
  end
  return vim.json.encode(value)
end

-- A path as the agent's dir sees it (dir and its real path).
function M.short(path, dirs)
  for _, base in ipairs(dirs or {}) do
    if path and base and vim.startswith(path, base .. "/") then
      return path:sub(#base + 2)
    end
  end
  return path or "a file"
end

-- What goes in the parens after the tool's name.
---@return string?
function M.tool_args(name, input, title, dirs)
  input = type(input) == "table" and input or {}
  local path = input.file_path or input.notebook_path
  if path then
    return M.short(path, dirs)
  elseif name == "Bash" and input.command then
    return first_line(input.command)
  elseif (name == "Grep" or name == "Glob") and input.pattern then
    local args = { "pattern: " .. quote(input.pattern) }
    if input.path then
      args[#args + 1] = "path: " .. quote(M.short(input.path, dirs))
    end
    return table.concat(args, ", ")
  elseif name == "WebFetch" and input.url then
    return input.url
  elseif name == "WebSearch" and input.query then
    return input.query
  elseif (name == "Task" or name == "Agent") and input.description then
    return input.description
  end
  local keys = vim.tbl_keys(input)
  if #keys > 0 then
    table.sort(keys)
    local args = {}
    for _, k in ipairs(keys) do
      if k ~= "description" or #keys == 1 then
        args[#args + 1] = ("%s: %s"):format(k, quote(input[k]))
      end
    end
    local text = table.concat(args, ", ")
    return #text > 160 and (vim.fn.strcharpart(text, 0, 159) .. "…") or text
  end
  -- None given (yet): what the title says after the name.
  title = title or ""
  if name == "Bash" then
    local cmd = title:match("^`(.*)`$") or title:match("^Bash:? (.*)$") or title
    return cmd ~= "" and cmd ~= "Terminal" and first_line(cmd) or nil
  end
  local rest = title:match("^%u%a+:? (.+)$")
  return rest and first_line(rest) or nil
end

-- The header: {name, args?}; name alone (the title as it came) when the tool isn't one Claude names.
function M.header(call, dirs)
  local name = M.tool_name(call)
  if name and name:match("^mcp__") then
    local server, tool = name:match("^mcp__(.-)__(.+)$")
    return ("%s - %s (MCP)"):format(server or name, tool or ""), M.tool_args(name, call.input, nil, dirs)
  end
  if name and M.NAMES[name] then
    return M.NAMES[name], M.tool_args(name, call.input, call.title, dirs)
  elseif name then
    return name, M.tool_args(name, call.input, call.title, dirs)
  end
  local title = (call.title or "tool"):gsub("\n.*", " …")
  return (title:gsub("^`(.*)`$", "%1")), nil
end

-- Rows: {text, hl?, spans?: {col, end_col, hl}[], note?: true}. text has no ⎿ prefix yet.

local function strip_ansi(text)
  return (text:gsub("\27%[[%d;?]*[%a]", ""):gsub("\27%][^\7]*\7", ""):gsub("\r\n", "\n"):gsub("\r", ""))
end

-- Text content without the code fence the adapter wraps output in.
function M.text_lines(text)
  local lines = vim.split(strip_ansi(text or ""), "\n", { plain = true })
  if lines[1] and lines[1]:match("^```") then
    table.remove(lines, 1)
    while lines[#lines] == "" do
      lines[#lines] = nil
    end
    if lines[#lines] and lines[#lines]:match("^```%s*$") then
      lines[#lines] = nil
    end
  end
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\t", "  ")
  end
  return lines
end

-- Spans for the numbers in "Added 5 lines, removed 1 line", bold as Claude has them.
local function bold_numbers(text)
  local spans = {}
  local init = 1
  while true do
    local s, e = text:find("%d+", init)
    if not s then
      break
    end
    spans[#spans + 1] = { s - 1, e, "IsovimAcpBold" }
    init = e + 1
  end
  return spans
end

-- The byte where a and b first differ and where their common tails start, kept off the middle of a
-- UTF-8 character.
local function changed_range(a, b)
  local pre = 0
  while pre < #a and pre < #b and a:byte(pre + 1) == b:byte(pre + 1) do
    pre = pre + 1
  end
  while pre > 0 and (a:byte(pre + 1) or 0) >= 0x80 and (a:byte(pre + 1) or 0) < 0xC0 do
    pre = pre - 1
  end
  local suf = 0
  while suf < #a - pre and suf < #b - pre and a:byte(#a - suf) == b:byte(#b - suf) do
    suf = suf + 1
  end
  while suf > 0 and (a:byte(#a - suf + 1) or 0) >= 0x80 and (a:byte(#a - suf + 1) or 0) < 0xC0 do
    suf = suf - 1
  end
  return pre, #a - suf, #b - suf
end

-- Syntax highlights for code by treesitter: per line (1-based), {col, end_col, group}. Nothing when
-- there's no parser for the language.
local function syntax(lines, lang)
  local out = {}
  if not lang or #lines == 0 then
    return out
  end
  local ok = pcall(function()
    local source = table.concat(lines, "\n")
    local parser = vim.treesitter.get_string_parser(source, lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(lang, "highlights")
    if not (tree and query) then
      return
    end
    for id, node in query:iter_captures(tree:root(), source) do
      local name = query.captures[id]
      if name ~= "spell" and name ~= "nospell" and not name:match("^_") then
        local sr, sc, er, ec = node:range()
        for row = sr, er do
          local line = lines[row + 1]
          if line then
            local from = row == sr and sc or 0
            local to = row == er and ec or #line
            if to > from then
              out[row + 1] = out[row + 1] or {}
              table.insert(out[row + 1], { from, to, "@" .. name .. "." .. lang })
            end
          end
        end
      end
    end
  end)
  return ok and out or {}
end

local function lang_of(path)
  local ft = path and vim.filetype.match({ filename = path })
  if not ft then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local has = pcall(vim.treesitter.language.add, lang)
  return has and lang or nil
end

-- A diff's rows: what changed with Claude's context, each line with its number, removed lines red
-- and added green with the changed words brighter, the code highlighted as its language; and its
-- summary ("Added 5 lines, removed 1 line"). start is the line its old text starts at in the file.
---@return table[] rows, string summary
function M.diff_rows(item, start, dirs)
  local old = item.oldText ~= vim.NIL and item.oldText or nil
  local new = item.newText ~= vim.NIL and item.newText or ""
  local path = M.short(item.path, dirs)
  local lang = lang_of(item.path)
  local function split(text)
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    return lines
  end
  if not old then
    local lines = split(new)
    local width = math.max(3, #tostring(#lines))
    local hl = syntax(lines, lang)
    local rows = {}
    for i, line in ipairs(lines) do
      local prefix = ("%" .. width .. "d  "):format(i)
      local spans = { { 0, #prefix, "IsovimAcpDiffNr" } }
      for _, s in ipairs(hl[i] or {}) do
        spans[#spans + 1] = { s[1] + #prefix, s[2] + #prefix, s[3] }
      end
      rows[#rows + 1] = { prefix .. line, spans = spans }
    end
    return rows, ("Wrote %s to %s"):format(plural(#lines, "line"), path)
  end
  local function nl(text)
    return text:sub(-1) == "\n" and text or text .. "\n"
  end
  start = math.max(1, tonumber(start) or 1)
  local diff = (vim.text and vim.text.diff or vim.diff)(nl(old), nl(new), { result_type = "unified", ctxlen = 3 })
  -- Each row: {sign, old number or nil, new number or nil, code}.
  local raw, olds, news = {}, split(old), split(new)
  local added, removed = 0, 0
  local o, n = 0, 0
  for line in tostring(diff or ""):gmatch("([^\n]*)\n") do
    local a, c = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if a then
      if #raw > 0 then
        raw[#raw + 1] = { "…" }
      end
      o, n = tonumber(a), tonumber(c)
      -- A hunk at the very start says 0 for an empty side.
      o, n = math.max(o, 1), math.max(n, 1)
    elseif line:sub(1, 1) == "-" then
      raw[#raw + 1] = { "-", o, nil, line:sub(2) }
      o, removed = o + 1, removed + 1
    elseif line:sub(1, 1) == "+" then
      raw[#raw + 1] = { "+", nil, n, line:sub(2) }
      n, added = n + 1, added + 1
    elseif line:sub(1, 1) == " " then
      raw[#raw + 1] = { " ", o, n, line:sub(2) }
      o, n = o + 1, n + 1
    end
  end
  local top = 0
  for _, r in ipairs(raw) do
    top = math.max(top, (r[2] or r[3] or 0) + start - 1)
  end
  local width = math.max(3, #tostring(top))
  local old_hl, new_hl = syntax(olds, lang), syntax(news, lang)
  -- Word-level changes: a run of removed lines then a run of added ones, paired line by line.
  local words = {}
  local i = 1
  while i <= #raw do
    if raw[i][1] == "-" then
      local j = i
      while j <= #raw and raw[j][1] == "-" do
        j = j + 1
      end
      local k = j
      while k <= #raw and raw[k][1] == "+" do
        k = k + 1
      end
      for p = 0, math.min(j - i, k - j) - 1 do
        local a, b = raw[i + p][4], raw[j + p][4]
        local pre, a_end, b_end = changed_range(a, b)
        -- Only part of the line changed: that part is marked; a whole new line isn't.
        if (a_end > pre or b_end > pre) and (pre > 0 or a_end < #a or b_end < #b) then
          words[i + p] = a_end > pre and { pre, a_end } or nil
          words[j + p] = b_end > pre and { pre, b_end } or nil
        end
      end
      i = k
    else
      i = i + 1
    end
  end
  local rows = {}
  for idx, r in ipairs(raw) do
    if r[1] == "…" then
      rows[#rows + 1] = { (" "):rep(width - 1) .. "…", spans = { { 0, width, "IsovimAcpDiffNr" } } }
    else
      local num = (r[1] == "-" and r[2] or r[3]) + start - 1
      local prefix = ("%" .. width .. "d %s"):format(num, r[1])
      local line = prefix .. r[4]
      local spans, hl = {}, nil
      if r[1] == "-" then
        hl = "IsovimAcpDiffDelete"
        spans[#spans + 1] = { 0, #prefix, "IsovimAcpDiffDeleteNr" }
      elseif r[1] == "+" then
        hl = "IsovimAcpDiffAdd"
        spans[#spans + 1] = { 0, #prefix, "IsovimAcpDiffAddNr" }
      else
        spans[#spans + 1] = { 0, #prefix, "IsovimAcpDiffNr" }
      end
      if words[idx] then
        spans[#spans + 1] = { #prefix + words[idx][1], #prefix + words[idx][2],
          r[1] == "-" and "IsovimAcpDiffDeleteWord" or "IsovimAcpDiffAddWord" }
      end
      local code_hl = r[1] == "-" and old_hl[r[2]] or new_hl[r[3]] or {}
      for _, s in ipairs(code_hl) do
        spans[#spans + 1] = { s[1] + #prefix, s[2] + #prefix, s[3], syntax = true }
      end
      rows[#rows + 1] = { line, hl = hl, spans = spans }
    end
  end
  local summary
  if added > 0 and removed > 0 then
    summary = ("Added %s, removed %s"):format(plural(added, "line"), plural(removed, "line"))
  elseif added > 0 then
    summary = ("Added %s"):format(plural(added, "line"))
  elseif removed > 0 then
    summary = ("Removed %s"):format(plural(removed, "line"))
  else
    summary = "No changes"
  end
  return rows, summary
end

-- The line its diff starts at in the file, from the tool call's locations.
local function start_of(call, item)
  for _, loc in ipairs(call.locations or {}) do
    if type(loc) == "table" and loc.path == item.path and tonumber(loc.line) then
      return tonumber(loc.line)
    end
  end
  return 1
end

-- What goes under a tool call, and how it shows collapsed: rows (the first after ⎿), and kind
-- "diff" (open by default), "read" (its line count only, until za) or "output" (the first few
-- lines and how many more).
---@return table[] rows, string kind
function M.body(call, dirs)
  local rows, kind = {}, "output"
  local shown_terminals = {}
  local name = M.tool_name(call)
  local function plain(lines)
    for _, line in ipairs(lines) do
      rows[#rows + 1] = { line }
    end
  end
  local failed = call.status == "failed" or (call.exit and call.exit ~= 0)
  if call.exit and call.exit ~= 0 then
    rows[#rows + 1] = { ("Error: Exit code %d"):format(call.exit), hl = "IsovimAcpError" }
  end
  for _, item in ipairs(call.items or {}) do
    if item.type == "content" and type(item.content) == "table" and item.content.type == "text" then
      plain(M.text_lines(item.content.text))
    elseif item.type == "diff" then
      local lines, summary = M.diff_rows(item, start_of(call, item), dirs)
      rows[#rows + 1] = { summary, spans = bold_numbers(summary) }
      vim.list_extend(rows, lines)
      kind = item.oldText ~= nil and item.oldText ~= vim.NIL and "diff" or "output"
      if kind == "output" then
        -- A new file: Claude shows its first lines.
        kind = "write"
      end
    elseif item.type == "terminal" then
      shown_terminals[item.terminalId or ""] = true
      plain(M.text_lines(call.terminal and call.terminal[item.terminalId or ""] or ""))
    end
  end
  for id, output in pairs(call.terminal or {}) do
    if not shown_terminals[id] then
      plain(M.text_lines(output))
    end
  end
  while #rows > 0 and vim.trim(rows[#rows][1]) == "" do
    rows[#rows] = nil
  end
  while #rows > 0 and vim.trim(rows[1][1]) == "" do
    table.remove(rows, 1)
  end
  -- A read: how many lines, the lines themselves under za.
  if (name == "Read" or (not name and call.kind == "read")) and #rows > 0 and not failed then
    local count = #rows
    local file = call.response and call.response.file
    if type(file) == "table" and tonumber(file.numLines) then
      count = tonumber(file.numLines)
    end
    for _, row in ipairs(rows) do
      row[1] = row[1]:gsub("^(%d+)  ", function(num)
        return ("%4d  "):format(tonumber(num))
      end)
    end
    local summary = ("Read %s"):format(plural(count, "line"))
    table.insert(rows, 1, { summary, spans = bold_numbers(summary) })
    kind = "read"
  end
  if #rows == 0 and call.status == "completed" and (name == "Bash" or call.kind == "execute") then
    rows[1] = { "(No content)", hl = "IsovimAcpResultNote" }
  end
  if failed and kind == "output" then
    for _, row in ipairs(rows) do
      row.hl = row.hl or "IsovimAcpError"
    end
  end
  if #rows > M.MAX_BODY then
    local more = #rows - M.MAX_BODY
    rows = vim.list_slice(rows, 1, M.MAX_BODY)
    rows[#rows + 1] = { ("… +%s"):format(plural(more, "line")), hl = "IsovimAcpResultNote" }
  end
  return rows, kind
end

-- Whether a call's output shows whole when nobody has opened or collapsed it.
function M.open_by_default(kind, count)
  return kind == "diff" and count <= M.DIFF_OPEN
end

-- How many of its rows show collapsed (the rest are counted on a note line).
function M.collapsed_count(kind, count)
  if kind == "read" or kind == "diff" then
    return 1
  elseif kind == "write" then
    return math.min(count, 1 + 10)
  end
  return count <= M.PREVIEW + 1 and count or M.PREVIEW
end

-- Markdown in the agent's text

-- Spans for one line of the agent's text: {col, end_col, hl} and conceals {col, end_col}: `code`
-- in Claude's code color, **bold**, a # heading, and a ``` fence dimmed.
function M.markdown(line)
  local spans, conceal = {}, {}
  if line:match("^%s*```") then
    spans[#spans + 1] = { 0, #line, "IsovimAcpNotice" }
    return spans, conceal
  end
  local hs, he = line:find("^[%s●⏺]*#+ ")
  if hs then
    local glyph = line:match("^[●⏺] ") and #line:match("^[●⏺] ") or (line:match("^%s+") and #line:match("^%s+") or 0)
    conceal[#conceal + 1] = { glyph, he }
    spans[#spans + 1] = { he, #line, "IsovimAcpHeading" }
  end
  local init = 1
  while true do
    local s, e = line:find("`[^`]+`", init)
    if not s then
      break
    end
    conceal[#conceal + 1] = { s - 1, s }
    conceal[#conceal + 1] = { e - 1, e }
    spans[#spans + 1] = { s, e - 1, "IsovimAcpCode" }
    init = e + 1
  end
  init = 1
  while true do
    local s, e = line:find("%*%*[^%*]+%*%*", init)
    if not s then
      break
    end
    conceal[#conceal + 1] = { s - 1, s + 1 }
    conceal[#conceal + 1] = { e - 2, e }
    spans[#spans + 1] = { s + 1, e - 2, "IsovimAcpBold" }
    init = e + 1
  end
  return spans, conceal
end

return M
