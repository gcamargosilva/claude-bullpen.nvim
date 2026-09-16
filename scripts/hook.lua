local nvim = vim.fn.sockconnect("pipe", vim.env.NVIM, { rpc = true })
vim.rpcrequest(
  nvim,
  "nvim_exec_lua",
  "require('claude-sessions').on_hook(...)",
  { tonumber(vim.env.CLAUDE_SESSIONS_BUF), io.read("a") }
)
