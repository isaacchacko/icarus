-- Links: a one-line pointer to anything in isovim, written as an address in text, so an agent's
-- words can point at what they mention and you go there with <Tab>:
--   iso:agent/<owner>/<repo>/aN          an agent's chat (root/aN, general/aN too)
--   iso:thread/<owner>/<repo>#t3          a thread
--   iso:task/<owner>/<repo>#k3            a task of the board's
--   iso:pr/<owner>/<repo>#12              a PR, on GitHub; o instead opens its view here
--   iso:surface/<owner>/<repo>/<name>     a surface (the PRs surface is PRs)
--   iso:page/<owner>/<repo>/<name>[#c4]   a page, at a comment
--   iso:file/<path>                       a file or folder (absolute; ~ is home)
--   http(s)://...                         a web page: a dev server on localhost or 127.0.0.1:<port>,
--                                         a preview deploy, a dashboard (a GitHub PR's URL is a PR,
--                                         and goes to that URL)
-- A bare <repo> in place of <owner>/<repo> means the one repo on this host of that name; with two,
-- it's refused rather than guessed. An address that leads nowhere is drawn as broken, and opening
-- one says why, in one notification per address and reason, not one per try.
-- In a chat, a thread, a page or a PR's view each address is drawn as a chip in its place: the
-- target's glyph, a short label and how it is (an agent working or idle, a PR's state, a thread
-- open or resolved, a file missing), the line exactly as long as the chip, and a side table (an
-- extmark per chip) keeps which address each one is, for <Tab>, gf and a yank, which gives the
-- address. A chip whose target changed (an agent now idle) is drawn again as you come back to its
-- buffer. <Tab> in normal mode with the cursor on one opens its target as a tab, gf too; elsewhere
-- <Tab> is vim's own (<C-i>, the jump forward). ]l and [l walk them, wrapping, with whatever else
-- the buffer can land on (a chat's images and waiting questions). A web page opens in isovim's Chrome (iso browser
-- open: a background window, so it never takes your focus), or the system's browser when that isn't
-- running; a localhost one's chip says down, dim, while nothing listens on its port (a connect,
-- in the background, at most every 30s). A router surfaces one with iso router surface link (in
-- the Inbox until you open it, then under Files) and prints one with iso <role> link <thing>.
local store = require("isovim.store")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_links")

local NBSP = "\194\160"
M.NBSP = NBSP

