local sessions = require("claude-sessions.sessions")

local STATUS_LABELS = { busy = "working" }
local STATUS_HIGHLIGHTS = { busy = "ClaudeSessionsWorking", idle = "ClaudeSessionsIdle" }
local NEW_SESSION_TITLE = "new session"
local QUIT_GUARD_NAME = "Claude Sessions: sessões rodando"
local MAX_COMMANDS = 50

local M = {}

local config = {
  cmd = { "claude" },
  sidebar_width = 36,
  commands_width = 60,
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
    commands = "<C-y>",
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
  panels = {},
  titles_by_id = {},
  commands_by_channel = {},
}

local map_keys

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

local function style_window(win)
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
    winfixheight = true,
  }) do
    vim.wo[win][0][option] = value
  end
end

local function create_panel_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "claude-sessions"
  vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, command = "stopinsert" })
  map_keys(buf)
  return buf
end

local function ensure_commands_window()
  if state.commands_win and vim.api.nvim_win_is_valid(state.commands_win) then
    return
  end
  if not (state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win)) then
    return
  end
  if not (state.commands_buf and vim.api.nvim_buf_is_valid(state.commands_buf)) then
    state.commands_buf = create_panel_buffer()
  end
  state.commands_win = vim.api.nvim_open_win(state.commands_buf, false, {
    split = "right",
    win = state.terminal_win,
    width = config.commands_width,
  })
  style_window(state.commands_win)
end

local function paint(win, buf, lines, marks, items_by_line, entry_lines)
  local previous = state.panels[buf]
  local cursor_line = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1]
  local cursor_item = previous and cursor_line and previous.items_by_line[cursor_line]

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, namespace, mark[1], mark[2], mark[3])
  end
  state.panels[buf] = { items_by_line = items_by_line, entry_lines = entry_lines }

  for _, line in ipairs(entry_lines) do
    if cursor_item and items_by_line[line].key == cursor_item.key then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
    end
  end
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

  paint(state.sidebar_win, state.sidebar_buf, lines, marks, items_by_line, entry_lines)
  state.titles_by_id = titles_by_id

  local active_terminal = find_terminal("id", state.active_id)
  if state.commands_win and vim.api.nvim_win_is_valid(state.commands_win) then
    lines, marks, items_by_line, entry_lines = {}, {}, {}, {}
    add_header("commands")
    for _, command in ipairs(active_terminal and active_terminal.commands or {}) do
      local status = command.exit_code == nil and "busy" or command.exit_code ~= 0 and "failed" or nil
      local detail
      if command.path then
        detail = "edit · " .. time_ago(command.started_at)
      elseif command.exit_code == nil then
        detail = "running · " .. os.time() - command.started_at .. "s"
      else
        detail = "exit " .. command.exit_code .. " · " .. command.duration .. "s"
      end
      add_entry(
        { key = command.channel or command.path .. command.started_at, command = command },
        status,
        (command.text:gsub("%s+", " ")),
        detail,
        false
      )
    end
    paint(state.commands_win, state.commands_buf, lines, marks, items_by_line, entry_lines)
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

local function toggle_commands()
  if state.commands_win and vim.api.nvim_win_is_valid(state.commands_win) then
    vim.api.nvim_win_close(state.commands_win, true)
    return
  end
  ensure_commands_window()
  render()
end

local function move(direction)
  local panel = state.panels[vim.api.nvim_get_current_buf()]
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local target_line
  for _, line in ipairs(panel and panel.entry_lines or {}) do
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
  local terminal = { id = id, cwd = cwd, buf = buf, commands = {} }
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
        for _, command in ipairs(terminal.commands) do
          if command.channel then
            state.commands_by_channel[command.channel] = nil
            vim.api.nvim_buf_delete(command.buf, { force = true })
          end
        end
        vim.bo[buf].bufhidden = "wipe"
        if #vim.fn.win_findbuf(buf) == 0 then
          vim.api.nvim_buf_delete(buf, { force = true })
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
  vim.keymap.set("t", config.keys.commands, toggle_commands, { buffer = buf })
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

local function open_command(command)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local buf = command.buf
  if command.path then
    buf = vim.fn.bufadd(command.path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    vim.cmd.checktime(buf)
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " " .. vim.fn.strcharpart((command.text:gsub("%s+", " ")), 0, width - 6) .. " ",
  })
  if command.first_changed_line then
    vim.api.nvim_win_set_cursor(win, { command.first_changed_line, 0 })
    vim.cmd("normal! zz")
  end
end

