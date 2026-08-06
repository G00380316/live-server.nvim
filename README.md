# live-server.nvim

A development server manager for Neovim. Start it, forget it, keep the same URL.

Manage local dev servers without leaving the editor — static sites *and* your Next.js,
Vite or Express app. Start and stop them, watch their output, pin a port to a project so
its URL never changes, and get sensible behaviour when Neovim is running over SSH.

```
 2 running

  ~/code/shop
  ● Next.js       running    :3000   up 12m   pinned
     http://127.0.0.1:3000/

  ~/code/portfolio
  ● live-server   running    :5500   up 4m
     http://127.0.0.1:5500/index.html
  ○ browser-sync  stopped    :3001

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
| `node` | nothing extra | per framework | The project's **own** dev server. Picked automatically inside a framework project. |
| `live_server` | `npm i -g live-server` | yes | Injects CSS without a page reload. |
| `browser_sync` | `npm i -g browser-sync` | yes | Syncs scroll, clicks and input across devices. |
| `serve` | `npm i -g serve` (or npx) | no | Clean URLs, correct MIME types, production-like. |
| `python` | already installed | no | Zero-install fallback. |

No `pgrep`, no `pkill`, no shell. `:checkhealth live_server` reports what it found —
including which framework it detected in the current project and what it would run.

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

## Node and framework projects

In a Next.js, Vite, Nuxt, Astro, SvelteKit, Angular, Express (…) project, `:LiveServer
toggle` runs **the dev server the repository already defines** rather than serving your
source tree as files:

```
:LiveServer toggle          # -> pnpm run dev --port 3000 --host 127.0.0.1
```

The framework comes from `package.json` dependencies (most specific first, so SvelteKit
is not mistaken for the Vite it is built on), and the package manager from the lockfile —
`pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `package-lock.json`.

**Ports reach the process the way that framework expects.** Next.js gets `--hostname`,
everything else gets `--host`; Vite and SvelteKit also get `--strictPort` so they fail
loudly instead of drifting somewhere we would then report incorrectly. Express, CRA,
NestJS and unrecognised scripts get `PORT`/`HOST` in the environment, the one convention
they all share.

**If the process announces a different address than we asked for** — the classic
hard-coded `app.listen(4000)` — the plugin believes the process, adopts that port, and
says so. A working server is never shown as unreachable because of our own bookkeeping.

**Cold starts are budgeted per framework.** A Next.js or Angular compile gets up to 120s
before it is called unhealthy, instead of the 15s that suits a static server.

### It asks before it runs anything

Serving static files reads files. Starting a dev server *executes code the repository
wrote*, so the first time it shows you exactly what that is:

```
Run the Next.js dev server defined by this repository?

  script:  dev = next dev
  via:     pnpm

Defined in ~/code/shop/package.json. This executes code from the repository.
```

The answer is remembered against **that script**, not the whole file — a dependency bump
won't ask again, but changing what `dev` runs will.

`auto` only picks this backend for a *recognised* framework. A plain `package.json` whose
`start` script is `node build.js` is a build step, not a web server; `auto` falls through
to a static server, and `:LiveServer start node` runs it anyway if that's what you meant.

## When the app isn't at the repo root

Plenty of repositories keep the thing you actually run one or two levels down —
and plenty of Neovim setups pin the project root to the git directory, so the
`package.json` never gets found:

```
~/code/my-repo/          <- .git, and where the root is pinned
  frontend/package.json  <- the app
  api/package.json       <- another app
```

`:LiveServer toggle` here starts `frontend`, not the repository. A directory counts
if it has a `package.json` with a dev script, or an `index.html`.

**Where it looks**, in order:

1. **The root itself** — if it's runnable (a monorepo whose `dev` is `turbo run dev`),
   that's the answer and nothing else is searched.
2. **Declared workspaces** — `workspaces` in `package.json`, or `pnpm-workspace.yaml`.
   A repo that says where its packages live is always believed over guesswork.
3. **A bounded walk** below the root — never into `node_modules`, `.git`, build output
   or hidden directories, and capped on depth, results and directories visited.

**Which one starts** when several are found: an explicit `dir=`, then the app containing
the buffer you're in, then a remembered answer, then it asks you once.

