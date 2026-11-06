-- icarus's colours: every colour icarus draws itself, named for what it means, so the badges, the
-- comments, the links and the home field agree. The field runs from the sky to the sun; the accents
-- are the warm end of it and the one-dark hues nvim's colourschemes already share.
local M = {}

M.ink = "#1e1e1e" -- text on a coloured badge or comment
M.sun = "#e5c07b" -- the warm accent: comments, nags, what waits on you
M.leaf = "#98c379" -- done and open: reader, open PRs, proposed additions
M.sky = "#61afef" -- agents and links
M.violet = "#c678dd" -- forks, merged PRs, icarus's own links
M.ember = "#d19a66" -- the router
M.coral = "#e06c75" -- auto mode, closed PRs, removals
M.teal = "#56b6c2" -- democracy, and your own comments
M.mute = "#7f848e" -- drafts, hints, and what has no state

M.asked = "#2c4a6e" -- a line the agent asked about
M.removed = "#5c2b2b" -- a proposed deletion
M.pulse = 0x3d6ea8 -- the asked line's pulse, blended into the background

-- The home field, from low (deep sky) to high (warm sun).
M.field = { "#34425c", "#3d5576", "#466990", "#4f7ea8", "#4f93b5", "#55a6aa", "#6fb39a", "#98c379",
  "#c4c47a", "#e5c07b", "#e8a66b" }

return M
