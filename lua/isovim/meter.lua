-- The style meter in the sidebar's title: a rank for how many agents run on this host at once,
-- e.g. "S (9) - swarming". A rank-up flashes the letter; the top rank shimmers.
local M = {}

-- {fewest agents, letter, phrase, color, shimmer color}; the rank is the last one reached.
local RANKS = {
  { 0, "–", "quiet" },
  { 1, "D", "dabbling", "#a9b1d6" },
  { 2, "C", "cooking", "#7aa2f7" },
  { 3, "B", "buzzing", "#7dcfff" },
  { 5, "A", "ablaze", "#9ece6a" },
  { 7, "S", "swarming", "#e0af68" },
  { 10, "SS", "supersonic", "#ff9e64" },
  { 15, "SSS", "singularity", "#f7768e", "#bb9af7" },
}
local FLASH_MS = 1200
local SHIMMER_MS = 600

-- Per rank: IsovimRank<letter> for the letter, ...Phrase for the phrase, ...Flash for a rank-up;
-- the top rank's second hue is IsovimRankSSSShimmer (and its Phrase).
function M.setup()
  local function define(group, color)
    vim.api.nvim_set_hl(0, group, { fg = color, bold = true, default = true })
    vim.api.nvim_set_hl(0, group .. "Phrase", { fg = color, italic = true, default = true })
    vim.api.nvim_set_hl(0, group .. "Flash", { fg = color, bold = true, reverse = true, default = true })
  end
  for _, rank in ipairs(RANKS) do
    if rank[4] then
      define("IsovimRank" .. rank[2], rank[4])
    end
    if rank[5] then
      define("IsovimRank" .. rank[2] .. "Shimmer", rank[5])
    end
  end
end

local function rank_of(count)
  local index = 1
  for i, rank in ipairs(RANKS) do
    if count >= rank[1] then
      index = i
    end
  end
  return index
end

local count, rank, flash_until = 0, nil, 0

-- The live agents on this host, from each refresh. Only a climb flashes, not the first count.
function M.update(live)
  local new = rank_of(live)
  if rank and new > rank then
    flash_until = vim.uv.now() + FLASH_MS
  end
  count, rank = live, new
end

-- Whether the title changes with time: mid-flash, or shimmering.
function M.moving()
  return vim.uv.now() < flash_until or (rank and RANKS[rank][5]) ~= nil
end

---@return {[1]: string, [2]: string}[] chunks, the phrase last
function M.chunks()
  local r = RANKS[rank or 1]
  local hl = "Comment"
  if r[4] then
    hl = "IsovimRank" .. r[2]
    if r[5] and math.floor(vim.uv.now() / SHIMMER_MS) % 2 == 1 then
      hl = hl .. "Shimmer"
    end
  end
  local flashing = r[4] and vim.uv.now() < flash_until
  return {
    { r[2], flashing and hl .. "Flash" or hl },
    { (" (%d) - "):format(count), "Comment" },
    { r[3], r[4] and hl .. "Phrase" or "Comment" },
  }
end

return M