local function open_item()
  local panel = state.panels[vim.api.nvim_get_current_buf()]
  local item = panel and panel.items_by_line[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  if item.command then
    open_command(item.command)
    return
  end
  if item.session then
    show(item.session.id, item.session.cwd, { "--resume", item.session.id })
    return
  end
  state.selected_cwd = item.cwd
  render()
  if state.panels[state.sidebar_buf].items_by_line[state.first_session_line] then
    vim.api.nvim_win_set_cursor(0, { state.first_session_line, 0 })
  end
end

map_keys = function(buf)
  local function map(key, action)
    vim.keymap.set("n", key, action, { buffer = buf, nowait = true })
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
    local panel = state.panels[buf]
    local item = panel and panel.items_by_line[vim.api.nvim_win_get_cursor(0)[1]]
    local terminal = item and item.session and find_terminal("id", item.session.id)
    if terminal then
      vim.fn.jobstop(terminal.job_id)
    end
  end)
  map(config.keys.close, function()
    M.toggle()
  end)
  map(config.keys.focus_terminal, function()
    vim.api.nvim_set_current_win(state.terminal_win)
  end)
  map(config.keys.commands, toggle_commands)
end

local function open()
  state.selected_cwd = state.selected_cwd or vim.fn.getcwd()
  vim.cmd.tabnew()
  state.tab = vim.api.nvim_get_current_tabpage()
  state.terminal_win = vim.api.nvim_get_current_win()
  vim.bo.bufhidden = "wipe"
  vim.cmd("topleft vsplit")
  state.sidebar_win = vim.api.nvim_get_current_win()
  state.panels = {}
  state.sidebar_buf = create_panel_buffer()
  vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
  vim.api.nvim_win_set_width(state.sidebar_win, config.sidebar_width)
  style_window(state.sidebar_win)

  local active_terminal = find_terminal("id", state.active_id)
  if active_terminal then
    vim.api.nvim_win_set_buf(state.terminal_win, active_terminal.buf)
    if #active_terminal.commands > 0 then
      ensure_commands_window()
    end
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

local function trim_commands(terminal)
  local dropped = table.remove(terminal.commands, MAX_COMMANDS + 1)
  if dropped and dropped.channel then
    state.commands_by_channel[dropped.channel] = nil
    vim.api.nvim_buf_delete(dropped.buf, { force = true })
  end
end

local function add_file_entry(terminal, hook_input)
  local path = hook_input.tool_input.file_path
  local buf = vim.fn.bufadd(path)
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

  table.insert(terminal.commands, 1, {
    text = vim.fn.fnamemodify(path, ":t"),
    path = path,
    first_changed_line = first_changed_line,
    started_at = os.time(),
    exit_code = 0,
  })
  trim_commands(terminal)
  ensure_commands_window()
  render()
end

function M.on_hook(terminal_buf, hook_input_json)
  local terminal = find_terminal("buf", terminal_buf)
  local hook_input = vim.json.decode(hook_input_json)
  if hook_input.hook_event_name == "PostToolUse" then
    add_file_entry(terminal, hook_input)
  elseif vim.api.nvim_get_current_tabpage() ~= state.tab or terminal.id ~= state.active_id then
    local title = state.titles_by_id[terminal.id] or NEW_SESSION_TITLE
    vim.notify(hook_input.message or "terminou", vim.log.levels.INFO, { title = "Claude · " .. title })
  end
end

function M.command_started(terminal_buf, text)
  local buf = vim.api.nvim_create_buf(false, true)
  local command = { text = text, buf = buf, channel = vim.api.nvim_open_term(buf, {}), started_at = os.time() }
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.api.nvim_chan_send(command.channel, "\27[1;35m❯ " .. text:gsub("\n", "\r\n") .. "\27[0m\r\n")

  local terminal = find_terminal("buf", terminal_buf)
  state.commands_by_channel[command.channel] = command
  table.insert(terminal.commands, 1, command)
  trim_commands(terminal)
  ensure_commands_window()
  render()
  return command.channel
end

function M.command_output(channel, chunk)
  vim.api.nvim_chan_send(channel, (chunk:gsub("\r?\n", "\r\n")))
end

function M.command_finished(channel, exit_code)
  local command = state.commands_by_channel[channel]
  command.exit_code = exit_code
  command.duration = os.time() - command.started_at
  vim.api.nvim_chan_send(
    channel,
    exit_code == 0 and "\27[32m✓\27[0m\r\n" or "\27[31m✗ exit " .. exit_code .. "\27[0m\r\n"
  )
  render()
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
