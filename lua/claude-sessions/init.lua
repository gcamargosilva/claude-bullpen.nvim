local sessions = require("claude-sessions.sessions")

local STATUS_LABELS = { busy = "working" }
local STATUS_HIGHLIGHTS = { busy = "ClaudeSessionsWorking", idle = "ClaudeSessionsIdle" }
local NEW_SESSION_TITLE = "new session"
local QUIT_GUARD_NAME = "Claude Sessions: sessões rodando"

local M = {}

local config = {
  cmd = { "claude" },
  sidebar_width = 36,
  refresh_interval_ms = 2000,
  keys = {
    open = "<CR>",
    new = "n",
    new_in_directory = "N",
    stop = "x",
    close = "q",
    focus_terminal = "<Tab>",
    focus_sidebar = "<C-h>",
    next = "<C-.>",
    prev = "<C-,>",
    minimize = "<C-q>",
  },
}

local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local HOOK_COMMAND =
  { { type = "command", command = "nvim -l " .. vim.fn.shellescape(PLUGIN_ROOT .. "/scripts/hook.lua") } }
local CLAUDE_SETTINGS = vim.json.encode({
  hooks = {
    PostToolUse = { { matcher = "Write|Edit", hooks = HOOK_COMMAND } },
    Stop = { { hooks = HOOK_COMMAND } },
    Notification = { { matcher = "permission_prompt|elicitation_dialog", hooks = HOOK_COMMAND } },
  },
})

local namespace = vim.api.nvim_create_namespace("claude-sessions")
local changes_namespace = vim.api.nvim_create_namespace("claude-sessions-changes")

local state = {
  terminals = {},
  items_by_line = {},
  entry_lines = {},
  titles_by_id = {},
}

local function find_terminal(field, value)
  for _, terminal in ipairs(state.terminals) do
    if terminal[field] == value then
      return terminal
    end
  end
end

local function time_ago(timestamp)
  local elapsed_seconds = os.time() - timestamp
  if elapsed_seconds < 3600 then
    return math.floor(elapsed_seconds / 60) .. "m ago"
  end
  if elapsed_seconds < 86400 then
    return math.floor(elapsed_seconds / 3600) .. "h ago"
  end
  return math.floor(elapsed_seconds / 86400) .. "d ago"
end

