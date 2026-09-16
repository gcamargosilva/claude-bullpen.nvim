local PROJECTS_GLOB = vim.fn.expand("~/.claude/projects") .. "/*/*.jsonl"
local LIVE_SESSIONS_GLOB = vim.fn.expand("~/.claude/sessions") .. "/*.json"

local M = {}

local parsed_by_path = {}

local function parse(path)
  local session = { id = vim.fn.fnamemodify(path, ":t:r") }
  for line in io.lines(path) do
    if not session.cwd and line:find('"cwd":"', 1, true) then
      session.cwd = line:match('"cwd":"([^"]+)"')
      session.branch = line:match('"gitBranch":"([^"]+)"')
    end
    if line:find('"type":"ai-title"', 1, true) or line:find('"type":"last-prompt"', 1, true) then
      local decoded, record = pcall(vim.json.decode, line)
      if decoded then
        session.title = record.aiTitle or session.title
        session.last_prompt = record.lastPrompt or session.last_prompt
      end
    end
  end
  return session
end

function M.list()
  local live_status_by_id = {}
  for _, path in ipairs(vim.fn.glob(LIVE_SESSIONS_GLOB, false, true)) do
    local decoded, live_session = pcall(vim.json.decode, table.concat(vim.fn.readfile(path)))
    if decoded then
      live_status_by_id[live_session.sessionId] = live_session.status
    end
  end

  local sessions = {}
  for _, path in ipairs(vim.fn.glob(PROJECTS_GLOB, false, true)) do
    local stat = vim.uv.fs_stat(path)
    local session = parsed_by_path[path]
    if not session or session.size ~= stat.size then
      session = parse(path)
      session.size = stat.size
      parsed_by_path[path] = session
    end
    session.updated_at = stat.mtime.sec
    if session.cwd and (session.title or session.last_prompt) then
      table.insert(sessions, session)
    end
  end
  table.sort(sessions, function(left, right)
    return left.updated_at > right.updated_at
  end)
  return sessions, live_status_by_id
end

return M
