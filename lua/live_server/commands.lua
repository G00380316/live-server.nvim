---@mod live_server.commands The `:LiveServer` command tree
---
--- One command with subcommands and real completion, rather than a dozen
--- top-level names competing for the `:L` prefix. Every dashboard action is
--- reachable here too, so nothing in the plugin is keyboard-only or
--- mouse-only.

local log = require("live_server.log")
local manager = require("live_server.manager")

local M = {}

---@class live_server.CommandArgs
---@field positional string[]
---@field flags table<string, string|boolean>

--- Parse `start live_server port=3000 dir=public expose` into positionals and
--- flags. Deliberately forgiving: `port 3000` works as well as `port=3000`.
---@param fargs string[]
---@return live_server.CommandArgs
local function parse(fargs)
  local positional, flags = {}, {}
  local index = 1
  while index <= #fargs do
    local arg = fargs[index]
    local key, value = arg:match("^(%w[%w_]*)=(.*)$")
    if key then
      flags[key] = value == "" and true or value
    elseif arg:match("^%-%-") then
      local name = arg:gsub("^%-%-", "")
      local negated = name:match("^no%-(.+)$")
      if negated then
        flags[negated:gsub("%-", "_")] = false
      else
        flags[name:gsub("%-", "_")] = true
      end
    else
      positional[#positional + 1] = arg
    end
    index = index + 1
  end
  return { positional = positional, flags = flags }
end

---@param value any
---@return boolean?
local function as_boolean(value)
  if value == nil then
    return nil
  end
  if type(value) == "boolean" then
    return value
  end
  local lowered = tostring(value):lower()
  if lowered == "true" or lowered == "yes" or lowered == "1" then
    return true
  end
  if lowered == "false" or lowered == "no" or lowered == "0" then
    return false
  end
  return nil
end

---@param args live_server.CommandArgs
---@return live_server.StartOpts
local function start_opts(args)
  local adapters = require("live_server.adapters")
  local opts = {}

  for _, value in ipairs(args.positional) do
    if tonumber(value) then
      opts.port = tonumber(value)
    elseif adapters.get(value) or value == "auto" then
      opts.adapter = value
    else
      opts.dir = value
    end
  end

  opts.port = opts.port or args.flags.port
  opts.adapter = opts.adapter or args.flags.server or args.flags.adapter
  opts.dir = opts.dir or args.flags.dir
  opts.path = args.flags.path or args.flags.open_path
  opts.expose = as_boolean(args.flags.expose)
  opts.open = as_boolean(args.flags.open)
  return opts
end

--- Pick the server a command should act on: the one for the current project,
--- or ask when there is more than one.
---@param callback fun(server: live_server.Server?)
local function pick_server(callback)
  local project = require("live_server.project").get()
  local candidates = manager.for_project(project.root, { active_only = true })
  if #candidates == 0 then
    candidates = manager.servers({ active_only = true })
  end
  if #candidates == 0 then
    log.notify("No servers are running.", "warn")
    return callback(nil)
  end
  require("live_server.ui.prompt").server(candidates, {}, callback)
end

--------------------------------------------------------------------------------
-- Subcommands
--------------------------------------------------------------------------------

---@class live_server.Subcommand
---@field run fun(args: live_server.CommandArgs)
---@field desc string shown in completion and error messages
---@field complete? fun(lead: string): string[] candidates for the next argument

---@type table<string, live_server.Subcommand>
local subcommands = {}

subcommands.start = {
  desc = "Start a server for the current project",
  run = function(args)
    manager.start(start_opts(args))
  end,
  complete = function()
    local out = { "auto" }
    vim.list_extend(out, require("live_server.adapters").names())
    vim.list_extend(out, { "port=", "dir=", "expose", "no-open" })
    return out
  end,
}

subcommands.stop = {
  desc = "Stop a server (or `all`)",
  run = function(args)
    if args.positional[1] == "all" or args.flags.all then
      manager.stop_all()
      return
    end
    pick_server(function(server)
      if server then
        manager.stop(server)
      end
    end)
  end,
  complete = function()
    return { "all" }
  end,
}

subcommands.toggle = {
  desc = "Start the project's server, or stop it if it is running",
  run = function(args)
    manager.toggle(start_opts(args))
  end,
  complete = function()
    local out = { "auto" }
    vim.list_extend(out, require("live_server.adapters").names())
    return out
  end,
}

subcommands.restart = {
  desc = "Restart a server on the same port",
  run = function()
    pick_server(function(server)
      if server then
        manager.restart(server)
      end
    end)
  end,
}

subcommands.open = {
  desc = "Open the served page in a browser",
  run = function(args)
    pick_server(function(server)
      if server then
        require("live_server.browser").open(server, args.positional[1])
      end
    end)
  end,
}

subcommands.dashboard = {
  desc = "Open the server manager",
  run = function()
    require("live_server.ui.dashboard").open()
  end,
}

subcommands.logs = {
  desc = "Show a server's output",
  run = function()
    pick_server(function(server)
      if server then
        require("live_server.ui.logs").open(server)
      end
    end)
  end,
}

subcommands.status = {
  desc = "Print a one-line summary",
  run = function()
    local servers = manager.servers({ active_only = true })
    if #servers == 0 then
      log.notify("No servers are running.", "info")
      return
    end
    local lines = {}
    for _, server in ipairs(servers) do
      lines[#lines + 1] = ("%-20s %-14s %-9s %s"):format(
        server.project.name,
        server.adapter.display,
        server.status,
        server:url()
      )
    end
    log.notify(table.concat(lines, "\n"), "info")
  end,
}

subcommands.port = {
  desc = "Move a server to another port",
  run = function(args)
    local requested = tonumber(args.positional[1] or args.flags.port)
    pick_server(function(server)
      if not server then
        return
      end
      if requested then
        manager.change_port(server, requested)
        return
      end
      require("live_server.ui.prompt").port(
        { default = server.port, host = server.host, prompt = "New port: " },
        function(port)
          if port then
            manager.change_port(server, port)
          end
        end
      )
    end)
  end,
}

subcommands.pin = {
  desc = "Pin the current project to a port",
  run = function(args)
    local project = require("live_server.project").get()
    local port_mod = require("live_server.port")
    local requested = tonumber(args.positional[1] or args.flags.port)
    local adapter = args.flags.server or args.flags.adapter

    local active = manager.find_active(project.root, adapter)
    local adapter_name = adapter or (active and active.adapter.name)
    if not adapter_name then
      local resolved = require("live_server.adapters").resolve()
      adapter_name = resolved and resolved.name
    end
    if not adapter_name then
      log.notify("Could not work out which server to pin. Pass `server=live_server`.", "error")
      return
    end

    local port = requested or (active and active.port)
    if not port then
      require("live_server.ui.prompt").port({
        prompt = ("Pin %s for %s to port: "):format(adapter_name, project.name),
        allow_busy = true,
      }, function(chosen)
        if chosen then
          port_mod.pin(project.root, adapter_name, chosen)
          log.notify(("Pinned %s to port %d for %s."):format(adapter_name, chosen, project.name), "info")
        end
      end)
      return
    end

    port_mod.pin(project.root, adapter_name, port)
    log.notify(("Pinned %s to port %d for %s."):format(adapter_name, port, project.name), "info")
  end,
}

subcommands.unpin = {
  desc = "Remove this project's port pin",
  run = function(args)
    local project = require("live_server.project").get()
    local adapter = args.flags.server or args.flags.adapter or args.positional[1]
    local port_mod = require("live_server.port")

    if adapter then
      local removed = port_mod.unpin(project.root, adapter)
      log.notify(
        removed and ("Unpinned %s for %s."):format(adapter, project.name) or "No pin for that server.",
        removed and "info" or "warn"
      )
      return
    end

    local removed = 0
    for _, name in ipairs(require("live_server.adapters").names()) do
      if port_mod.unpin(project.root, name) then
        removed = removed + 1
      end
    end
    log.notify(
      removed > 0 and ("Removed %d pin%s for %s."):format(removed, removed == 1 and "" or "s", project.name)
        or ("No pins for %s."):format(project.name),
      removed > 0 and "info" or "warn"
    )
  end,
  complete = function()
    return require("live_server.adapters").names()
  end,
}

subcommands.pins = {
  desc = "List every port pin (`prune` drops missing projects)",
  run = function(args)
    local port_mod = require("live_server.port")
    if args.positional[1] == "prune" then
      local removed = port_mod.prune()
      log.notify(("Pruned %d stale pin%s."):format(removed, removed == 1 and "" or "s"), "info")
      return
    end
    local pins = port_mod.pins()
    if #pins == 0 then
      log.notify("No port pins yet. `:LiveServer pin` records one.", "info")
      return
    end
    local lines = {}
    for _, pin in ipairs(pins) do
      lines[#lines + 1] = ("%-6d %-14s %s"):format(pin.port, pin.adapter, vim.fn.fnamemodify(pin.root, ":~"))
    end
    log.notify(table.concat(lines, "\n"), "info")
  end,
  complete = function()
    return { "prune" }
  end,
}

subcommands.expose = {
  desc = "Restart a server bound to the local network",
  run = function()
    pick_server(function(server)
      if not server then
        return
      end
      local was_exposed = server.exposed
      manager.stop(server, function()
        manager.forget(server)
        manager.start({
          adapter = server.adapter.name,
          dir = server.project.root,
          port = server.port,
          expose = not was_exposed,
        })
      end)
    end)
  end,
}

subcommands.reap = {
  desc = "Stop server processes left behind by a previous session",
  run = function()
    manager.find_orphans(function(orphans)
      if #orphans == 0 then
        log.notify("No leftover server processes.", "info")
        return
      end
      local description = {}
      for _, record in ipairs(orphans) do
        description[#description + 1] = ("  pid %d  port %s  %s"):format(
          record.pid,
          tostring(record.port),
          vim.fn.fnamemodify(record.root or "?", ":~")
        )
      end
      local question = ("Stop %d leftover process%s?\n%s"):format(
        #orphans,
        #orphans == 1 and "" or "es",
        table.concat(description, "\n")
      )
      require("live_server.ui.prompt").confirm(question, {}, function(confirmed)
        if confirmed then
          local killed = manager.reap(orphans)
          log.notify(("Stopped %d process%s."):format(killed, killed == 1 and "" or "es"), "info")
        end
      end)
    end)
  end,
}

subcommands.trust = {
  desc = "Show or revoke project-file trust decisions",
  run = function(args)
    local trust = require("live_server.trust")
    if args.positional[1] == "revoke" then
      local removed = trust.revoke(args.positional[2])
      log.notify(("Revoked %d trust record%s."):format(removed, removed == 1 and "" or "s"), "info")
      return
    end
    local records = trust.list()
    if #records == 0 then
      log.notify("No project files have been trusted.", "info")
      return
    end
    local lines = {}
    for _, record in ipairs(records) do
      lines[#lines + 1] = ("%-6s %s"):format(record.decision, vim.fn.fnamemodify(record.path, ":~"))
    end
    log.notify(table.concat(lines, "\n"), "info")
  end,
  complete = function()
    return { "revoke" }
  end,
}

subcommands.log = {
  desc = "Open the plugin's debug log",
  run = function()
    local path = log.path()
    if not require("live_server.util").is_file(path) then
      log.notify("No log yet. Raise `log.level` to record one.", "info")
      return
    end
    vim.cmd.split(vim.fn.fnameescape(path))
  end,
}

subcommands.health = {
  desc = "Run the health check",
  run = function()
    vim.cmd("checkhealth live_server")
  end,
}

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

---@return string[]
local function subcommand_names()
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return names
end

---@param args_string string
---@param cmd_line string
---@return string[]
local function complete(args_string, cmd_line)
  local parts = vim.split(vim.trim(cmd_line), "%s+")
  -- `parts[1]` is the command itself.
  local finished = cmd_line:sub(-1) == " "
  local depth = #parts - 1 + (finished and 1 or 0)

  if depth <= 1 then
    return vim.tbl_filter(function(name)
      return name:find(args_string, 1, true) == 1
    end, subcommand_names())
  end

  local entry = subcommands[parts[2]]
  if not entry or not entry.complete then
    return {}
  end
  return vim.tbl_filter(function(candidate)
    return candidate:find(args_string, 1, true) == 1
  end, entry.complete(args_string))
end

--- Run a `:LiveServer` invocation. Shared by the real command and by the lazy
--- stub in `plugin/`, so there is only ever one dispatch path.
---@param fargs string[]
function M.dispatch(fargs)
  fargs = vim.deepcopy(fargs or {})
  if #fargs == 0 then
    require("live_server.ui.dashboard").open()
    return
  end

  local name = table.remove(fargs, 1)
  local entry = subcommands[name]
  if not entry then
    -- Be helpful rather than pedantic: a bare port or adapter name is
    -- obviously a start request.
    if tonumber(name) or require("live_server.adapters").get(name) then
      table.insert(fargs, 1, name)
      manager.start(start_opts(parse(fargs)))
      return
    end
    log.notify(
      ("Unknown subcommand '%s'. Try one of: %s"):format(name, table.concat(subcommand_names(), ", ")),
      "error"
    )
    return
  end

  local ok, err = pcall(entry.run, parse(fargs))
  if not ok then
    log.notify(("`:LiveServer %s` failed: %s"):format(name, err), "error")
    log.error("subcommand failed", { name = name, err = tostring(err) })
  end
end

M.complete = complete

--- Define `:LiveServer` and, when enabled, the pre-1.0 command names.
function M.setup()
  vim.api.nvim_create_user_command("LiveServer", function(cmd)
    M.dispatch(cmd.fargs)
  end, {
    nargs = "*",
    complete = complete,
    desc = "Manage development servers",
  })

  if not require("live_server.config").get().legacy_commands then
    return
  end

  ---@type table<string, { run: fun(a: table), desc: string, nargs?: string }>
  local legacy = {
    LiveServerToggle = {
      desc = "Toggle live-server (deprecated: `:LiveServer toggle`)",
      nargs = "?",
      run = function(a)
        manager.toggle({ adapter = "live_server", port = a.fargs[1] })
      end,
    },
    LiveServerStart = {
      desc = "Start live-server (deprecated: `:LiveServer start`)",
      nargs = "?",
      run = function(a)
        manager.start({ adapter = "live_server", port = a.fargs[1] })
      end,
    },
    LiveServerStop = {
      desc = "Stop all servers (deprecated: `:LiveServer stop all`)",
      nargs = 0,
      run = function()
        manager.stop_all()
      end,
    },
    BrowserSyncToggle = {
      desc = "Toggle browser-sync (deprecated: `:LiveServer toggle browser_sync`)",
      nargs = "?",
      run = function(a)
        manager.toggle({ adapter = "browser_sync", port = a.fargs[1] })
      end,
    },
    LiveServerList = {
      desc = "Open the server manager (deprecated: `:LiveServer`)",
      nargs = 0,
      run = function()
        require("live_server.ui.dashboard").open()
      end,
    },
    LiveServerPrompt = {
      desc = "Start live-server after asking for a port (deprecated)",
      nargs = 0,
      run = function()
        require("live_server.ui").start_server_with_prompt("live_server")
      end,
    },
    BrowserSyncPrompt = {
      desc = "Start browser-sync after asking for a port (deprecated)",
      nargs = 0,
      run = function()
        require("live_server.ui").start_server_with_prompt("browser_sync")
      end,
    },
    LiveServerOpen = {
      desc = "Open the live-server URL (deprecated: `:LiveServer open`)",
      nargs = 0,
      run = function()
        local project = require("live_server.project").get()
        local server = manager.find_active(project.root, "live_server") or manager.find_active(project.root)
        if server then
          require("live_server.browser").open(server)
        else
          log.notify("No server is running for this project.", "warn")
        end
      end,
    },
    BrowserSyncOpen = {
      desc = "Open the browser-sync URL (deprecated: `:LiveServer open`)",
      nargs = 0,
      run = function()
        local project = require("live_server.project").get()
        local server = manager.find_active(project.root, "browser_sync")
        if server then
          require("live_server.browser").open(server)
        else
          log.notify("browser-sync is not running for this project.", "warn")
        end
      end,
    },
  }

  for name, spec in pairs(legacy) do
    if vim.fn.exists(":" .. name) == 0 then
      vim.api.nvim_create_user_command(name, spec.run, { nargs = spec.nargs or "?", desc = spec.desc })
    end
  end
end

--- Exposed for the docs and for tests.
---@return table
function M.subcommands()
  return subcommands
end

return M
