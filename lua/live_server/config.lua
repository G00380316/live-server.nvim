---@mod live_server.config Configuration schema, defaults and validation
---
--- A bad option should never break a user's `init.lua`. Validation therefore
--- reports every problem it finds at once, discards only the offending values,
--- and keeps the rest of the configuration working.

local M = {}

--- `vim.islist` on 0.10+, `vim.tbl_islist` on 0.9.
local islist = vim.islist or vim.tbl_islist

---@class live_server.Config
local defaults = {
  --- Adapter used when a command does not name one.
  --- `"auto"` picks the first installed adapter from `adapter_priority`.
  ---@type "auto"|"live_server"|"browser_sync"|"serve"|"python"|string
  server = "auto",

  --- Order `server = "auto"` searches for a backend. `node` comes first
  --- because a project that ships its own dev server almost always means it:
  --- serving a Next.js source tree as static files produces a broken page.
  --- It only applies in projects that actually are Node projects, and starting
  --- it always asks for consent first.
  ---@type string[]
  adapter_priority = { "node", "live_server", "browser_sync", "serve", "python" },

  --- Extra adapter definitions, keyed by name. See `:help live-server-adapters`.
  ---@type table<string, live_server.AdapterSpec>
  adapters = {},

  --- Interface servers bind to. Loopback keeps a work-in-progress site off the
  --- local network by default; use `expose` to opt in deliberately.
  ---@type string
  host = "127.0.0.1",

  --- Bind `0.0.0.0` so phones and other machines on the LAN can connect.
  --- `"ask"` prompts once per session before exposing anything.
  ---@type boolean|"ask"
  expose = "ask",

  root = {
    --- Markers searched upward from the current file to find the project root.
    ---@type string[]
    patterns = { ".liveserverrc.json", ".git", "package.json", "index.html" },

    --- Used when no marker matches: the editor's cwd or the file's directory.
    ---@type "cwd"|"file"
    fallback = "cwd",

    --- Directory served relative to the project root, e.g. `"public"` or
    --- `"dist"`. `nil` serves the root itself. Auto-detection tries the
    --- entries in `auto` when the root has no `index.html`.
    ---@type string?
    serve_dir = nil,

    --- Candidate sub-directories probed for an `index.html` when
    --- `serve_dir` is unset. Set to `{}` to always serve the project root.
    ---@type string[]
    auto = { "public", "dist", "build", "src", "docs", "www", "site", "app" },
  },

  port = {
    --- How a port is chosen when the command does not specify one.
    ---   `"pin"`    remember the port per project+adapter and reuse it
    ---   `"scan"`   first free port in `range`
    ---   `"stable"` derive deterministically from the project path
    ---   `"fixed"`  always `defaults[adapter]`
    ---@type "pin"|"scan"|"stable"|"fixed"
    strategy = "pin",

    --- Inclusive port range used by the `scan` and `stable` strategies, and as
    --- the fallback whenever a preferred port is already taken.
    ---@type integer[]
    range = { 5500, 5599 },

    --- Preferred starting port per adapter.
    ---@type table<string, integer>
    defaults = {
      -- 3000 is what Next.js, Nuxt and Express all print in their own docs, so
      -- a Node project lands where its README says it will.
      node = 3000,
      live_server = 5500,
      browser_sync = 3000,
      serve = 3000,
      python = 8000,
    },

    --- Persist the resolved port so the same project reopens on the same URL
    --- across sessions (keeps browser tabs, bookmarks and devtools state valid).
    ---@type boolean
    remember = true,

    --- How many ports to try before giving up.
    ---@type integer
    max_attempts = 64,
  },

  browser = {
    --- Open a browser once the server is confirmed accepting connections.
    ---@type boolean
    auto_open = true,

    --- Command used to open URLs. `nil` uses `vim.ui.open()` / the platform
    --- default. Either a string or an argv list; the URL is appended.
    ---@type string|string[]|nil
    cmd = nil,

    --- Open the page matching the current buffer rather than the site root.
    ---@type boolean
    open_current_file = true,

    --- Reuse the same browser tab per project where the platform allows it.
    ---@type boolean
    reuse_tab = true,
  },

  watch = {
    --- Extensions that trigger a reload, for adapters that take a file list.
    ---@type string[]
    extensions = { "html", "htm", "css", "js", "mjs", "cjs", "json", "svg", "md" },

    --- Glob patterns excluded from watching. Large directories here are the
    --- single biggest win for CPU use on big repositories.
    ---@type string[]
    ignore = {
      "node_modules",
      ".git",
      "dist",
      "build",
      "coverage",
      ".next",
      ".nuxt",
      ".cache",
      "vendor",
      "target",
      "__pycache__",
    },

    --- Debounce in milliseconds between a file change and the browser reload.
    ---@type integer
    delay = 100,
  },

  --- Single-page-app fallback: serve this file for unknown routes.
  ---@type string?
  entry_file = nil,

  --- Extra CLI arguments appended per adapter, e.g.
  --- `{ live_server = { "--cors" } }`.
  ---@type table<string, string[]>
  extra_args = {},

  restart = {
    --- Restart a server that exits unexpectedly.
    ---@type boolean
    on_crash = true,

    --- Consecutive crash restarts before giving up.
    ---@type integer
    max_attempts = 3,

    --- Base delay between restart attempts; grows exponentially.
    ---@type integer
    backoff = 1000,
  },

  ready = {
    --- How long to wait for the port to start accepting connections before
    --- reporting the server as unhealthy.
    ---@type integer
    timeout = 15000,

    --- Poll interval while waiting.
    ---@type integer
    interval = 150,
  },

  project = {
    --- Read per-project configuration files.
    ---@type boolean
    enabled = true,

    --- Filenames searched in the project root, in order.
    ---@type string[]
    files = { ".liveserverrc.json", ".live-server.json" },

    --- How to handle project files that change how a process is executed
    --- (`command`, `args`, `env`):
    ---   `"prompt"` ask once per file content, then remember the answer
    ---   `"deny"`   ignore those fields silently
    ---   `"allow"`  trust every project file (only for fully trusted machines)
    ---@type "prompt"|"deny"|"allow"
    trust = "prompt",
  },

  remote = {
    --- Detect SSH sessions and adapt URLs, browser opening and hints.
    ---@type boolean
    detect = true,

    --- Show the `ssh -L` command needed to reach the server from the machine
    --- the browser runs on.
    ---@type boolean
    forward_hint = true,

    --- Copy the URL to the system clipboard (OSC 52 when available) instead of
    --- trying to launch a browser that the user cannot see.
    ---@type boolean
    copy_url = true,
  },

  ui = {
    --- Float border style, or `"none"`.
    ---@type string|string[]
    border = "rounded",

    --- Dashboard size. Fractions (<= 1) are a share of the editor, integers are
    --- absolute cell counts. Always clamped to what the terminal can show.
    ---@type number
    width = 0.7,
    ---@type number
    height = 0.6,

    --- Icon set. `"auto"` uses Nerd Font glyphs when `vim.g.have_nerd_font` is
    --- set, `"text"` renders words only — the most screen-reader friendly mode.
    ---@type "auto"|"nerd"|"ascii"|"text"
    icons = "auto",

    --- Animate the "starting" indicator. Disable to remove all motion.
    ---@type boolean
    spinner = true,

    --- One line per server instead of a line plus its URL.
    ---@type boolean
    compact = false,

    --- Show the keybinding footer inside the dashboard.
    ---@type boolean
    footer = true,

    --- Refresh interval, in ms, while the dashboard is open. The timer only
    --- runs when a server is in a transient state; steady state is event-driven.
    ---@type integer
    refresh = 250,

    --- Open the dashboard in a split instead of a float below this width.
    ---@type integer
    min_float_width = 64,

    --- Highlight group overrides, e.g. `{ LiveServerRunning = { fg = "#a6e3a1" } }`.
    ---@type table<string, table>
    highlights = {},

    --- Dashboard keymaps. Set a value to `false` to unmap it. Every action is
    --- also reachable from `:LiveServer` so no feature is keyboard-only.
    keys = {
      open = { "<CR>", "o" },
      toggle = "s",
      restart = "r",
      stop_all = "X",
      logs = "l",
      yank_url = "y",
      change_port = "p",
      pin_port = "P",
      new = "a",
      delete = "d",
      refresh = "R",
      expose = "e",
      forward_hint = "f",
      help = "?",
      close = { "q", "<Esc>" },
    },
  },

  notify = {
    --- Route user-facing messages through `vim.notify`.
    ---@type boolean
    enabled = true,

    --- Suppress notifications below this level.
    ---@type "trace"|"debug"|"info"|"warn"|"error"
    level = "info",
  },

  log = {
    --- File log verbosity. The log lives at
    --- `stdpath("state")/live-server.nvim/live-server.log`.
    ---@type "off"|"trace"|"debug"|"info"|"warn"|"error"
    level = "warn",

    --- Lines of process output retained in memory per server.
    ---@type integer
    max_lines = 2000,
  },

  statusline = {
    --- Prefix shown before the port list.
    ---@type string
    prefix = "",
    --- Show the adapter name alongside the port.
    ---@type boolean
    show_adapter = false,
  },

  --- Register the pre-1.0 command names (`:LiveServerToggle`, `:BrowserSyncToggle`, …).
  ---@type boolean
  legacy_commands = true,

  --- Warn at startup about servers left running by a previous crashed session.
  ---@type boolean
  detect_orphans = true,

  --- Called after a server reaches the running state.
  ---@type fun(server: live_server.Server)|nil
  on_start = nil,

  --- Called after a server stops, crashes included.
  ---@type fun(server: live_server.Server)|nil
  on_stop = nil,
}