-- Where an address ends: before white space, a closing bracket or quote, or trailing punctuation
-- (or a bold's closing asterisks).
local WORD = "[^%s%)%]>\"'`]"
local STARTS = { "iso:%a+/" .. WORD, "https?://" .. WORD }

-- Every address written in text, iso: ones and web pages: {from, to, address} (byte columns, to
-- exclusive), in order. One holding a placeholder (https://host/<entity>?a=1, /{id}/) is a template,
-- nothing you can open, so it isn't one: it stays as written, all of it up to the next white space.
function M.scan(text)
  local found, at = {}, 1
  while true do
    local from
    for _, start in ipairs(STARTS) do
      local here = text:find(start, at)
      from = here and math.min(from or here, here) or from
    end
    if not from then
      return found
    end
    local raw = text:match("^" .. WORD .. "+", from)
    local angle = raw:find("<", 1, true)
    local brace = raw:find("{", 1, true)
    if (angle and text:match("^<[%w_][^<>\n]*>", from + angle - 1)) or (brace and text:match("^{+[%w_][^{}\n]*}", from + brace - 1)) then
      at = text:find("%s", from) or #text + 1
    else
      -- An angle bracket that opens no placeholder (a tag after it) ends it.
      local address = (angle and raw:sub(1, angle - 1) or raw):gsub("[%.,;:!?%*]+$", "")
      if address:match("^iso:%a+/.") or address:match("^https?://.") then
        found[#found + 1] = { from - 1, from - 1 + #address, address }
      end
      at = from + #raw
    end
  end
end

-- The addresses in a line, as M.scan finds them, but for one inside `code`.
function M.find(line)
  return vim.tbl_filter(function(link)
    local _, ticks = line:sub(1, link[1]):gsub("`", "")
    return ticks % 2 == 0
  end, M.scan(line))
end

-- An address's parts: kind and the rest, as {kind, repo?, id?, path?, fragment?}; nil if it isn't one.
function M.parse(addr)
  local scheme, host, path = (addr or ""):match("^(https?)://([^/?#]+)(.*)$")
  if scheme then
    local pr_repo, pr_n = addr:match("^https?://github%.com/([^/]+/[^/]+)/pull/(%d+)")
    if pr_repo then
      return { kind = "pr", repo = pr_repo:lower(), id = pr_n }
    end
    return { kind = "url", url = addr, host = host, path = path }
  end
  local kind, rest = (addr or ""):match("^iso:(%a+)/(.+)$")
  if not kind then
    return nil
  end
  if kind == "agent" then
    local ws, id = rest:match("^(.+)/(a%d+)$")
    return ws and { kind = kind, ws = ws, id = id }
  elseif kind == "thread" or kind == "pr" or kind == "task" then
    local repo, id = rest:match("^(.+)#(%w+)$")
    return repo and { kind = kind, repo = repo:lower(), id = id }
  elseif kind == "surface" or kind == "page" then
    local repo, name, fragment = rest:match("^(.+)/([^/#]+)#?(.*)$")
    return repo and { kind = kind, repo = repo:lower(), name = name, fragment = fragment ~= "" and fragment or nil }
  elseif kind == "file" then
    return { kind = kind, path = vim.fs.normalize(rest:sub(1, 1) == "/" and rest or ("/" .. rest)) }
  end
end

local function short(path)
  return vim.fn.fnamemodify(path, ":~")
end

-- The repo key a name in an address means: as written if it has its owner (or is root or general),
-- else the one repo on this host of that name. Nil and why with none, or with several.
---@return string? repo, string? why
local function whole_repo(name)
  if name:find("/", 1, true) or store.pseudo[name] or name == "_" then
    return name
  end
  local found = vim.tbl_filter(function(key)
    return (key:match("/([^/]+)$") or ""):lower() == name:lower()
  end, require("isovim.surfaces").repos())
  if #found == 1 then
    return found[1]
  elseif #found > 1 then
    return nil, ("%s could be %s: write it as <owner>/<repo>"):format(name, table.concat(found, " or "))
  end
  return nil, ("no repo on this host is named %s: write it as <owner>/<repo>"):format(name)
end

-- What an address points at, as drawn and opened: {glyph, hl, label, status?, status_hl?, open(),
-- secondary()?, its other way to open, which only a PR has},
-- or nil and why not.
function M.resolve(addr)
  local p = M.parse(addr)
  if not p then
    return nil, addr .. " isn't an isovim address"
  end
  local why
  if p.repo then
    p.repo, why = whole_repo(p.repo)
  elseif p.kind == "agent" and not store.agent(p.ws, p.id) then
    p.ws, why = whole_repo(p.ws)
  end
  if why then
    return nil, why
  end
  if p.kind == "agent" then
    local spec = store.agent(p.ws, p.id)
    if not spec then
      return nil, "no agent " .. p.ws .. "/" .. p.id
    end
    local glyph, hl = require("isovim.icons").get(spec.kind or "claude")
    local state = require("isovim.status").get(p.ws, p.id)
    return { glyph = glyph, hl = hl, label = spec.name or p.id, status = state,
      status_hl = state == "working" and "DiagnosticInfo" or state == "attention" and "DiagnosticWarn" or "Comment",
      open = function()
        require("isovim").open(p.ws, p.id)
      end }
  elseif p.kind == "thread" then
    local threads = require("isovim.threads")
    local entries = threads.read(p.repo, p.id)
    if not entries or not entries[1] then
      return nil, ("%s has no thread %s"):format(p.repo, p.id)
    end
    local info = threads.summary(entries)
    return { glyph = "\u{f086}", hl = "Special", label = info.title, status = info.status,
      status_hl = info.status == "open" and "DiagnosticOk" or "Comment",
      open = function()
        require("isovim.acp.chat").open_thread(p.repo, p.id)
      end }
  elseif p.kind == "task" then
    local entry = require("isovim.surfaces").task_entry(p.repo, p.id)
    if not entry then
      return nil, ("%s has no task %s"):format(p.repo, p.id)
    end
    local chunk = require("isovim.sidebar").surface_chunks(entry)[1]
    return { glyph = chunk[1], hl = chunk[2], label = ("%s %s"):format(p.id, entry.title),
      status = require("isovim.board_tasks").COLUMN_NAMES[entry.column], status_hl = "Comment",
      open = function()
        require("isovim.surfaces").open(entry)
      end }
  elseif p.kind == "pr" then
    local url = ("https://github.com/%s/pull/%s"):format(p.repo, p.id)
    local pr = {}
    for _, repo in ipairs({ p.repo, require("isovim").current_scope }) do
      for cached_url, each in pairs(repo and require("isovim.prs").cached(repo) or {}) do
        if cached_url:lower() == url:lower() then
          pr, url = each, cached_url
        end
      end
    end
    local state = pr.state == "MERGED" and "merged" or pr.state == "CLOSED" and "closed" or pr.isDraft and "draft"
      or pr.state and "open" or nil
    return { glyph = "\u{f407}", hl = "Special", label = ("#%s%s"):format(p.id, pr.title and (" " .. pr.title) or ""),
      status = state, status_hl = state == "merged" and "DiagnosticHint" or state == "closed" and "DiagnosticError"
        or state == "open" and "DiagnosticOk" or "Comment",
      open = function()
        M.open_url(addr:match("^https?://") and addr or url)
      end,
      secondary = function()
        require("isovim.pr_view").open(p.repo, url)
      end }
  elseif p.kind == "surface" or p.kind == "page" then
    local surfaces = require("isovim.surfaces")
    local entry = vim.iter(surfaces.list(p.repo)):find(function(each)
      return each.name == p.name
    end)
    if not entry then
      return nil, ("%s has no %s %s"):format(p.repo, p.kind, p.name)
    end
    local chunk = require("isovim.sidebar").surface_chunks(entry)[1]
    return { glyph = chunk[1], hl = chunk[2], label = entry.title or entry.name,
      status = entry.needs_you and "waiting on you" or nil, status_hl = "DiagnosticWarn",
      open = function()
        surfaces.open(entry)
        if p.fragment and entry.type == "page" then
          -- At the comment: the page's view places its comments as it draws them.
          vim.schedule(function()
            local view = require("isovim.surface_view").views[p.repo .. "/" .. p.name]
            local placed = view and vim.iter(view.placed or {}):find(function(each)
              return each.comment.id == p.fragment
            end)
            if placed then
              pcall(vim.api.nvim_win_set_cursor, 0, { placed.first, 0 })
            end
          end)
        end
      end }
  elseif p.kind == "url" then
    local path = p.path:gsub("[?#].*$", ""):gsub("/$", "")
    local local_host = p.host:match("^localhost") or p.host:match("^127%.0%.0%.1") or p.host:match("^0%.0%.0%.0")
    local up = local_host and M.reachable(p.host)
    return { glyph = "\u{f0ac}", hl = "Special", label = p.host .. (#path > 0 and #path <= 20 and path or ""),
      status = up == false and "down" or nil, status_hl = "Comment",
      open = function()
        M.open_url(p.url)
      end }
  elseif p.kind == "file" then
    local path = vim.fn.expand(p.path)
    local stat = vim.uv.fs_stat(path)
    local folder = stat and stat.type == "directory"
    return { glyph = folder and "\u{f07b}" or "\u{f15b}", hl = "Directory", label = vim.fs.basename(path),
      status = not stat and "missing" or nil, status_hl = "DiagnosticWarn",
      open = function()
        if folder then
          require("isovim").reveal(require("isovim").current, path)
        elseif stat then
          require("isovim").show(path)
        else
          vim.notify("isovim: " .. short(path) .. " doesn't exist", vim.log.levels.WARN)
        end
      end }
  end
  return nil, "isovim doesn't know links to " .. p.kind
end

-- Opens a web page in isovim's Chrome (iso browser open: a background window, so your focus stays
-- where it is), or the system's browser when that fails (isovim's Chrome isn't running).
function M.open_url(url)
  vim.system({ require("isovim.panes").bin, "browser", "open", url }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      vim.ui.open(url)
    end
  end))
end

-- Whether something listens on a local host:port, as last seen: true, false, or nil not known yet.
-- A connect (in the background, a second at most) runs when what's known is over 30s old; when it
-- says otherwise than before, the chips drawn are drawn again.
_G.isovim_link_reach = _G.isovim_link_reach or {}
local reach = _G.isovim_link_reach

function M.reachable(host)
  local name, port = host:match("^([^:]+):(%d+)$")
  name, port = name or host, tonumber(port) or 80
  local key = name .. ":" .. port
  local known = reach[key]
  if not known or vim.uv.now() - known.at > 30000 then
    reach[key] = { at = vim.uv.now(), up = known and known.up }
    local tcp = vim.uv.new_tcp()
    local timer = vim.uv.new_timer()
    local function done(up)
      if timer:is_closing() then
        return
      end
      timer:close()
      if not tcp:is_closing() then
        tcp:close()
      end
      local was = reach[key].up
      reach[key].up = up
      if was ~= up then
        vim.schedule(function()
          M.refresh_all()
        end)
      end
    end
    timer:start(1000, 0, function()
      done(false)
    end)
    local ip = name == "localhost" and "127.0.0.1" or name == "0.0.0.0" and "127.0.0.1" or name
    local ok = pcall(tcp.connect, tcp, ip, port, function(err)
      done(err == nil)
    end)
    if not ok then
      done(false)
    end
  end
  return reach[key] and reach[key].up
end

-- A chip's parts, {text, hl}: the target's glyph, its label, how it is; an address that leads
-- nowhere, a broken link's glyph, the word and the address, on a colored ground. sep joins them (a no-break space keeps a box's
-- wrapping from cutting one).
function M.parts(addr, sep)
  sep = sep or " "
  local target = M.resolve(addr)
  if not target then
    return { { "\u{f127}" .. sep .. "broken" .. sep, "IsovimLinkBroken" }, { (addr:gsub("^iso:", "")), "IsovimLinkBroken" } }
  end
  local label = target.label:gsub(" ", sep)
  local parts = { { target.glyph .. sep, target.hl or "Special" }, { label, "IsovimLink" } }
  if target.status then
    parts[#parts + 1] = { sep .. "·" .. sep .. target.status:gsub(" ", sep), target.status_hl or "Comment" }
  end
  return parts
end

function M.chip(addr, sep)
  return table.concat(vim.tbl_map(function(part)
    return part[1]
  end, M.parts(addr, sep)))
end

vim.api.nvim_set_hl(0, "IsovimLink", { default = true, link = "Underlined" })
vim.api.nvim_set_hl(0, "IsovimLinkBroken", { default = true, link = "DiagnosticVirtualTextError" })

-- The side table: which address each chip drawn in a buffer is, by its extmark.
_G.isovim_links = _G.isovim_links or {}
local drawn = _G.isovim_links

-- Notes that the chip at row, col..end_col of buf is addr (its parts' highlights drawn there too).
function M.register(buf, row, col, end_col, addr, parts)
  drawn[buf] = drawn[buf] or {}
  local id = vim.api.nvim_buf_set_extmark(buf, NS, row, col, { end_col = end_col, right_gravity = false,
    end_right_gravity = true })
  drawn[buf][id] = addr
  local at = col
  for _, part in ipairs(parts or M.parts(addr)) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, at, { end_col = math.min(at + #part[1], end_col), hl_group = part[2],
      priority = 300 })
    at = at + #part[1]
  end
  return id
end

-- Forgets the chips on rows from..to, about to be written over.
function M.forget(buf, from, to)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { from, 0 }, { to - 1, -1 }, {})) do
    if drawn[buf] then
      drawn[buf][mark[1]] = nil
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, from, to)
end

