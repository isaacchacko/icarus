-- Whether an agent's last answer has progress for you, or only waits on something it started (a
-- build, a test run, a server coming up) and will go on by itself. Haiku reads the answer; anything
-- unclear, or a failed check, counts as progress so a real finish is never missed.
local transcript = require("isovim.transcript")

local M = {}

local PROMPT = [[An AI coding agent just ended its turn with the message below. Answer with exactly one word.
PROGRESS if it gives the user something new: a result, a finding, a finished step, a decision, or a question for them.
WAITING if it only says it is waiting on something it started (a command, build, test run, deploy, server starting) and will continue on its own when that finishes.

Message:
]]

---@return "progress"|"waiting"
function M.verdict(ws, agent)
  local answer = transcript.last_answer(ws, agent)
  if not answer or vim.fn.executable("claude") == 0 then
    return "progress"
  end
  -- No settings sources: none of your hooks or plugins run for this side call; run from a scratch
  -- dir so it never touches a project's settings either.
  vim.fn.mkdir(vim.fn.stdpath("cache"), "p")
  local result = vim.system(
    { "claude", "-p", "--model", "haiku", "--setting-sources", "", "--no-session-persistence", "--tools", "" },
    { stdin = PROMPT .. answer:sub(-4000), text = true, cwd = vim.fn.stdpath("cache"), timeout = 30000 }
  ):wait()
  return (result.stdout or ""):upper():match("WAITING") and "waiting" or "progress"
end

return M