---@type live_server.Config
M.options = vim.deepcopy(defaults)

---@type boolean
M.did_setup = false

--- Read-only access to the pristine defaults.
---@return live_server.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

---@param tbl table
---@param path string dotted path
---@return any
local function get_path(tbl, path)
  local node = tbl
  for part in path:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  return node
end

---@param tbl table
---@param path string
---@param value any
local function set_path(tbl, path, value)
  local parts = vim.split(path, ".", { plain = true })
  local node = tbl
  for i = 1, #parts - 1 do
    node = node[parts[i]]
    if type(node) ~= "table" then
      return
    end
  end
  node[parts[#parts]] = value
end

---@class live_server.Rule
---@field types string[] acceptable `type()` results
---@field one_of? any[]
---@field check? fun(value: any): boolean, string?

---@type table<string, live_server.Rule>
local rules = {
  ["server"] = { types = { "string" } },
  ["adapter_priority"] = { types = { "table" } },
  ["adapters"] = { types = { "table" } },
  ["host"] = {
    types = { "string" },
    check = function(value)
      if value:match("^[%w%.%-:_%[%]]+$") then
        return true
      end
      return false, "not a valid hostname or IP address"
    end,
  },
  ["expose"] = { types = { "boolean", "string" }, one_of = { true, false, "ask" } },
  ["root.patterns"] = { types = { "table" } },
  ["root.fallback"] = { types = { "string" }, one_of = { "cwd", "file" } },
  ["root.serve_dir"] = { types = { "string", "nil" } },
  ["root.auto"] = { types = { "table" } },
  ["port.strategy"] = { types = { "string" }, one_of = { "pin", "scan", "stable", "fixed" } },
  ["port.range"] = {
    types = { "table" },
    check = function(value)
      if type(value[1]) ~= "number" or type(value[2]) ~= "number" then
        return false, "expected { low, high }"
      end
      if value[1] < 1 or value[2] > 65535 or value[1] > value[2] then
        return false, "expected an ascending range within 1-65535"
      end
      return true
    end,
  },
  ["port.defaults"] = { types = { "table" } },
  ["port.remember"] = { types = { "boolean" } },
  ["port.max_attempts"] = { types = { "number" } },
  ["browser.auto_open"] = { types = { "boolean" } },
  ["browser.cmd"] = { types = { "string", "table", "nil" } },
  ["browser.open_current_file"] = { types = { "boolean" } },
  ["browser.reuse_tab"] = { types = { "boolean" } },
  ["watch.extensions"] = { types = { "table" } },
  ["watch.ignore"] = { types = { "table" } },
  ["watch.delay"] = { types = { "number" } },
  ["entry_file"] = { types = { "string", "nil" } },
  ["extra_args"] = { types = { "table" } },
  ["restart.on_crash"] = { types = { "boolean" } },
  ["restart.max_attempts"] = { types = { "number" } },
  ["restart.backoff"] = { types = { "number" } },
  ["ready.timeout"] = { types = { "number" } },
  ["ready.interval"] = { types = { "number" } },
  ["project.enabled"] = { types = { "boolean" } },
  ["project.files"] = { types = { "table" } },
  ["project.trust"] = { types = { "string" }, one_of = { "prompt", "deny", "allow" } },
  ["remote.detect"] = { types = { "boolean" } },
  ["remote.forward_hint"] = { types = { "boolean" } },
  ["remote.copy_url"] = { types = { "boolean" } },
  ["ui.border"] = { types = { "string", "table" } },
  ["ui.width"] = { types = { "number" } },
  ["ui.height"] = { types = { "number" } },
  ["ui.icons"] = { types = { "string" }, one_of = { "auto", "nerd", "ascii", "text" } },
  ["ui.spinner"] = { types = { "boolean" } },
  ["ui.compact"] = { types = { "boolean" } },
  ["ui.footer"] = { types = { "boolean" } },
  ["ui.refresh"] = { types = { "number" } },
  ["ui.min_float_width"] = { types = { "number" } },
  ["ui.highlights"] = { types = { "table" } },
  ["ui.keys"] = { types = { "table" } },
  ["notify.enabled"] = { types = { "boolean" } },
  ["notify.level"] = { types = { "string" }, one_of = { "trace", "debug", "info", "warn", "error" } },
  ["log.level"] = { types = { "string" }, one_of = { "off", "trace", "debug", "info", "warn", "error" } },
  ["log.max_lines"] = { types = { "number" } },
  ["statusline.prefix"] = { types = { "string" } },
  ["statusline.show_adapter"] = { types = { "boolean" } },
  ["legacy_commands"] = { types = { "boolean" } },
  ["detect_orphans"] = { types = { "boolean" } },
  ["on_start"] = { types = { "function", "nil" } },
  ["on_stop"] = { types = { "function", "nil" } },
}

--- Keys whose contents are user data rather than schema, so unknown-key
--- detection must not descend into them.
local opaque = {
  ["adapters"] = true,
  ["extra_args"] = true,
  ["port.defaults"] = true,
  ["ui.highlights"] = true,
  ["ui.keys"] = true,
}

---@param user table
---@param reference table
---@param prefix string
---@param issues string[]
local function collect_unknown(user, reference, prefix, issues)
  for key, value in pairs(user) do
    local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    if reference[key] == nil and not opaque[path] then
      issues[#issues + 1] = ("unknown option `%s`"):format(path)
    elseif type(value) == "table" and type(reference[key]) == "table" and not opaque[path] then
      -- Only descend into map-like sub-tables; lists are values, not schema.
      if not islist(value) then
        collect_unknown(value, reference[key], path, issues)
      end
    end
  end
end

--- Validate `opts` against the schema.
---@param opts table
---@return string[] issues human-readable problems, empty when the config is clean
---@return string[] invalid dotted paths whose values must be discarded
function M.validate(opts)
  local issues, invalid = {}, {}
  if type(opts) ~= "table" then
    return { "setup() expects a table" }, {}
  end

  collect_unknown(opts, defaults, "", issues)

  for path, rule in pairs(rules) do
    local value = get_path(opts, path)
    if value ~= nil or vim.tbl_contains(rule.types, "nil") then
      local actual = type(value)
      if value ~= nil and not vim.tbl_contains(rule.types, actual) then
        issues[#issues + 1] = ("`%s`: expected %s, got %s"):format(path, table.concat(rule.types, "|"), actual)
        invalid[#invalid + 1] = path
      elseif value ~= nil and rule.one_of and not vim.tbl_contains(rule.one_of, value) then
        local allowed = vim.tbl_map(tostring, rule.one_of)
        issues[#issues + 1] = ("`%s`: expected one of %s"):format(path, table.concat(allowed, ", "))
        invalid[#invalid + 1] = path
      elseif value ~= nil and rule.check then
        local ok, why = rule.check(value)
        if not ok then
          issues[#issues + 1] = ("`%s`: %s"):format(path, why or "invalid value")
          invalid[#invalid + 1] = path
        end
      end
    end
  end

  return issues, invalid
end

--- Merge user options over the defaults, discarding anything that fails
--- validation and reporting every problem in a single notification.
---@param opts? table
---@return live_server.Config
function M.setup(opts)
  opts = opts or {}
  local issues, invalid = M.validate(opts)

  if #issues > 0 then
    local sanitized = vim.deepcopy(opts)
    for _, path in ipairs(invalid) do
      set_path(sanitized, path, nil)
    end
    opts = sanitized
    vim.schedule(function()
      vim.notify(
        "live-server.nvim: invalid configuration\n  " .. table.concat(issues, "\n  "),
        vim.log.levels.ERROR,
        { title = "Live Server" }
      )
    end)
  end

  -- Lists are replaced wholesale rather than merged: a user who sets
  -- `watch.ignore` means "these", not "these plus my defaults".
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  local list_options = {
    "adapter_priority",
    "root.patterns",
    "root.auto",
    "port.range",
    "project.files",
    "watch.extensions",
    "watch.ignore",
  }
  for _, path in ipairs(list_options) do
    local override = get_path(opts, path)
    if override ~= nil then
      set_path(M.options, path, vim.deepcopy(override))
    end
  end

  M.did_setup = true
  return M.options
end

--- Current options, running `setup()` with defaults on first access so every
--- entry point works even when the user never called it.
---@return live_server.Config
function M.get()
  if not M.did_setup then
    M.setup({})
  end
  return M.options
end

return M