-- The chips drawn in buffer from become to's, ids and all, in place of what it had: a chat drawn again
-- in a buffer of its own takes over its old one (isovim.acp.chat's swap).
function M.move(from, to)
  M.forget(to, 0, vim.api.nvim_buf_line_count(to))
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(from, NS, 0, -1, { details = true })) do
    local opts = mark[4]
    opts.ns_id, opts.id = nil, mark[1]
    vim.api.nvim_buf_set_extmark(to, NS, mark[2], mark[3], opts)
  end
  drawn[to], drawn[from] = drawn[from], nil
end

-- Writes into buf with fn: the buffer made modifiable meanwhile (the chat passes its own writer,
-- which keeps its guard and following right).
local function plain_write(buf)
  return function(fn)
    local was = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    pcall(fn)
    vim.bo[buf].modifiable = was
    vim.bo[buf].modified = false
  end
end

-- Draws the addresses written in rows from..to (0-based, to exclusive; -1 the end) of buf as
-- chips, each in place of its address. write(fn) makes the change (default: modifiable meanwhile).
function M.substitute(buf, from, to, write)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  write = write or plain_write(buf)
  from = from or 0
  -- The whole buffer drawn again (a view's redraw): its old chips went with its old lines.
  if from == 0 and (to or -1) == -1 then
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    drawn[buf] = nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, from, to or -1, false)
  for i, line in ipairs(lines) do
    local found = line:find("iso:", 1, true) and M.find(line) or {}
    for j = #found, 1, -1 do
      local link, row = found[j], from + i - 1
      local parts = M.parts(link[3])
      local text = table.concat(vim.tbl_map(function(part)
        return part[1]
      end, parts))
      write(function()
        vim.api.nvim_buf_set_text(buf, row, link[1], row, link[2], { text })
      end)
      M.register(buf, row, link[1], link[1] + #text, link[3], parts)
    end
  end
end
-- Kept under its old name for the views that call it.
M.decorate = M.substitute

-- The chips drawn in buf again where what they say changed (an agent now idle, a thread resolved):
-- each one's line changes length with it.
function M.refresh(buf, write)
  if not (drawn[buf] and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end
  write = write or plain_write(buf)
  -- Over a copy: drawing a chip again takes its old entry out and puts a new one in.
  for id, addr in pairs(vim.deepcopy(drawn[buf])) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, { details = true })
    -- Gone with its text (a chat drawn again, a line rewritten): forgotten, never written back.
    if not mark[1] or (mark[3].end_col or mark[2]) <= mark[2] or (mark[3].end_row or mark[1]) ~= mark[1] then
      if mark[1] then
        vim.api.nvim_buf_del_extmark(buf, NS, id)
      end
      drawn[buf][id] = nil
    else
      local row, col, end_col = mark[1], mark[2], mark[3].end_col or mark[2]
      local now = vim.api.nvim_buf_get_text(buf, row, col, row, end_col, {})[1] or ""
      local sep = now:find("\194\160", 1, true) and "\194\160" or " "
      local parts = M.parts(addr, sep)
      local text = table.concat(vim.tbl_map(function(part)
        return part[1]
      end, parts))
      if text ~= now then
        for _, other in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { row, col }, { row, end_col }, { overlap = false })) do
          if other[3] >= col and other[3] < end_col then
            vim.api.nvim_buf_del_extmark(buf, NS, other[1])
            drawn[buf][other[1]] = nil
          end
        end
        local grow = vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(now)
        write(function()
          vim.api.nvim_buf_set_text(buf, row, col, row, end_col, { text })
          -- In a box (a thread's post, a PR's description) the padding before its right edge takes
          -- the difference, so the edge stays put while there's room.
          local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
          local pad_from, pad_to = line:find(" +│$")
          if pad_from and pad_from > col + #text and grow ~= 0 then
            local spaces = pad_to - pad_from + 1 - #"│"
            local keep = math.max(1, spaces - grow)
            vim.api.nvim_buf_set_text(buf, row, pad_from - 1, row, pad_from - 1 + spaces, { (" "):rep(keep) })
          end
        end)
        M.register(buf, row, col, col + #text, addr, parts)
      end
    end
  end
end

-- The chip (or address written out) under the cursor in the current window, if any.
function M.at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    local addr = (drawn[buf] or {})[mark[1]]
    if addr and col >= mark[3] and col < (mark[4].end_col or mark[3]) then
      return addr
    end
  end
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  for _, link in ipairs(M.find(line)) do
    if col >= link[1] and col < link[2] then
      return link[3]
    end
  end
end

-- Moves the cursor to the next or previous stop in buf, wrapping: its links, drawn or not, and what
-- opts.stops adds as {row, col}, 0-based, up to row opts.last. False with none.
---@return boolean
local function walk(buf, opts, direction)
  local last = opts.last and opts.last() or vim.api.nvim_buf_line_count(buf) - 1
  local stops = opts.stops and opts.stops() or {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    -- One whose text was written over has closed up: it's no chip now.
    if (drawn[buf] or {})[mark[1]] and (mark[4].end_col or mark[3]) > mark[3] then
      stops[#stops + 1] = { mark[2], mark[3] }
    end
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, last + 1, false)) do
    for _, link in ipairs(M.find(line)) do
      stops[#stops + 1] = { i - 1, link[1] }
    end
  end
  stops = vim.tbl_filter(function(stop)
    return stop[1] <= last
  end, stops)
  if #stops == 0 then
    return false
  end
  table.sort(stops, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local target
  for i = direction > 0 and 1 or #stops, direction > 0 and #stops or 1, direction do
    local stop = stops[i]
    local past = stop[1] > row or (stop[1] == row and stop[2] > col)
    local before = stop[1] < row or (stop[1] == row and stop[2] < col)
    if direction > 0 and past or direction < 0 and before then
      target = stop
      break
    end
  end
  target = target or stops[direction > 0 and 1 or #stops]
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
  vim.cmd("normal! zv")
  return true
end

-- What each address was last warned about, so a <Tab> on it again doesn't stack another notification
-- (its chip still says broken); a new reason is told.
_G.isovim_link_warned = _G.isovim_link_warned or {}
local warned = _G.isovim_link_warned

-- Opens what addr points at; false, said why, when it can't.
function M.open(addr)
  local target, err = M.resolve(addr)
  if not target then
    if warned[addr] ~= err then
      warned[addr] = err
      vim.notify("isovim: " .. tostring(err), vim.log.levels.WARN)
    end
    return false
  end
  vim.cmd.stopinsert()
  target.open()
  return true
end

-- The other way to open the link under the cursor, if it has one.
local function secondary_here()
  local addr = M.at_cursor()
  local target = addr and M.resolve(addr)
  return target and target.secondary
end

-- Whether o here means the link's other way to open, so an expr map needn't open it itself.
function M.has_secondary()
  return secondary_here() ~= nil
end

-- o on a link with another way to open (a PR: its view here, where its primary is the browser): opens
-- it. False on anything else, where o keeps whatever it means in that view.
---@return boolean
function M.secondary()
  local open = secondary_here()
  if not open then
    return false
  end
  vim.cmd.stopinsert()
  open()
  return true
end

-- A yank over chips gives their addresses: each chip on the yanked lines, its text replaced.
local function yanked(buf)
  local event = vim.v.event
  if event.operator ~= "y" or not drawn[buf] then
    return
  end
  local first, last = vim.fn.line("'[") - 1, vim.fn.line("']") - 1
  local contents = vim.deepcopy(event.regcontents)
  local changed = false
  for row = first, last do
    local i = row - first + 1
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { row, 0 }, { row, -1 }, { details = true })) do
      local addr = drawn[buf][mark[1]]
      if addr and contents[i] then
        local chip = vim.api.nvim_buf_get_text(buf, row, mark[3], row, mark[4].end_col or mark[3], {})[1] or ""
        local s = chip ~= "" and contents[i]:find(chip, 1, true)
        if s then
          contents[i] = contents[i]:sub(1, s - 1) .. addr .. contents[i]:sub(s + #chip)
          changed = true
        end
      end
    end
  end
  if changed then
    vim.fn.setreg(event.regname ~= "" and event.regname or '"', contents, event.regtype)
  end
end

-- <Tab> on a link opens it, else it's vim's own (the jump forward); gf too, unless the buffer maps
-- gf itself (the chat's gf asks M.at_cursor first). o is the link's other way to open (M.secondary),
-- unless the buffer maps o itself, which then asks M.secondary first. Its chips are drawn again on coming back to it,
-- and a yank of them gives their addresses. write as M.substitute takes it.
_G.isovim_link_writers = _G.isovim_link_writers or {}
local writers = _G.isovim_link_writers

-- Every buffer's chips drawn again where what they say changed (a dev server came up or went).
function M.refresh_all()
  for buf in pairs(drawn) do
    if vim.api.nvim_buf_is_loaded(buf) then
      require("isovim.safe").wrap("a buffer's links", M.refresh)(buf, writers[buf])
    end
  end
end

---@param opts? {stops?: fun(): {[1]: integer, [2]: integer}[], last?: fun(): integer, open?: fun(): boolean}
function M.attach(buf, write, opts)
  writers[buf] = write
  opts = opts or {}
  vim.keymap.set("n", "<Tab>", function()
    local addr = M.at_cursor()
    if addr then
      return M.open(addr)
    elseif opts.open and opts.open() then
      return
    end
    vim.api.nvim_feedkeys(vim.v.count1 .. vim.keycode("<C-i>"), "n", false)
  end, { buffer = buf, desc = "isovim: open the link under the cursor (else jump forward)" })
  for lhs, direction in pairs({ ["]l"] = 1, ["[l"] = -1 }) do
    vim.keymap.set("n", lhs, function()
      for _ = 1, vim.v.count1 do
        if not walk(buf, opts, direction) then
          return vim.api.nvim_echo({ { "no links here", "Comment" } }, false, {})
        end
      end
    end, { buffer = buf, desc = ("isovim: the %s link, image or waiting question"):format(direction > 0 and "next" or "previous") })
  end
  local function mapped(lhs)
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true).buffer == 1
    end)
  end
  if not mapped("o") then
    vim.keymap.set("n", "o", function()
      if not M.secondary() then
        vim.api.nvim_feedkeys("o", "n", false)
      end
    end, { buffer = buf, desc = "isovim: a PR's link: its view here (else o)" })
  end
  if not mapped("gf") then
    vim.keymap.set("n", "gf", function()
      local addr = M.at_cursor()
      if addr then
        return M.open(addr)
      end
      pcall(vim.cmd, "normal! gf")
    end, { buffer = buf, desc = "isovim: open the link (or file) under the cursor" })
  end
  local group = vim.api.nvim_create_augroup("isovim_links_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      require("isovim.safe").wrap("a buffer's links", require("isovim.links").refresh)(buf, write)
    end,
  })
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    buffer = buf,
    callback = function()
      require("isovim.safe").wrap("a yank's links", yanked)(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      drawn[buf] = nil
    end,
  })
