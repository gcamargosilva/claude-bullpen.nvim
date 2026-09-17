# claude-bullpen.nvim

A bullpen for your Claude Code sessions: all of them warmed up in a Neovim tab, ready to be called in. Browse every session you have, run several at once, and watch what Claude edits and executes while it works.

```
 spaces                 │ [Fix flaky login test]  Add usage charts │ src/auth/login.ts
 ● web-dashboard        │                                          │
   feat/usage-charts    │ ⏺ The retry wraps the whole request, so  │  41  async function login(user) {
 ○ data-pipeline        │   the second try reuses an expired       │  42    const token = await refresh()
   main                 │   token. Moving it inside the retry.     │  43 ▌  if (token.expired) {
                        │                                          │  44 ▌    await refresh()
 sessions               │ ⏺ Update(src/auth/login.ts)              │  45    }
 ● Fix flaky login test │                                          │
   working              │ ⏺ Both login tests pass now.             │
 ○ Add usage charts     │                                          │
   2h ago               │ ❯                                        │
────────────────────────│                                          │
 commands               │                                          │
 ● npm run typecheck    │                                          │
   running · 3s         │                                          │
 ○ npm test -- login    │                                          │
   exit 0 · 12s         │                                          │

 sidebar + commands       Claude Code                                panel: the file it just changed
```

- **Every session in one sidebar.** Grouped by project directory, with git branch, AI title and live status, including sessions running in other terminals.
- **Run many, switch fast.** Sessions you open become tabs. Hop between them with `<C-,>` / `<C-.>`; hidden ones keep working.
- **Watch Claude work.** Files Claude writes or edits open on the right with the changed lines highlighted. The first command a session runs opens a commands list under the sidebar, and `<CR>` on one shows its live output in a floating window.
- **Minimize and get pinged.** `<C-q>` puts the bullpen away. You get a notification when a hidden session finishes or asks for permission.
- **No accidental kills.** `:qa` refuses to quit while sessions are running.
- **No global config.** Hooks are passed per session with `--settings`. Claude Code sessions started anywhere else are untouched.

## Requirements