local function render()
  if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
    return
  end

  local all_sessions, live_status_by_id = sessions.list()
  local listed_ids = {}
  for _, session in ipairs(all_sessions) do
    listed_ids[session.id] = true
  end
  for _, terminal in ipairs(state.terminals) do
    if not listed_ids[terminal.id] then
      table.insert(all_sessions, 1, { id = terminal.id, cwd = terminal.cwd, updated_at = os.time() })
    end
  end

  local spaces, sessions_by_cwd, titles_by_id = {}, {}, {}
  for _, session in ipairs(all_sessions) do
    if not sessions_by_cwd[session.cwd] then
      sessions_by_cwd[session.cwd] = {}
      table.insert(spaces, session.cwd)
    end
    table.insert(sessions_by_cwd[session.cwd], session)
    titles_by_id[session.id] = session.title
      or (session.last_prompt and session.last_prompt:gsub("%s+", " "))
      or NEW_SESSION_TITLE
  end
  if not sessions_by_cwd[state.selected_cwd] then
    sessions_by_cwd[state.selected_cwd] = {}
    table.insert(spaces, 1, state.selected_cwd)
  end

  local lines, marks, items_by_line, entry_lines = {}, {}, {}, {}

  local function add_header(text)
    table.insert(lines, " " .. text)
    table.insert(marks, { #lines - 1, 0, { end_col = #lines[#lines], hl_group = "ClaudeSessionsHeader" } })
  end

  local function add_entry(item, status, name, detail, selected)
    local dot = status and "●" or "○"
    local status_highlight = status and (STATUS_HIGHLIGHTS[status] or "ClaudeSessionsBlocked")
    table.insert(lines, " " .. dot .. " " .. name)
    table.insert(lines, "   " .. detail)
    local name_line, detail_line = #lines - 1, #lines
    items_by_line[name_line], items_by_line[detail_line] = item, item
    table.insert(entry_lines, name_line)
    table.insert(marks, {
      name_line - 1,
      1,
      { end_col = 1 + #dot, hl_group = status_highlight or "ClaudeSessionsInactive" },
    })
    table.insert(marks, {
      detail_line - 1,
      3,
      { end_col = #lines[detail_line], hl_group = status_highlight or "ClaudeSessionsDetail" },
    })
    if selected then
      table.insert(marks, { name_line - 1, 0, { line_hl_group = "ClaudeSessionsSelected" } })
      table.insert(marks, { detail_line - 1, 0, { line_hl_group = "ClaudeSessionsSelected" } })
    end
  end

  add_header("spaces")
  for _, cwd in ipairs(spaces) do
    local space_status, branch
    for _, session in ipairs(sessions_by_cwd[cwd]) do
      local status = live_status_by_id[session.id]
      if status == "busy" or (status and not space_status) then
        space_status = status
      end
      branch = branch or session.branch
    end
    local detail = branch or vim.fn.fnamemodify(cwd, ":~:h")
    add_entry({ key = cwd, cwd = cwd }, space_status, vim.fn.fnamemodify(cwd, ":t"), detail, cwd == state.selected_cwd)
  end

  table.insert(lines, "")
  add_header("sessions")
  state.first_session_line = #lines + 1
  for _, session in ipairs(sessions_by_cwd[state.selected_cwd]) do
    local status = live_status_by_id[session.id]
    local detail = status and (STATUS_LABELS[status] or status) or time_ago(session.updated_at)
    add_entry(
      { key = session.id, session = session },
      status,
      titles_by_id[session.id],
      detail,
      session.id == state.active_id
    )
  end

  local cursor_line = vim.api.nvim_win_is_valid(state.sidebar_win) and vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
  local cursor_item = cursor_line and state.items_by_line[cursor_line]

  vim.bo[state.sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
  vim.bo[state.sidebar_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.sidebar_buf, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(state.sidebar_buf, namespace, mark[1], mark[2], mark[3])
  end
  state.items_by_line, state.entry_lines, state.titles_by_id = items_by_line, entry_lines, titles_by_id

  for _, line in ipairs(entry_lines) do
    if cursor_item and items_by_line[line].key == cursor_item.key then
      vim.api.nvim_win_set_cursor(state.sidebar_win, { line, 0 })
    end
  end

  if vim.api.nvim_win_is_valid(state.terminal_win) then
    local tabs = {}
    for _, terminal in ipairs(state.terminals) do
      local tab_highlight = terminal.id == state.active_id and "ClaudeSessionsTabActive" or "ClaudeSessionsTab"
      local title = vim.fn.strcharpart(titles_by_id[terminal.id], 0, 24):gsub("%%", "%%%%")
      table.insert(tabs, "%#" .. tab_highlight .. "# " .. title .. " %*")
    end
    vim.wo[state.terminal_win].winbar = table.concat(tabs, " ")
  end
end

local function move(direction)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local target_line
  for _, line in ipairs(state.entry_lines) do
    if direction > 0 and line > cursor_line then
      target_line = line
      break
    end
    if direction < 0 and line <= cursor_line - 2 then
      target_line = line
    end
  end
  if target_line then
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  end
end

local function show_in_panel(terminal, buf)
  terminal.panel_buf = buf
  if terminal.id ~= state.active_id or not vim.api.nvim_win_is_valid(state.terminal_win) then
    return
  end
  if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then
    state.panel_win = vim.api.nvim_open_win(buf, false, { split = "right", win = state.terminal_win })
  end
  vim.api.nvim_win_set_buf(state.panel_win, buf)
end

local function restore_panel(terminal)
  if terminal and terminal.panel_buf and vim.api.nvim_buf_is_valid(terminal.panel_buf) then
    show_in_panel(terminal, terminal.panel_buf)
  elseif state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_close(state.panel_win, false)
  end
end

local function update_quit_guard()
  if not (state.quit_guard_buf and vim.api.nvim_buf_is_valid(state.quit_guard_buf)) then
    state.quit_guard_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.quit_guard_buf].buftype = "prompt"
    vim.api.nvim_buf_set_name(state.quit_guard_buf, QUIT_GUARD_NAME)
  end
  vim.bo[state.quit_guard_buf].modified = #state.terminals > 0
end

local cycle

local function start_terminal(id, cwd, args)
  local buf = vim.api.nvim_create_buf(false, false)
  local terminal = { id = id, cwd = cwd, buf = buf }
  table.insert(state.terminals, terminal)
  update_quit_guard()
  vim.api.nvim_win_set_buf(state.terminal_win, buf)
  local command = vim.list_extend(vim.deepcopy(config.cmd), { "--settings", CLAUDE_SETTINGS })
  vim.api.nvim_win_call(state.terminal_win, function()
    terminal.job_id = vim.fn.jobstart(vim.list_extend(command, args), {
      term = true,
      cwd = cwd,
      env = {
        CLAUDE_CODE_SHELL_PREFIX = PLUGIN_ROOT .. "/scripts/shell-prefix",
        CLAUDE_SESSIONS_BUF = tostring(buf),
      },
      on_exit = function()
        state.terminals = vim.tbl_filter(function(other)
          return other ~= terminal
        end, state.terminals)
        update_quit_guard()
        for _, exited_buf in ipairs({ buf, terminal.output_buf }) do
          if vim.api.nvim_buf_is_valid(exited_buf) then
            vim.bo[exited_buf].bufhidden = "wipe"
            if #vim.fn.win_findbuf(exited_buf) == 0 then
              vim.api.nvim_buf_delete(exited_buf, { force = true })
            end
          end
        end
        render()
      end,
    })
  end)
  vim.keymap.set("t", config.keys.focus_sidebar, [[<C-\><C-n><C-w>h]], { buffer = buf })
  vim.keymap.set("t", config.keys.next, function()
    cycle(1)
  end, { buffer = buf })
  vim.keymap.set("t", config.keys.prev, function()
    cycle(-1)
  end, { buffer = buf })
  vim.keymap.set("t", config.keys.minimize, function()
    M.toggle()
  end, { buffer = buf })
  vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, command = "startinsert" })
end

local function show(id, cwd, start_args)
  if not vim.api.nvim_win_is_valid(state.terminal_win) then
    vim.api.nvim_set_current_win(state.sidebar_win)
    vim.cmd("rightbelow vnew")
    state.terminal_win = vim.api.nvim_get_current_win()
    vim.bo.bufhidden = "wipe"
    vim.api.nvim_win_set_width(state.sidebar_win, config.sidebar_width)
  end
  local terminal = find_terminal("id", id)
  if terminal then
    vim.api.nvim_win_set_buf(state.terminal_win, terminal.buf)
  else
    start_terminal(id, cwd, start_args)
  end
  state.active_id = id
  restore_panel(terminal)
  vim.api.nvim_set_current_win(state.terminal_win)
  render()
end

cycle = function(step)
  if #state.terminals == 0 then
    return
  end
  local active_index = 0
  for index, terminal in ipairs(state.terminals) do
    if terminal.id == state.active_id then
      active_index = index
    end
  end
  show(state.terminals[(active_index - 1 + step) % #state.terminals + 1].id)
end

local function new_session(cwd)
  local id = vim.trim(vim.fn.system({ "uuidgen" })):lower()
  state.selected_cwd = cwd
  show(id, cwd, { "--session-id", id })
end

local function open_item()
  local item = state.items_by_line[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  if item.session then
    show(item.session.id, item.session.cwd, { "--resume", item.session.id })
    return
  end
  state.selected_cwd = item.cwd
  render()
  if state.items_by_line[state.first_session_line] then
    vim.api.nvim_win_set_cursor(0, { state.first_session_line, 0 })
  end
end

local function open()
  state.selected_cwd = state.selected_cwd or vim.fn.getcwd()
  vim.cmd.tabnew()
  state.tab = vim.api.nvim_get_current_tabpage()
  state.terminal_win = vim.api.nvim_get_current_win()
  vim.bo.bufhidden = "wipe"
  vim.cmd("topleft vsplit")
  state.sidebar_win = vim.api.nvim_get_current_win()
  state.sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
  vim.api.nvim_win_set_width(state.sidebar_win, config.sidebar_width)
  vim.bo[state.sidebar_buf].bufhidden = "wipe"
  vim.bo[state.sidebar_buf].filetype = "claude-sessions"
  for option, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    cursorline = true,
    wrap = false,
    list = false,
    spell = false,
    winfixwidth = true,
  }) do
    vim.wo[state.sidebar_win][0][option] = value
  end

  local function map(key, action)
    vim.keymap.set("n", key, action, { buffer = state.sidebar_buf, nowait = true })
  end
  map("j", function()
    move(1)
  end)
  map("k", function()
    move(-1)
  end)
  map(config.keys.open, open_item)
  map(config.keys.new, function()
    new_session(state.selected_cwd)
  end)
  map(config.keys.new_in_directory, function()
    vim.ui.input({ prompt = "Directory: ", default = state.selected_cwd, completion = "dir" }, function(directory)
      if directory then
        new_session(vim.fs.normalize(vim.fn.fnamemodify(directory, ":p")))
      end
    end)
  end)
  map(config.keys.stop, function()
    local item = state.items_by_line[vim.api.nvim_win_get_cursor(0)[1]]
    local terminal = item and item.session and find_terminal("id", item.session.id)
    if terminal then
      vim.fn.jobstop(terminal.job_id)
    end
  end)
  map(config.keys.close, M.toggle)
  map(config.keys.focus_terminal, function()
    vim.api.nvim_set_current_win(state.terminal_win)
  end)

  local active_terminal = find_terminal("id", state.active_id)
  if active_terminal then
    vim.api.nvim_win_set_buf(state.terminal_win, active_terminal.buf)
    restore_panel(active_terminal)
  end
  render()
  move(1)

  state.timer = state.timer or vim.uv.new_timer()
  state.timer:start(
    config.refresh_interval_ms,
    config.refresh_interval_ms,
    vim.schedule_wrap(function()
      if vim.api.nvim_get_current_tabpage() == state.tab then
        render()
      end
    end)
  )
end

local function show_changed_file(terminal, hook_input)
  local buf = vim.fn.bufadd(hook_input.tool_input.file_path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  vim.cmd.checktime(buf)

  vim.api.nvim_buf_clear_namespace(buf, changes_namespace, 0, -1)
  local first_changed_line
  for _, hunk in ipairs(hook_input.tool_response.structuredPatch or {}) do
    local line = hunk.newStart
    for _, patch_line in ipairs(hunk.lines) do
      local marker = patch_line:sub(1, 1)
      if marker == "+" or marker == "-" then
        first_changed_line = first_changed_line or line
      end
      if marker == "+" then
        vim.api.nvim_buf_set_extmark(buf, changes_namespace, line - 1, 0, { line_hl_group = "ClaudeSessionsChanged" })
      end
      if marker == "+" or marker == " " then
        line = line + 1
      end
    end
  end

  show_in_panel(terminal, buf)
  if
    state.panel_win
    and vim.api.nvim_win_is_valid(state.panel_win)
    and vim.api.nvim_win_get_buf(state.panel_win) == buf
  then
    vim.api.nvim_win_set_cursor(state.panel_win, { first_changed_line or 1, 0 })
    vim.api.nvim_win_call(state.panel_win, function()
      vim.cmd("normal! zz")
    end)
  end
end

function M.on_hook(terminal_buf, hook_input_json)
  local terminal = find_terminal("buf", terminal_buf)
  local hook_input = vim.json.decode(hook_input_json)
  if hook_input.hook_event_name == "PostToolUse" then
    show_changed_file(terminal, hook_input)
  elseif vim.api.nvim_get_current_tabpage() ~= state.tab or terminal.id ~= state.active_id then
    local title = state.titles_by_id[terminal.id] or NEW_SESSION_TITLE
    vim.notify(hook_input.message or "terminou", vim.log.levels.INFO, { title = "Claude · " .. title })
  end
end

function M.command_started(terminal_buf, command)
  local terminal = find_terminal("buf", terminal_buf)
  if not (terminal.output_buf and vim.api.nvim_buf_is_valid(terminal.output_buf)) then
    terminal.output_buf = vim.api.nvim_create_buf(false, true)
    terminal.output_channel = vim.api.nvim_open_term(terminal.output_buf, {})
  end
  vim.api.nvim_chan_send(terminal.output_channel, "\27[1;35m❯ " .. command:gsub("\n", "\r\n") .. "\27[0m\r\n")
  show_in_panel(terminal, terminal.output_buf)
  return terminal.output_channel
end

function M.command_output(output_channel, chunk)
  vim.api.nvim_chan_send(output_channel, (chunk:gsub("\r?\n", "\r\n")))
end

function M.command_finished(output_channel, exit_code)
  local footer = exit_code == 0 and "\27[32m✓\27[0m" or "\27[31m✗ exit " .. exit_code .. "\27[0m"
  vim.api.nvim_chan_send(output_channel, footer .. "\r\n\r\n")
end

function M.toggle()
  if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    open()
  elseif vim.api.nvim_get_current_tabpage() == state.tab then
    vim.cmd.tabclose()
  else
    vim.api.nvim_set_current_tabpage(state.tab)
  end
end

local function set_highlights()
  for group, link in pairs({
    ClaudeSessionsHeader = "Comment",
    ClaudeSessionsDetail = "Comment",
    ClaudeSessionsInactive = "Comment",
    ClaudeSessionsWorking = "DiagnosticWarn",
    ClaudeSessionsIdle = "DiagnosticOk",
    ClaudeSessionsBlocked = "DiagnosticError",
    ClaudeSessionsSelected = "Visual",
    ClaudeSessionsTab = "TabLine",
    ClaudeSessionsTabActive = "TabLineSel",
    ClaudeSessionsChanged = "DiffAdd",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
  vim.api.nvim_create_user_command("ClaudeSessions", M.toggle, {})
end

return M
