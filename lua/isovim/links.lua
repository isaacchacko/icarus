-- Links: a one-line pointer to anything in isovim, written as an address in text, so an agent's
-- words can point at what they mention and you go there with <Tab>:
--   iso:agent/<owner>/<repo>/aN          an agent's chat (root/aN, general/aN too)
--   iso:thread/<repo>#t3                  a thread
--   iso:pr/<owner>/<repo>#12              a PR's view
--   iso:surface/<repo>/<name>             a surface (the Task Board is tasks, the PRs PRs)
--   iso:page/<repo>/<name>[#c4]           a page, at a comment
--   iso:file/<path>                       a file or folder (absolute; ~ is home)
-- In a chat, a thread, a page or a PR's view each address is drawn over (an overlay as wide as the
-- address, so nothing moves or rewraps) as a chip: the target's glyph, a short label and how it is
-- (an agent working or idle, a PR's state and CI, a thread open or resolved, a file missing). <Tab>
-- in normal mode with the cursor on one opens its target as a tab, gf too; elsewhere <Tab> is
-- vim's own (<C-i>, the jump forward). A router surfaces one with iso router surface link, a row
-- under Files, and prints one with iso <role> link <thing>.
local store = require("isovim.store")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_links")

-- Where an address ends: before white space, a closing bracket or quote, or trailing punctuation.
local PATTERN = "()(iso:[%a@][^%s%)%]>\"'`]+)"
local NBSP = "\194\160"

-- Addresses drawn in a box (isovim.boxes: a thread's post, a PR's description) are swapped for a
-- token as wide as a chip, iso:@<n> and no-break spaces, so the box's wrapping never cuts one in
-- two; the token keeps the address here, for this session (a box is drawn again from its source).
_G.isovim_link_tokens = _G.isovim_link_tokens or { by_address = {}, list = {} }
local tokens = _G.isovim_link_tokens
local TOKEN_WIDTH = 28

function M.compact(text)
  return ((text or ""):gsub("iso:%a+/[^%s%)%]>\"'`]+", function(raw)
    local addr = raw:gsub("[%.,;:!?]+$", "")
    local tail = raw:sub(#addr + 1)
    local n = tokens.by_address[addr]
    if not n then
      tokens.list[#tokens.list + 1] = addr
      n = #tokens.list
      tokens.by_address[addr] = n
    end
    local token = "iso:@" .. n
    return token .. NBSP:rep(math.max(1, math.min(TOKEN_WIDTH, vim.fn.strdisplaywidth(addr)) - #token)) .. tail
  end))
end

-- The addresses in a line: {from, to, address} (byte columns, to exclusive); a token's, its address.
function M.find(line)
  local found = {}
  for from, raw in line:gmatch(PATTERN) do
    raw = raw:gsub("[%.,;:!?]+$", "")
    local clean = raw:gsub(NBSP, "")
    local n = clean:match("^iso:@(%d+)$")
    clean = n and tokens.list[tonumber(n)] or clean
    if clean and not clean:match("^iso:@") then
      found[#found + 1] = { from - 1, from - 1 + #raw, clean }
    end
  end
  return found
end

-- An address's parts: kind and the rest, as {kind, repo?, id?, path?, fragment?}; nil if it isn't one.
function M.parse(addr)
  local kind, rest = (addr or ""):match("^iso:(%a+)/(.+)$")
  if not kind then
    return nil
  end
  if kind == "agent" then
    local ws, id = rest:match("^(.+)/(a%d+)$")
    return ws and { kind = kind, ws = ws, id = id }
  elseif kind == "thread" or kind == "pr" then
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

-- What an address points at, as drawn and opened: {glyph, hl, label, status?, status_hl?, open()},
-- or nil and why not.
function M.resolve(addr)
  local p = M.parse(addr)
  if not p then
    return nil, addr .. " isn't an isovim address"
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

-- The chip over an address: as wide as the address, so nothing moves; cut with … when it doesn't fit.
local function chip(addr, width)
  local target = M.resolve(addr)
  local parts = target and {
    { target.glyph .. " ", target.hl or "Special" },
    { target.label, "IsovimLink" },
    target.status and { " · " .. target.status, target.status_hl or "Comment" } or nil,
  } or { { "\u{f127} ", "DiagnosticWarn" }, { addr:gsub("^iso:", ""), "DiagnosticWarn" } }
  local out, left = {}, width
  for _, part in ipairs(parts) do
    if left <= 0 then
      break
    end
    local text = part[1]
    if vim.fn.strdisplaywidth(text) > left then
      while vim.fn.strdisplaywidth(text) > left - 1 do
        text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
      end
      text = text .. "…"
    end
    out[#out + 1] = { text, part[2] }
    left = left - vim.fn.strdisplaywidth(text)
  end
  if left > 0 then
    out[#out + 1] = { (" "):rep(left) }
  end
  return out
end

vim.api.nvim_set_hl(0, "IsovimLink", { default = true, link = "Underlined" })

-- Draws the links in rows from..to (0-based, to exclusive; -1 the end) of buf as chips.
function M.decorate(buf, from, to)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  from, to = from or 0, to or -1
  vim.api.nvim_buf_clear_namespace(buf, NS, from, to)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, from, to, false)) do
    if line:find("iso:", 1, true) then
      for _, link in ipairs(M.find(line)) do
        local width = vim.fn.strdisplaywidth(line:sub(link[1] + 1, link[2]))
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, from + i - 1, link[1], { end_col = link[2],
          virt_text = chip(link[3], width), virt_text_pos = "overlay", hl_mode = "combine", priority = 300 })
      end
    end
  end
end

-- The address under the cursor in the current window, if any.
function M.at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  for _, link in ipairs(M.find(line)) do
    if col >= link[1] and col < link[2] then
      return link[3]
    end
  end
end

-- Opens what addr points at; false, said why, when it can't.
function M.open(addr)
  local target, err = M.resolve(addr)
  if not target then
    vim.notify("isovim: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  vim.cmd.stopinsert()
  target.open()
  return true
end

-- <Tab> on a link opens it, else it's vim's own (the jump forward); gf too, unless the buffer maps
-- gf itself (the chat's gf asks M.at_cursor first). Their chips are drawn again on entering it.
function M.attach(buf)
  vim.keymap.set("n", "<Tab>", function()
    local addr = M.at_cursor()
    if addr then
      return M.open(addr)
    end
    vim.api.nvim_feedkeys(vim.v.count1 .. vim.keycode("<C-i>"), "n", false)
  end, { buffer = buf, desc = "isovim: open the link under the cursor (else jump forward)" })
  if vim.fn.maparg("gf", "n", false, true).buffer ~= 1 then
    vim.keymap.set("n", "gf", function()
      local addr = M.at_cursor()
      if addr then
        return M.open(addr)
      end
      pcall(vim.cmd, "normal! gf")
    end, { buffer = buf, desc = "isovim: open the link (or file) under the cursor" })
  end
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("isovim_links_" .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      require("isovim.links").decorate(buf)
    end,
  })
end

-- The address of a thing named as you'd say it: an agent (owner/repo/aN, or aN in repo), a PR
-- (#12, 12, owner/repo#12 or its URL), a thread (t3), a page or surface's name, or a path.
---@return string? address, string? err
function M.address(thing, repo)
  thing = vim.trim(thing or "")
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
  return nil, ("%s isn't an agent, PR, thread, page, surface or path isovim knows"):format(thing)
end

return M
