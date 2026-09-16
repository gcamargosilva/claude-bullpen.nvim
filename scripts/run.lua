local wrapped_command = arg[1]
local command = wrapped_command:match("eval '(.*)'[^']- && pwd %-P >| ")
command = command and command:gsub("'\\''", "'") or wrapped_command

local nvim = vim.fn.sockconnect("pipe", vim.env.NVIM, { rpc = true })
local output_channel = vim.rpcrequest(
  nvim,
  "nvim_exec_lua",
  "return require('claude-sessions').command_started(...)",
  { tonumber(vim.env.CLAUDE_SESSIONS_BUF), command }
)

local exit_code, open_pipes, finished = nil, 2, false

local function finish_when_done()
  if exit_code and open_pipes == 0 then
    vim.schedule(function()
      vim.rpcrequest(
        nvim,
        "nvim_exec_lua",
        "require('claude-sessions').command_finished(...)",
        { output_channel, exit_code }
      )
      finished = true
    end)
  end
end

local stdout_pipe, stderr_pipe = vim.uv.new_pipe(), vim.uv.new_pipe()
vim.uv.spawn(
  vim.env.SHELL,
  { args = { "-c", wrapped_command }, stdio = { 0, stdout_pipe, stderr_pipe } },
  function(code, signal)
    exit_code = signal == 0 and code or 128 + signal
    finish_when_done()
  end
)

local function forward(pipe, destination)
  pipe:read_start(function(_, chunk)
    if not chunk then
      pipe:close()
      open_pipes = open_pipes - 1
      finish_when_done()
      return
    end
    destination:write(chunk)
    vim.schedule(function()
      vim.rpcnotify(nvim, "nvim_exec_lua", "require('claude-sessions').command_output(...)", { output_channel, chunk })
    end)
  end)
end

io.stdout:setvbuf("no")
forward(stdout_pipe, io.stdout)
forward(stderr_pipe, io.stderr)
vim.wait(2 ^ 31 - 1, function()
  return finished
end)
os.exit(exit_code)