end

-- The address of a thing named as you'd say it: an agent (owner/repo/aN, or aN in repo), a PR
-- (#12, 12, owner/repo#12 or its URL), a thread (t3), a task (k3), a page or surface's name, or a path.
---@return string? address, string? err
function M.address(thing, repo)
  thing = vim.trim(thing or "")
  -- A web page: itself (a PR's URL becomes the PR below); localhost:3000 gets its http://.
  if thing:match("^localhost[:/]") or thing:match("^localhost$") or thing:match("^127%.0%.0%.1[:/]") then
    thing = "http://" .. thing
  end
  if thing:match("^https?://[^/]") and not thing:match("github%.com/[^/]+/[^/]+/pull/%d+") then
    return thing
  end
  local url_repo, url_n = thing:match("github%.com/([^/]+/[^/]+)/pull/(%d+)")
  if url_repo then
    return ("iso:pr/%s#%s"):format(url_repo:lower(), url_n)
  end
  local pr_repo, pr_n = thing:match("^([%w._-]+/[%w._-]+)#(%d+)$")
  if pr_repo then
    return ("iso:pr/%s#%s"):format(pr_repo:lower(), pr_n)
  end
  local n = thing:match("^#?(%d+)$")
  if n and repo and not store.is_pseudo(repo) then
    return ("iso:pr/%s#%s"):format(repo, n)
  end
  local ws, id = thing:match("^(.+)/(a%d+)$")
  if ws and store.agent(ws, id) then
    return ("iso:agent/%s/%s"):format(ws, id)
  end
  if thing:match("^a%d+$") and repo and store.agent(repo, thing) then
    return ("iso:agent/%s/%s"):format(repo, thing)
  end
  if thing:match("^t%d+$") and repo and vim.uv.fs_stat(require("isovim.threads").file(repo, thing)) then
    return ("iso:thread/%s#%s"):format(repo, thing)
  end
  if thing:match("^k%d+$") and repo and require("isovim.board_tasks").read(repo)[thing] then
    return ("iso:task/%s#%s"):format(repo, thing)
  end
  local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(thing), ":p")):gsub("(.)/$", "%1")
  if vim.uv.fs_stat(path) then
    return "iso:file/" .. path:gsub("^/", "")
  end
  if repo then
    local entry = vim.iter(require("isovim.surfaces").list(repo)):find(function(each)
      return each.name == thing and each.type ~= "question"
    end)
    if entry then
      return ("iso:%s/%s/%s"):format(entry.type == "page" and "page" or "surface", repo, entry.name)
    end
  end
  return nil, ("%s isn't an agent, PR, thread, task, page, surface or path isovim knows"):format(thing)
end

return M
