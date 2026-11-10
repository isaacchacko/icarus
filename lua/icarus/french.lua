-- French, a few words at a time: in what agents say (each chat's thread, and a task's portal with the
-- router's reply under it), the English words you've learned show as their French, in place, the rest
-- of the sentence English: "I'll vérifier the fichier and ensuite push." It's drawn over the text, never in it: the buffer, the transcript and what
-- the agent reads stay English.
--
-- Bergamot translates each line locally (bin/icarus-french, a process of its own), and its alignment
-- says which French a word became there, so a word reads as the French it is in that sentence. A word
-- that split (don't -> ne ... pas) stays English. Code, inline code, paths, links, tables and your own
-- messages are left alone.
--
-- The words come in on a schedule: R a day (5 to start), in the order the agents use them most, from
-- their replies in Claude's transcripts, skipping words that don't translate cleanly. <leader>L sets R
-- from now on (0 stalls it, 0.5 is one every two days), <leader>F puts the English back and takes it
-- away again, and the cursor on a French word shows its English. ~/.icarus/french/ keeps what you've
-- learned (state.json: the words with the day each came, the rate and its changes) and the ranking.
local M = {}

local T = require("icarus.theme")

local DIR = (vim.env.ICARUS_HOME or (vim.env.HOME .. "/.icarus")) .. "/french"
local STATE = DIR .. "/state.json"
local RANKED = DIR .. "/ranked.json"
local ENGINE = vim.env.HOME .. "/.local/share/icarus/french"
local PYTHON = ENGINE .. "/venv/bin/python"
local SCRIPT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))) .. "/bin/icarus-french"
local NS = vim.api.nvim_create_namespace("icarus_french")
local THREAD = vim.api.nvim_create_namespace("icarus_thread")
local RATE = 5
-- A word is ranked once it's been seen this often and translated cleanly this share of the time.
local MIN_COUNT, MIN_CLEAN = 3, 0.6
local RANK_EVERY = 7 * 86400
-- The buffers that are what agents say: everything above their composer but your messages.
local FILETYPES = { icarus_thread = true, icarus_portal = true }
local TRANSCRIPTS = 400
local DEBOUNCE_MS = 300
-- How far back a thread is drawn: its last rows, where you read.
local RECENT = 300

-- In _G, so a hot reload keeps the translator, its answers and the buffers it draws on.
_G.icarus_french = _G.icarus_french or { cache = {}, waiting = {}, bufs = {}, next = 0 }
local live = _G.icarus_french

local function read_json(path)
  local file = io.open(path)
  if not file then
    return nil
  end
  local ok, data = pcall(vim.json.decode, file:read("*a"))
  file:close()
  return ok and data or nil
end

local function write_json(path, data)
  vim.fn.mkdir(DIR, "p")
  local file = assert(io.open(path, "w"))
  file:write(vim.json.encode(data))
  file:close()
end

local function today()
  return os.date("%Y-%m-%d")
end

local function day_seconds(day)
  local y, m, d = day:match("^(%d+)-(%d+)-(%d+)$")
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

---@return {rate: number, progress: number, day: string, known: {word: string, day: string}[], log: {day: string, rate: number}[], english?: boolean}
local function state()
  if not live.state then
    live.state = read_json(STATE) or { rate = RATE, progress = 0, day = os.date("%Y-%m-%d", os.time() - 86400),
      known = {}, log = { { day = today(), rate = RATE } } }
  end
  return live.state
end

local function save()
  write_json(STATE, state())
end

local function known_set()
  local set = {}
  for _, each in ipairs(state().known) do
    set[each.word] = true
  end
  return set
end

-- The translator