- Neovim 0.11+
- [Claude Code](https://claude.com/claude-code) CLI as `claude` on your `PATH` (tested with 2.1.270)
- `bash` and `uuidgen` (standard on macOS and most Linux distros)

## Install with Claude Code

Open Claude Code and paste:

```
Install https://github.com/gcamargosilva/claude-bullpen.nvim in my Neovim setup:

1. Clone the repo to a temp dir and read README.md.
2. Check the requirements: Neovim >= 0.11, `claude` on PATH, bash and uuidgen available.
3. Find how plugins are managed in my Neovim config.
   - LazyVim or lazy.nvim: add the spec from the README's Manual install section as a new file in my plugins dir
   - anything else: install the repo and call require("claude-sessions").setup({})
4. Pick a free key for :ClaudeSessions. Check my existing mappings first (LazyVim's claudecode extra already uses <leader>as).
5. Verify headless: load the plugin and confirm the :ClaudeSessions command exists.
6. Tell me what changed and that I need to restart Neovim.
```

## Manual install

lazy.nvim / LazyVim:

```lua
return {
  "gcamargosilva/claude-bullpen.nvim",
  main = "claude-sessions",
  cmd = "ClaudeSessions",
  keys = {
    { "<leader>aS", "<cmd>ClaudeSessions<cr>", desc = "Claude Sessions" },
  },
  opts = {},
}
```

Other plugin managers: install the repo and call `require("claude-sessions").setup({})`.

## Usage

`:ClaudeSessions` opens the bullpen in its own tab, or minimizes it if you are already there.

1. Pick a space (project directory) with `<CR>`.
2. Resume a session with `<CR>`, or start one with `n` (`N` asks for a directory).
3. Talk to Claude in the middle column. The panel on the right follows what it does.
4. Press `<C-q>` to put everything away. Sessions keep running.

### Keys

| Key | Where | Action |
|---|---|---|
| `j` / `k` | sidebar, commands | next / previous entry |
| `<CR>` | sidebar | select a space, open or resume a session, show a command's output |
| `n` | sidebar | new session in the selected space |
| `N` | sidebar | new session in another directory |
| `x` | sidebar | stop the session under the cursor |
| `<Tab>` | sidebar | focus the Claude terminal |
| `q` | sidebar | minimize |
| `<C-h>` | terminal | focus the sidebar |
| `<C-.>` / `<C-,>` | terminal | next / previous open session |
| `<C-q>` | terminal | minimize |
| `<C-y>` | sidebar, commands, terminal | show or hide the commands window |
| `q` | command output | close the floating window |

To close a session, type `/exit` in Claude or press `x` on it in the sidebar. The conversation is saved; `<CR>` on it resumes later.

### Sidebar status

| Dot | Detail | Meaning |
|---|---|---|
| yellow `●` | `working` | Claude is busy, in this Neovim or any other terminal |
| green `●` | `idle` | running, waiting for you |
| `○` | `2h ago` | not running, with its last activity |

### Files

When Claude writes or edits a file, it opens in the panel on the right with the added lines highlighted and the cursor on the change. Each session remembers the last file it touched, so switching sessions switches the panel too. Focus never leaves the Claude terminal.

### Commands

The first time a session runs a Bash command, a **commands** window opens under the sidebar, listing that session's commands, newest first, titled with the command itself:

| Dot | Detail | Meaning |
|---|---|---|
| yellow `●` | `running · 12s` | still running |
| `○` | `exit 0 · 3s` | finished, with how long it took |
| red `●` | `exit 1 · 3s` | failed |

`<CR>` opens that command's output in a floating window, live while it runs; `q` closes it. Claude still receives the output as usual. The last 50 commands of each session are kept.

The commands window uses the same keys as the sidebar and follows the session you are in. `<C-y>` shows or hides it from the sidebar, from the window itself or from the Claude terminal; closing it with `:q` works too, and the next command opens it again.

### Notifications and quitting

- A `vim.notify` fires when a session you are not looking at (bullpen minimized, or another session active) finishes a turn or asks for permission.
- While sessions run, `:qa` and `:q` on the last window refuse to quit, or ask when `'confirm'` is set (LazyVim's default). `:qa!` quits and ends the sessions. `:wqa` and `:xa` are not guarded.

## Options

Defaults:

```lua
opts = {
  cmd = { "claude" },
  sidebar_width = 36,
  commands_height = 12,
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
```

Highlight groups are linked by default, so they follow your colorscheme:

| Group | Default link |
|---|---|
| `ClaudeSessionsHeader`, `ClaudeSessionsDetail`, `ClaudeSessionsInactive` | `Comment` |
| `ClaudeSessionsWorking` | `DiagnosticWarn` |
| `ClaudeSessionsIdle` | `DiagnosticOk` |
| `ClaudeSessionsBlocked` | `DiagnosticError` |
| `ClaudeSessionsSelected` | `Visual` |
| `ClaudeSessionsTab` / `ClaudeSessionsTabActive` | `TabLine` / `TabLineSel` |
| `ClaudeSessionsChanged` | `DiffAdd` |

## How it works

```
claude ──hooks──────────▶ scripts/hook.lua ──┐
   │                                         ├──RPC over $NVIM──▶ panel, notifications
   └──shell prefix──▶ scripts/run.lua ───────┘
```

- **The sidebar** reads Claude Code's own files: transcripts in `~/.claude/projects` (directory, branch, AI title, last prompt) and live session records in `~/.claude/sessions` (working / idle). Transcripts are only parsed again when they grow.
- **Sessions** run `claude` in a Neovim terminal with two additions:
  - `--settings` with `PostToolUse` (`Write|Edit`), `Stop` and `Notification` hooks. They run `scripts/hook.lua`, which calls back into Neovim over `$NVIM`.
  - `CLAUDE_CODE_SHELL_PREFIX=scripts/shell-prefix`, which spots Bash tool commands and runs them through `scripts/run.lua`. It executes the command with `$SHELL`, hands stdout, stderr and the exit code to Claude untouched, and streams the same output to the panel. Everything else that goes through the prefix (hooks, MCP servers) is executed directly.

## Notes

- claude-bullpen.nvim leans on Claude Code internals that may change: the transcript and session file formats, and the shape of Bash tool commands (`eval '…' && pwd -P >| …`) used to recognize them. If that shape changes, commands stop showing in the panel and run under `/bin/sh`.
- Tested on macOS with Neovim 0.11 and Claude Code 2.1.270.
- Commands running in parallel interleave in the panel.
- Highlighted lines stay until Claude edits that file again.
- Notifications only show inside Neovim.
- Each command and hook adds about 25ms (a short-lived `nvim -l` talking to Neovim).
- Only sessions started from the sidebar get the panel and notifications.

## License

[MIT](LICENSE)
