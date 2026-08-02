# live-server.nvim

A development server manager for Neovim. Start it, forget it, keep the same URL.

Manage local dev servers without leaving the editor: start and stop them, watch their
output, pin a port to a project so its URL never changes, and get sensible behaviour
when Neovim is running over SSH.

```
 1 running

  ~/code/portfolio
  ● live-server   running    :5500   up 12m   pinned
     http://127.0.0.1:5500/index.html
  ○ browser-sync  stopped    :3000

 <CR> open  s start/stop  r restart  p port  l logs  y copy  a new  ? help
```

## Why

The usual live-reload workflow has three papercuts that this fixes:

- **The URL keeps moving.** Ports are pinned per project, so bookmarks, an open
  devtools session, a CORS allowlist and a QR code taped to a test phone all keep
  working across restarts and across machines.
- **"Running" doesn't mean reachable.** A browser opens only once the port actually
  accepts connections — not after a fixed one-second guess — and a server that spawns
  but never answers is reported as such instead of being shown as healthy.
- **SSH quietly breaks it.** Editing on a remote box means the server binds loopback
  *over there*. The plugin detects it, hands you the exact `ssh -L` command, and copies
  the URL to *your* clipboard over OSC 52.

## Requirements

Neovim 0.9+, plus at least one backend. The plugin finds whichever you have.

| Backend | Install | Live reload | Notes |
| --- | --- | --- | --- |
| `live_server` | `npm i -g live-server` | yes | Injects CSS without a page reload. Default. |
| `browser_sync` | `npm i -g browser-sync` | yes | Syncs scroll, clicks and input across devices. |
| `serve` | `npm i -g serve` (or npx) | no | Clean URLs, correct MIME types, production-like. |
| `python` | already installed | no | Zero-install fallback. |

No `pgrep`, no `pkill`, no shell. `:checkhealth live_server` reports what it found.

## Install

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "G00380316/live-server.nvim",
  cmd = "LiveServer",
  keys = {
    { "<leader>ls", "<Cmd>LiveServer toggle<CR>", desc = "Toggle live server" },
    { "<leader>lm", "<Cmd>LiveServer<CR>",        desc = "Live server manager" },
    { "<leader>lo", "<Cmd>LiveServer open<CR>",   desc = "Open in browser" },
    { "<leader>ll", "<Cmd>LiveServer logs<CR>",   desc = "Live server logs" },
  },
  opts = {},
}
```

</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use({
  "G00380316/live-server.nvim",
  config = function()
    require("live_server").setup({})
  end,
})
```

</details>

<details>
<summary><b>mini.deps / vim.pack</b></summary>

```lua
require("live_server").setup({})
```

</details>

`opts = {}` is enough — every option has a working default, and the plugin configures
itself on first use if you never call `setup()` at all.

## Usage

```vim
:LiveServer                 " open the manager
:LiveServer toggle          " start or stop a server for this project
:LiveServer start 3000      " start on a specific port
:LiveServer start browser_sync dir=docs
:LiveServer pin 4000        " this project always uses port 4000
:LiveServer open            " open the current file's page in a browser
:LiveServer logs            " tail the server's output
:LiveServer expose          " let your phone reach it (asks first)
```

Everything completes with `<Tab>`. A bare port or backend name is treated as a start
request, so `:LiveServer 3000` does what it looks like.

### The manager

`:LiveServer` opens a panel listing every server grouped by project.

| Key | Action | | Key | Action |
| --- | --- | --- | --- | --- |
| `<CR>` `o` | open in browser | | `d` | stop and remove |
| `s` | start / stop | | `e` | toggle network exposure |
| `r` | restart, same port | | `f` | ssh forwarding command |
| `p` | change port | | `X` | stop everything |
| `P` | pin / unpin port | | `R` | re-scan for backends |
| `l` | show output | | `<Tab>` | next server |
| `y` | copy URL | | `?` | help |
| `a` | start a new server | | `q` | close |

Every one of these is also a `:LiveServer` subcommand — nothing is keyboard-only.

The log view tails output live and stops following the moment you scroll up, so
reading a stack trace is never interrupted.

## Ports that stay put

By default the port a project ends up with is remembered and reused forever:

```vim
:LiveServer pin 4000     " pin explicitly
:LiveServer unpin        " forget it
:LiveServer pins         " list all pins
:LiveServer pins prune   " drop pins for directories that are gone
```

Four strategies, set with `port.strategy`:

| Strategy | Behaviour |
| --- | --- |
| `"pin"` | Reuse the project's remembered port. **Default.** |
| `"scan"` | First free port in `port.range`. |
| `"stable"` | Derived from the project path — same checkout, same port on every machine, no shared state. |
| `"fixed"` | Always `port.defaults[backend]`; fail rather than move. |

Availability is checked against the operating system, so a port held by a stray Docker
publish or another editor is correctly seen as taken. When the preferred port is busy
the plugin moves to the next free one and tells you which process held the old one.

## Per-project configuration

Drop a `.liveserverrc.json` in the project root and everyone on the team gets the same
setup:

```json
{
  "server": "live_server",
  "port": 4321,
  "root": "public",
  "open": "index.html",
  "entry_file": "index.html"
}
```

`root` may not point outside the project, so a cloned repository can never aim the
server at your home directory.

## Over SSH

When `SSH_CONNECTION` or `SSH_TTY` is set, the plugin stops pretending a browser will
open. Instead it prints what you can actually act on:

```
Serving portfolio at http://127.0.0.1:5500/ (on build-box)

Forward it from your machine:
  ssh -N -L 5500:127.0.0.1:5500 you@build-box

URL copied to your clipboard via OSC 52.
```

OSC 52 means the URL lands on your *local* clipboard even when the remote machine has
no clipboard tool at all. `f` in the manager re-shows and re-copies the command.

## Security

A dev server serves your working tree, including files you have not committed.

- **Loopback by default.** Servers bind `127.0.0.1`. Exposing one to the network is a
  deliberate, confirmed act (`:LiveServer expose`).
- **Project files cannot execute code by accident.** `.liveserverrc.json` may set where
  and how to serve without a prompt. Fields that decide *what runs* (`command`, `args`,
  `env`) require consent, recorded against the exact file contents — the same model as
  Neovim's `:trust`. Any edit, by a teammate or a malicious PR, revokes it and asks
  again, showing the exact command it wants to run.
- Processes are spawned with argv lists, never a shell string.
- A project file may not serve a directory outside its own project.
- Privileged ports are rejected; only local `http://` URLs are handed to a browser;
  state files are written `0600`.

`:LiveServer trust` lists decisions, `:LiveServer trust revoke` clears them.

## Configuration

Full defaults are in [`:help live-server-config`](doc/live-server.txt). The options
most people touch:

```lua
require("live_server").setup({
  server = "auto",            -- or "live_server" | "browser_sync" | "serve" | "python"
  host = "127.0.0.1",
  expose = "ask",             -- true | false | "ask"

  port = {
    strategy = "pin",         -- "pin" | "scan" | "stable" | "fixed"
    range = { 5500, 5599 },
    defaults = { live_server = 5500, browser_sync = 3000 },
  },

  root = {
    serve_dir = nil,          -- e.g. "public"; auto-detected when nil
  },

  browser = {
    auto_open = true,
    open_current_file = true, -- open the page for the buffer you are in
  },

  ui = {
    icons = "auto",           -- "auto" | "nerd" | "ascii" | "text"
    spinner = true,           -- false removes all motion
    compact = false,
  },
})
```

Unknown keys, wrong types and out-of-range values are reported in one message and then
ignored — a typo never breaks your `init.lua`.

### Accessibility

- Status is always spelled out as a word next to the icon; nothing is conveyed by
  colour or glyph alone.
- `ui.icons = "text"` removes glyphs entirely; `"ascii"` avoids non-ASCII.
- `ui.spinner = false` removes all motion.
- Highlight groups are `default link`s to standard groups, so the panel follows your
  colorscheme's contrast in light and dark.
- Below `ui.min_float_width` columns the panel opens as a split rather than a cramped
  float, and lines never exceed the window width.

## Statusline

```lua
-- lualine
sections = { lualine_x = { require("live_server").lualine() } }

-- anything else
require("live_server").statusline()   -- "● 5500", or "" when idle
```

Rebuilt only when a server actually changes state, so calling it on every redraw costs
nothing.

## Lua API

```lua
local ls = require("live_server")

ls.start({ adapter = "live_server", port = 3000, dir = "docs" })
ls.toggle()
ls.stop()
ls.restart()
ls.open()

ls.pin(4000)
ls.servers({ active_only = true })
ls.current()

ls.on("ready", function(payload)
  vim.notify("preview at " .. payload.server:url())
end)
```

Every state change also fires a `User` autocommand — `LiveServerStarting`,
`LiveServerReady`, `LiveServerStopped`, `LiveServerCrashed`, `LiveServerChanged` —
with the server's info table as `data`:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "LiveServerReady",
  callback = function(event)
    print(event.data.url, event.data.port, event.data.project_name)
  end,
})
```

### Custom backends

```lua
require("live_server").setup({
  adapters = {
    vite = {
      display = "vite",
      bin = "npx",
      live_reload = true,
      command = { "npx", "vite", "--port", "{port}", "--host", "{host}", "{dir}" },
    },
  },
})
```

Or with full control over the argv, `require("live_server").register_adapter({ ... })`
with a `build(ctx)` function. See `:help live-server-adapters`.

## Migrating from 0.x

Everything still works. The old commands and the `live_server.core` / `live_server.utils`
modules forward to the new API and warn once.

| Old option | New |
| --- | --- |
| `live_server_port` | `port.defaults.live_server` |
| `browser_sync_port` | `port.defaults.browser_sync` |
| `files_to_watch` | `watch.extensions` (a list, no quoting) |
| `auto_open_browser` | `browser.auto_open` |

Behaviour changes worth knowing: servers are no longer detached (Neovim owning them is
what makes cleanup reliable), ports are checked against the OS rather than an internal
list, the browser waits for the port to actually answer, servers bind loopback instead
of every interface, and browser-sync's extra UI port is disabled.

Full notes: `:help live-server-migration`.

## Development

```bash
make test        # full suite, spawns real servers
make test-unit   # everything except the integration specs
make lint        # luacheck, if installed
make format      # stylua, if installed
```

Tests point `XDG_*` at `./.test-home`, so a run can never touch your real port pins or
trust records.

## Troubleshooting

`:checkhealth live_server` first — it reports backends and versions, free ports in your
range, every pin, whether this is an SSH session, and where the log lives. For a bug
report, set `log = { level = "debug" }`, reproduce, and attach `:LiveServer log`.

Common cases are covered in `:help live-server-troubleshooting`.

## License

See [LICENSE](LICENSE).