```vim
:LiveServer apps          " list what was found
:LiveServer apps forget   " clear the remembered choice
:LiveServer start dir=api " skip the question entirely
```

**Or write the list down.** Commit an `apps` list and every clone starts the same
services on the same ports — no discovery, no prompt, ports used verbatim:

```json
{
  "apps": [
    { "dir": "web",           "port": 3000, "name": "Frontend" },
    { "dir": "server",        "port": 5000 },
    { "dir": "server/socket", "port": 5001 }
  ]
}
```

**One window for all the output.** `:LiveServer logs all` (or `L` in the manager)
interleaves every service in the order things actually happened, tagged and coloured
per service; `1`-`9` narrows to one, `0` shows them all. That's the view that answers
"the frontend broke — what was the API doing at that moment".

**Stop just this repo** with `:LiveServer stop repo`, leaving your other projects alone.

**Every service at once.** Servers are identified by their working directory, not the
repository, so they all run together, each on its own port with its own pin:

```vim
:LiveServer start all     " or `A` in the manager
```

One consent prompt covers the whole set — it lists every command in full, and each
answer is still recorded against that command alone, so editing any one script asks
again. A repo like this works as you'd expect, including the socket servers nested
*inside* the API directories:

```
my-project/
  web/                Next.js frontend
  server/             Express API
  server/socket/      socket.io server, inside the API directory
  ai_server/          a second Express API
  ai_server/socket/   its socket server
```

`socket.io`/`ws` processes are recognised as **Socket servers**: readiness and ports
work normally, but no browser opens at them — there's no page there. A server with
*both* Express and socket.io is an HTTP server with sockets attached, and is treated
as one.

```
 2 running

  ~/code/my-repo
  ● Next.js        web                running   :3000  up 8m   pinned
  ● Node server    server             running   :3001  up 8m   no reload
  ● Socket server  server/socket      running   :3002  up 8m   no reload
  ● Node server    ai_server          running   :3003  up 8m   no reload
  ● Socket server  ai_server/socket   running   :3004  up 8m   no reload
```

Turn it off with `discover = { enabled = false }`, or keep it and never be asked with
`discover = { prompt = false }`.

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
- **Nothing from a repository executes without consent.** That covers both
  `.liveserverrc.json` fields that decide *what runs* (`command`, `args`, `env`) and
  `package.json` dev scripts. Consent is recorded against the exact command — the same
  model as Neovim's `:trust` — so any edit, by a teammate or a malicious PR, revokes it
  and asks again, showing what it wants to run.
- Processes are spawned with argv lists, never a shell string.
- Stopping records the process tree first, then kills it from the leaves up — the
  process holding a port is usually a grandchild of the launcher. If a port is still
  held afterwards, the plugin says so and names the holder rather than claiming a
  clean stop.
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

  -- `node` first: a project that ships its own dev server almost always means it.
  adapter_priority = { "node", "live_server", "browser_sync", "serve", "python" },

  port = {
    strategy = "pin",         -- "pin" | "scan" | "stable" | "fixed"
    range = { 5500, 5599 },
    defaults = { node = 3000, live_server = 5500, browser_sync = 3000 },
  },

  root = {
    serve_dir = nil,          -- e.g. "public"; auto-detected when nil
  },

  browser = {
    auto_open = true,
    open_current_file = true, -- open the page for the buffer you are in
  },

  discover = {
    enabled = true,           -- find apps below the repo root
    depth = 3,
    prompt = true,            -- ask when several are found
    remember = true,
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

CI additionally runs the suite on Windows (the only place the `taskkill`/`tasklist`
paths execute) and a job that scaffolds a real Vite app and a real Express app,
installs them, and starts them through the plugin — so the flags we build are checked
against the actual CLIs, not against stand-ins.

Tests point `XDG_*` at `./.test-home`, so a run can never touch your real port pins or
trust records.

## Troubleshooting

`:checkhealth live_server` first — it reports backends and versions, free ports in your
range, every pin, whether this is an SSH session, and where the log lives. For a bug
report, set `log = { level = "debug" }`, reproduce, and attach `:LiveServer log`.

Common cases are covered in `:help live-server-troubleshooting`.

## License

See [LICENSE](LICENSE).