local function answer(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    return
  end
  if message.ready then
    live.ready = true
    for _, send in ipairs(live.backlog or {}) do
      send()
    end
    live.backlog = nil
    return
  end
  local done = live.waiting[message.id]
  live.waiting[message.id] = nil
  if done then
    done(message)
  end
end

local function start()
  if live.proc or live.installing then
    return
  end
  if vim.fn.executable(PYTHON) == 0 then
    live.installing = true
    vim.notify("French: installing Bergamot and its English→French model (once)…")
    vim.system({ "python3", SCRIPT, "--install" }, { text = true }, vim.schedule_wrap(function(result)
      live.installing = false
      if result.code ~= 0 then
        return vim.notify("French: the install failed: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
      end
      start()
    end))
    return
  end
  local partial = ""
  live.ready = false
  live.proc = vim.system({ "arch", "-x86_64", PYTHON, SCRIPT }, {
    stdin = true,
    stdout = vim.schedule_wrap(function(_, data)
      if not data then
        return
      end
      partial = partial .. data
      while true do
        local nl = partial:find("\n", 1, true)
        if not nl then
          break
        end
        local line = partial:sub(1, nl - 1)
        partial = partial:sub(nl + 1)
        answer(line)
      end
    end),
  }, vim.schedule_wrap(function()
    live.proc, live.ready = nil, false
    live.waiting = {}
  end))
end

-- Sends a request; done gets its answer.
local function ask(request, done)
  start()
  live.next = live.next + 1
  request.id = live.next
  live.waiting[request.id] = done
  local function send()
    if live.proc then
      live.proc:write(vim.json.encode(request) .. "\n")
    end
  end
  if live.ready then
    send()
  else
    live.backlog = live.backlog or {}
    table.insert(live.backlog, send)
  end
end

-- The schedule

-- The agents' words, most used first, from the newest transcripts of icarus's chats; ranked again a
-- week on.
local function rank(done)
  local ranked = read_json(RANKED)
  if ranked and ranked.made and os.time() - ranked.made < RANK_EVERY then
    return done(ranked.words)
  end
  local files = vim.fn.glob(vim.env.HOME .. "/.claude/projects/*icarus-tasks*/*.jsonl", false, true)
  table.sort(files, function(a, b)
    return (vim.uv.fs_stat(a) or { mtime = { sec = 0 } }).mtime.sec > (vim.uv.fs_stat(b) or { mtime = { sec = 0 } }).mtime.sec
  end)
  files = vim.list_slice(files, 1, TRANSCRIPTS)
  ask({ rank = files }, function(message)
    if not message.rank then
      return vim.notify("French: ranking failed: " .. tostring(message.error), vim.log.levels.WARN)
    end
    local words = {}
    for _, each in ipairs(message.rank) do
      if each.count >= MIN_COUNT and each.clean >= MIN_CLEAN then
        words[#words + 1] = each.word
      end
    end
    write_json(RANKED, { made = os.time(), words = words })
    done(words)
  end)
end

-- The words the days since the last added are owed, at the rate: R a day, a fraction carried over.
function M.tick()
  local s = state()
  local now = today()
  if s.day == now then
    return
  end
  rank(function(words)
    local days = math.max(0, math.floor((day_seconds(now) - day_seconds(s.day)) / 86400 + 0.5))
    s.progress = s.progress + s.rate * days
    s.day = now
    local have = known_set()
    local added = 0
    for _, word in ipairs(words) do
      if s.progress < 1 then
        break
      end
      if not have[word] then
        table.insert(s.known, { word = word, day = now })
        s.progress = s.progress - 1
        added = added + 1
      end
    end
    -- What can't be paid (the ranking ran out) isn't kept owing.
    s.progress = math.min(s.progress, math.max(s.rate, 1))
    save()
    if added > 0 then
      M.redraw()
    end
  end)
end

-- <leader>L: the new words a day from now on.
function M.set_rate()
  local s = state()
  vim.ui.input({ prompt = "New French words a day (0 stalls, 0.5 = one every two days): ", default = tostring(s.rate) },
    function(text)
      local rate = text and tonumber(vim.trim(text))
      if not rate or rate < 0 then
        if text and vim.trim(text) ~= "" then
          vim.notify("French: a number of words a day, 0 or more", vim.log.levels.WARN)
        end
        return
      end
      s.rate = rate
      table.insert(s.log, { day = today(), rate = rate })
      -- A stall owes nothing when it's lifted.
      if rate == 0 then
        s.progress = 0
      end
      save()
      vim.cmd.redrawstatus()
      vim.notify(rate == 0 and "French: stalled; the words you know still show" or ("French: %s new words a day"):format(rate))
    end)
end

-- <leader>F: the English back, or the French again.
function M.toggle()
  local s = state()
  s.english = not s.english
  save()
  M.redraw()
  vim.cmd.redrawstatus()
end

-- The statusline's badge: how many words, at what rate.
function M.badge()
  if not live.state and vim.fn.filereadable(STATE) == 0 then
    return nil
  end
  local s = state()
  local rate = s.rate == math.floor(s.rate) and tostring(math.floor(s.rate)) or tostring(s.rate)
  return (" FR %d · %s/d%s "):format(#s.known, rate, s.english and " · EN" or "")
end

-- Drawing

-- Where in a line nothing is translated: inline code, links and paths, as byte ranges.
local function shielded(line)
  local out = {}
  for _, pattern in ipairs({ "()`[^`]*`()", "()https?://%S+()", "()%S*/%S*()", "()[%w_%-]+%.%a%a?%a?%a?()" }) do
    for from, to in line:gmatch(pattern) do
      out[#out + 1] = { from - 1, to - 1 }
    end
  end
  return out
end

local function inside(ranges, from, to)
  for _, r in ipairs(ranges) do
    if from < r[2] and to > r[1] then
      return true
    end
  end
  return false
end

local function cased(english, french)
  if english:match("^%u") and not english:match("^I$") then
    return vim.fn.toupper(vim.fn.strcharpart(french, 0, 1)) .. vim.fn.strcharpart(french, 1)
  end
  return french
end

-- The rows of buf that are the agent's prose: above the composer, not your message (a prompt row),
-- not in a code fence or a table.
local function prose_rows(buf)
  local stop = require("icarus.acp.compose").start(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, stop, false)
  local prompt = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, THREAD, 0, -1, { details = true })) do
    if mark[4].line_hl_group == "IcarusAcpPrompt" then
      prompt[mark[2]] = true
    end
  end
  local rows, fenced = {}, false
  for i, line in ipairs(lines) do
    local row = i - 1
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced and not prompt[row] and line:match("%a") and row >= stop - RECENT
      and not line:match("^%s*|") and not line:match("^%s*[│┌├└┬┼─]") then
      rows[#rows + 1] = { row, line }
    end
  end
  return rows
end

local function paint(buf, row, line, words, have)
  vim.api.nvim_buf_clear_namespace(buf, NS, row, row + 1)
  local shield = shielded(line)
  for _, w in ipairs(words) do
    local from, to, french = w[1], w[2], w[3]
    local english = line:sub(from + 1, to)
    if have[english:lower()] and not inside(shield, from, to) and french:lower() ~= english:lower() then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, from, { end_col = to, conceal = "",
        virt_text = { { cased(english, french), "IcarusFrench" } }, virt_text_pos = "inline",
        hl_mode = "combine" })
    end
  end
end

-- Draws the French on buf's prose: what's translated now, the rest once Bergamot answers.
function M.draw(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    live.bufs[buf] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local s = state()
  -- A thread nobody's looking at is drawn when it's shown (BufWinEnter).
  if s.english or #s.known == 0 or #vim.fn.win_findbuf(buf) == 0 then
    return
  end
  local have = known_set()
  local todo = {}
  for _, each in ipairs(prose_rows(buf)) do
    local row, line = each[1], each[2]
    local words = live.cache[line]
    if words then
      paint(buf, row, line, words, have)
    else
      todo[#todo + 1] = line
    end
  end
  if #todo > 0 then
    ask({ lines = todo }, function(message)
      for i, line in ipairs(todo) do
        live.cache[line] = message.words and message.words[i] or {}
      end
      -- Drawn again where those lines are now.
      if vim.api.nvim_buf_is_valid(buf) then
        for _, each in ipairs(prose_rows(buf)) do
          local words = live.cache[each[2]]
          if words then
            paint(buf, each[1], each[2], words, have)
          end
        end
      end
    end)
  end
end

-- Every thread drawn again: the words or the toggle changed.
function M.redraw()
  for buf in pairs(live.bufs) do
    M.draw(buf)
  end
end

-- A thread's French drawn again once what streams into it goes quiet.
local function changed(buf)
  local timer = live.bufs[buf]
  if type(timer) ~= "userdata" then
    timer = vim.uv.new_timer()
    live.bufs[buf] = timer
  end
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    M.draw(buf)
  end))
end

-- Each setup is a generation: a buffer attached by older code (before a hot reload) detaches on its
-- next change, and this code attaches it again.
function M.attach(buf)
  live.attached = live.attached or {}
  if live.attached[buf] == live.gen then
    return
  end
  local gen = live.gen
  live.attached[buf] = gen
  live.bufs[buf] = live.bufs[buf] or true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if live.attached[buf] ~= gen then
        return true
      end
      changed(buf)
    end,
    on_detach = function()
      if live.attached[buf] == gen then
        live.bufs[buf], live.attached[buf] = nil, nil
      end
    end,
  })
  changed(buf)
end

-- The cursor on a French word: its English, below.
local function hint()
  local buf = vim.api.nvim_get_current_buf()
  if not live.bufs[buf] then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if col >= mark[3] and col < mark[4].end_col then
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      vim.api.nvim_echo({ { mark[4].virt_text[1][1], "IcarusFrench" }, { "  " .. line:sub(mark[3] + 1, mark[4].end_col), "Comment" } }, false, {})
      live.hinted = true
      return
    end
  end
  if live.hinted then
    live.hinted = false
    vim.api.nvim_echo({ { "" } }, false, {})
  end
end

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusFrench", { fg = T.teal, italic = true })
end

function M.setup()
  live.gen = (live.gen or 0) + 1
  highlights()
  local group = vim.api.nvim_create_augroup("icarus_french", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = vim.tbl_keys(FILETYPES), callback = function(ev)
    M.attach(ev.buf)
  end })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, callback = hint })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function(ev)
    if live.bufs[ev.buf] then
      M.draw(ev.buf)
    end
  end })
  -- Threads and portals open from before (a hot reload): attached now.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and FILETYPES[vim.bo[buf].filetype] then
      M.attach(buf)
    end
  end
  -- A new day's words, checked on start and each hour.
  if live.timer then
    live.timer:stop()
    live.timer:close()
  end
  live.timer = vim.uv.new_timer()
  live.timer:start(0, 3600 * 1000, vim.schedule_wrap(function()
    M.tick()
  end))
end

return M
