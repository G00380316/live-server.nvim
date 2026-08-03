---@mod live_server.manager Server registry and lifecycle orchestration
---
--- The single owner of "which servers exist". Everything user-facing —
--- commands, dashboard, statusline, health — reads from here, so there is
--- exactly one source of truth about what is running.

local adapters = require("live_server.adapters")
local event = require("live_server.event")
local log = require("live_server.log")
local net = require("live_server.net")
local port_mod = require("live_server.port")
local project_mod = require("live_server.project")
local server_mod = require("live_server.server")
local store = require("live_server.store")
local trust = require("live_server.trust")
local util = require("live_server.util")

local M = {}

---@type table<string, live_server.Server>
local registry = {}

---@type boolean set once the user has approved LAN exposure this session
local expose_approved = false

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

--- Every known server, active ones first, then by project and port.
---@param opts? { active_only?: boolean }
---@return live_server.Server[]
function M.servers(opts)
  local out = {}
  for _, server in pairs(registry) do
    if not (opts and opts.active_only) or server:is_active() then
      out[#out + 1] = server
    end
  end
  table.sort(out, function(a, b)
    if a:is_active() ~= b:is_active() then
      return a:is_active()
    end
    if a.project.root ~= b.project.root then
      return a.project.root < b.project.root
    end
    return a.port < b.port
  end)
  return out
end

---@param id string
---@return live_server.Server?
function M.get(id)
  return registry[id]
end

--- Servers belonging to a project root.
---@param root string
---@param opts? { active_only?: boolean }
---@return live_server.Server[]
function M.for_project(root, opts)
  local normalized = util.normalize(root)
  return vim.tbl_filter(function(server)
    return server.project.root == normalized
  end, M.servers(opts))
end

--- The active server for a project + adapter, if any.
---@param root string
---@param adapter_name? string nil matches any adapter
---@return live_server.Server?
function M.find_active(root, adapter_name)
  for _, server in ipairs(M.for_project(root, { active_only = true })) do
    if not adapter_name or server.adapter.name == adapter_name then
      return server
    end
  end
  return nil
end

---@return integer
function M.count_active()
  return #M.servers({ active_only = true })
end

--------------------------------------------------------------------------------
-- Runtime state file (orphan detection)
--------------------------------------------------------------------------------

---@return live_server.Store
local function state_store()
  return store.open("running", { scope = "state" })
end

local function persist_state()
  local db = state_store()
  db:clear()
  for _, server in ipairs(M.servers({ active_only = true })) do
    if server.pid then
      db:set(tostring(server.pid), {
        pid = server.pid,
        port = server.port,
        root = server.project.root,
        adapter = server.adapter.name,
        argv0 = server.argv and server.argv[1] or nil,
        nvim = util.uv.getpid(),
        at = os.time(),
      })
    end
  end
  db:save_soon()
end

--- Find server processes recorded by a previous session that are still alive.
--- Identity is verified against the process table so a recycled PID is never
--- mistaken for ours.
---@param callback fun(orphans: table[])
function M.find_orphans(callback)
  local records = {}
  local self_pid = util.uv.getpid()
  for _, record in pairs(state_store():all()) do
    if type(record) == "table" and record.pid and record.nvim ~= self_pid then
      records[#records + 1] = record
    end
  end
  if #records == 0 then
    return callback({})
  end

  local alive = {}
  for _, record in ipairs(records) do
    -- Signal 0 only checks for existence and permission.
    local ok = pcall(util.uv.kill, record.pid, 0)
    if ok then
      alive[#alive + 1] = record
    end
  end
  if #alive == 0 or util.is_windows then
    return callback(alive)
  end

  -- Confirm the PID still belongs to the command we started.
  local pending = #alive
  local confirmed = {}
  for _, record in ipairs(alive) do
    local output = {}
    local started = pcall(vim.fn.jobstart, { "ps", "-p", tostring(record.pid), "-o", "command=" }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        vim.list_extend(output, data or {})
      end,
      on_exit = function()
        local line = vim.trim(table.concat(output, " "))
        local expected = record.argv0 and vim.fn.fnamemodify(record.argv0, ":t") or record.adapter
        if line ~= "" and expected and line:find(expected, 1, true) then
          confirmed[#confirmed + 1] = record
        end
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            callback(confirmed)
          end)
        end
      end,
    })
    if not started then
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          callback(confirmed)
        end)
      end
    end
  end
end

--- Kill leftover processes from a previous session.
---@param orphans table[]
---@return integer killed
function M.reap(orphans)
  local killed = 0
  local db = state_store()
  for _, record in ipairs(orphans) do
    if pcall(util.uv.kill, record.pid, 15) then
      killed = killed + 1
      log.info("reaped orphaned server", { pid = record.pid, port = record.port })
    end
    db:delete(tostring(record.pid))
  end
  db:save()
  return killed
end

--------------------------------------------------------------------------------
-- Starting
--------------------------------------------------------------------------------

--- Binding to every interface puts the working tree on the network. That is a
--- legitimate thing to want (testing on a phone) and a bad thing to do by
--- accident, so it is always a deliberate, confirmed act.
---@param wanted boolean
---@param needs_prompt boolean
---@param callback fun(expose: boolean)
local function confirm_expose(wanted, needs_prompt, callback)
  if not wanted then
    return callback(false)
  end
  if not needs_prompt or expose_approved then
    return callback(true)
  end

  local ip = net.lan_ip()
  local prompt = table.concat({
    "Serve this directory to the whole local network?",
    "",
    ip and ("  Anyone who can reach %s will be able to browse it,"):format(ip)
      or "  Anyone on this network will be able to browse it,",
    "  including files you have not committed.",
  }, "\n")

  vim.ui.select({ "Keep it private (127.0.0.1)", "Expose on the network" }, { prompt = prompt }, function(choice)
    local approved = choice ~= nil and choice:match("^Expose") ~= nil
    expose_approved = expose_approved or approved
    callback(approved)
  end)
end

---@class live_server.StartOpts
---@field adapter? string
---@field port? integer|string
---@field dir? string directory to serve (or a path inside the project)
---@field path? string page to open
---@field expose? boolean
---@field open? boolean override `browser.auto_open`
---@field extra? string[]

--- Start a server.
---@param opts? live_server.StartOpts
---@param callback? fun(server: live_server.Server?, err: string?)
function M.start(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local cfg = config()

  local project = project_mod.get(opts.dir)

  local adapter_name = opts.adapter or project.config.server or cfg.server
  local adapter, adapter_err = adapters.resolve(adapter_name)
  if not adapter then
    log.notify(adapter_err or "no server available", "error")
    return callback(nil, adapter_err)
  end

  local existing = M.find_active(project.root, adapter.name)
  if existing then
    log.notify(("%s is already running for %s at %s"):format(adapter.display, project.name, existing:url()), "warn")
    return callback(existing, nil)
  end

  trust.ensure(project, function(granted)
    if not granted and next(project.privileged or {}) then
      log.notify(
        ("Ignoring the launch settings in %s."):format(vim.fn.fnamemodify(project.config_path, ":~:.")),
        "info"
      )
    end

    local want_expose = opts.expose
    if want_expose == nil then
      want_expose = project.config.expose
    end
    if want_expose == nil then
      want_expose = cfg.expose == true
    end
    -- `expose = true` in the user's own config is standing consent; a request
    -- from anywhere else still gets confirmed.
    local needs_prompt = cfg.expose ~= true

    confirm_expose(want_expose == true, needs_prompt, function(exposed)
      local host = exposed and "0.0.0.0" or (project.config.host or cfg.host)

      local serve_dir = project.serve_dir
      if opts.dir and util.is_dir(util.normalize(opts.dir)) then
        local candidate = util.normalize(opts.dir)
        if util.is_within(project.root, candidate) then
          serve_dir = candidate
        end
      end

      local resolved, port_err = port_mod.resolve({
        root = project.root,
        adapter = adapter.name,
        host = host,
        requested = opts.port,
        project_port = project.config.port,
      })
      if not resolved then
        log.notify(port_err or "could not allocate a port", "error")
        return callback(nil, port_err)
      end

      if resolved.fallback then
        local message = ("Port %d is in use; using %d instead."):format(resolved.preferred, resolved.port)
        net.port_owner(resolved.preferred, function(owner)
          log.notify(owner and (message .. " (held by " .. owner .. ")") or message, "warn")
        end)
      end

      local open_path = opts.path or project.config.open
      if not open_path and cfg.browser.open_current_file then
        open_path = project_mod.relative_page(serve_dir)
      end

      local server = server_mod.new({
        adapter = adapter,
        project = project,
        host = host,
        port = resolved.port,
        serve_dir = serve_dir,
        open_path = open_path,
        entry_file = project.config.entry_file or cfg.entry_file,
        extra = opts.extra,
        env = granted and project.privileged.env or nil,
        command = granted and project.privileged.command or nil,
      })
      if granted and project.privileged.args then
        server.extra = vim.list_extend(vim.deepcopy(server.extra or {}), project.privileged.args)
      end

      registry[server.id] = server

      server:start(function(ok, err)
        persist_state()
        if not ok then
          if err then
            log.notify(err, "error")
          end
          return callback(nil, err)
        end

        if cfg.port.remember and cfg.port.strategy == "pin" then
          port_mod.pin(project.root, adapter.name, server.port)
        end

        local suffix = server.adapter.live_reload and "" or "  (no live reload)"
        log.notify(("%s → %s%s"):format(project.name, server:url(), suffix), "info")

        local should_open = opts.open
        if should_open == nil then
          should_open = project.config.auto_open
        end
        if should_open == nil then
          should_open = cfg.browser.auto_open
        end
        if should_open then
          require("live_server.browser").open(server)
        elseif require("live_server.remote").is_remote() then
          require("live_server.remote").announce(server)
        end

        if type(cfg.on_start) == "function" then
          local hook_ok, hook_err = pcall(cfg.on_start, server)
          if not hook_ok then
            log.error("on_start hook failed", { err = tostring(hook_err) })
          end
        end

        callback(server, nil)
      end)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Stopping / toggling
--------------------------------------------------------------------------------

---@param server live_server.Server
---@param callback? fun()
function M.stop(server, callback)
  callback = callback or function() end
  server:stop(nil, function()
    persist_state()
    log.notify(("%s on port %d stopped."):format(server.adapter.display, server.port), "info")
    callback()
  end)
end

--- Stop everything. Returns how many servers were asked to stop.
---@param opts? { sync?: boolean, quiet?: boolean }
---@return integer
function M.stop_all(opts)
  opts = opts or {}
  local active = M.servers({ active_only = true })
  for _, server in ipairs(active) do
    if opts.sync then
      server:stop_sync()
    else
      server:stop()
    end
  end
  if opts.sync then
    state_store():clear():save()
  else
    persist_state()
  end
  if #active > 0 and not opts.quiet then
    log.notify(("Stopped %d server%s."):format(#active, #active == 1 and "" or "s"), "info")
  end
  return #active
end

--- Start the project's server if it is not running, stop it if it is.
---@param opts? live_server.StartOpts
---@param callback? fun(server: live_server.Server?, err: string?)
function M.toggle(opts, callback)
  opts = opts or {}
  local project = project_mod.get(opts.dir)
  local adapter_name = opts.adapter
  if adapter_name and adapter_name ~= "auto" then
    local existing = M.find_active(project.root, adapter_name)
    if existing then
      return M.stop(existing, function()
        if callback then
          callback(nil, nil)
        end
      end)
    end
  else
    local existing = M.find_active(project.root)
    if existing then
      return M.stop(existing, function()
        if callback then
          callback(nil, nil)
        end
      end)
    end
  end
  M.start(opts, callback)
end

---@param server live_server.Server
---@param callback? fun(ok: boolean, err: string?)
function M.restart(server, callback)
  server:restart(function(ok, err)
    persist_state()
    if ok then
      log.notify(("Restarted %s on port %d."):format(server.adapter.display, server.port), "info")
    elseif err then
      log.notify(err, "error")
    end
    if callback then
      callback(ok, err)
    end
  end)
end

--- Move a running server to a different port, keeping everything else.
---@param server live_server.Server
---@param port integer
---@param callback? fun(ok: boolean, err: string?)
function M.change_port(server, port, callback)
  callback = callback or function() end
  local valid, err = port_mod.validate(port, server.host)
  if not valid then
    log.notify(err or "invalid port", "error")
    return callback(false, err)
  end

  local previous = server.port
  server:stop({ grace = 1500 }, function()
    server.port = valid
    server.restarts = 0
    server:start(function(ok, start_err)
      if ok then
        local cfg = config()
        if cfg.port.remember and cfg.port.strategy == "pin" then
          port_mod.pin(server.project.root, server.adapter.name, valid)
        end
        log.notify(("Moved %s from %d to %s"):format(server.adapter.display, previous, server:url()), "info")
      else
        server.port = previous
        if start_err then
          log.notify(start_err, "error")
        end
      end
      persist_state()
      callback(ok, start_err)
    end)
  end)
end

--- Remove a stopped server from the registry.
---@param server live_server.Server
function M.forget(server)
  if server:is_active() then
    return
  end
  registry[server.id] = nil
  event.emit("changed", { server = server })
end

--- Drop every stopped entry.
---@return integer removed
function M.prune()
  local removed = 0
  for id, server in pairs(registry) do
    if not server:is_active() then
      registry[id] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then
    event.emit("changed", {})
  end
  return removed
end

--- Called on `VimLeavePre`: stop everything synchronously so nothing survives
--- the editor.
function M.shutdown()
  M.stop_all({ sync = true, quiet = true })
end

--- Test-suite hook.
function M.reset()
  registry = {}
  expose_approved = false
end

return M
