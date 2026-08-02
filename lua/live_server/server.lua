---@mod live_server.server A single managed server process
---
--- Everything that can go wrong with a child process is handled here: it can
--- fail to spawn, bind a different port than we asked for, take seconds to
--- become reachable, die silently, or refuse to die. Each of those has an
--- explicit state, so the dashboard never shows "running" for a process that
--- is not actually answering requests.

local event = require("live_server.event")
local log = require("live_server.log")
local net = require("live_server.net")
local port_mod = require("live_server.port")
local util = require("live_server.util")

local M = {}

---@alias live_server.Status
---| "starting"   process spawned, port not answering yet
---| "running"    port confirmed accepting connections
---| "unhealthy"  process alive but never became reachable
---| "stopping"   termination requested
---| "stopped"    exited on request
---| "crashed"    exited unexpectedly

---@class live_server.Server
---@field id string
---@field adapter live_server.AdapterSpec
---@field project live_server.Project
---@field host string
---@field port integer
---@field serve_dir string
---@field argv string[]
---@field env table<string, string>
---@field status live_server.Status
---@field job integer?
---@field pid integer?
---@field started_at integer
---@field ready_at integer?
---@field stopped_at integer?
---@field exit_code integer?
---@field restarts integer
---@field open_path string?
---@field exposed boolean
---@field logs live_server.Ring
---@field private _intentional boolean
---@field private _cancel_ready fun()|nil
---@field private _force_timer any
local Server = {}
Server.__index = Server

---@type integer
local next_id = 0

--- Create a server object. Nothing is spawned until `start()`.
---@param opts { adapter: live_server.AdapterSpec, project: live_server.Project, host: string, port: integer, serve_dir?: string, open_path?: string, entry_file?: string, extra?: string[], env?: table<string,string>, command?: string[] }
---@return live_server.Server
function M.new(opts)
  next_id = next_id + 1
  local cfg = require("live_server.config").get()

  local server = setmetatable({
    id = ("%s#%d"):format(opts.adapter.name, next_id),
    adapter = opts.adapter,
    project = opts.project,
    host = opts.host,
    port = opts.port,
    serve_dir = opts.serve_dir or opts.project.serve_dir,
    open_path = opts.open_path,
    entry_file = opts.entry_file,
    extra = opts.extra or {},
    env = opts.env or {},
    command = opts.command,
    status = "stopped",
    restarts = 0,
    exposed = opts.host == "0.0.0.0" or opts.host == "::",
    logs = util.ring(cfg.log.max_lines),
    _intentional = false,
  }, Server)

  return server
end

--- Build the argv for this server.
---@return string[]
function Server:build_argv()
  local cfg = require("live_server.config").get()

  ---@type live_server.SpawnContext
  local ctx = {
    host = self.host,
    port = self.port,
    serve_dir = self.serve_dir,
    project = self.project,
    config = cfg,
    entry_file = self.entry_file or cfg.entry_file,
    ignore = cfg.watch.ignore,
    extensions = cfg.watch.extensions,
    delay = cfg.watch.delay,
    extra = vim.list_extend(vim.deepcopy(cfg.extra_args[self.adapter.name] or {}), self.extra),
  }

  -- A trusted project file can replace the command outright.
  if self.command and #self.command > 0 then
    local argv = vim.deepcopy(self.command)
    for _, arg in ipairs(ctx.extra) do
      argv[#argv + 1] = arg
    end
    return argv
  end

  return self.adapter.build(ctx)
end

--- Base URL, optionally with a page path appended.
---@param path? string
---@return string
function Server:url(path)
  -- A wildcard bind is not a usable address in a browser.
  local display_host = self.host
  if display_host == "0.0.0.0" or display_host == "::" or display_host == "" then
    display_host = net.lan_ip() or "127.0.0.1"
  end
  if display_host:find(":", 1, true) and not display_host:find("%[") then
    display_host = "[" .. display_host .. "]"
  end

  local base = ("http://%s:%d"):format(display_host, self.port)
  path = path or self.open_path
  if not path or path == "" then
    return base .. "/"
  end
  return base .. "/" .. (path:gsub("^/+", ""))
end

---@return integer milliseconds since the process started
function Server:uptime()
  if not self.started_at then
    return 0
  end
  local until_ms = self.stopped_at or util.now()
  return math.max(0, until_ms - self.started_at)
end

---@return boolean
function Server:is_active()
  return self.status == "starting" or self.status == "running" or self.status == "unhealthy"
end

--- Plain, serialisable snapshot. Used for `User` autocommand payloads, so it
--- must contain no functions or metatables.
---@return table
function Server:info()
  return {
    id = self.id,
    adapter = self.adapter.name,
    project = self.project.root,
    project_name = self.project.name,
    serve_dir = self.serve_dir,
    host = self.host,
    port = self.port,
    url = self:url(),
    status = self.status,
    pid = self.pid,
    uptime = self:uptime(),
    restarts = self.restarts,
    exposed = self.exposed,
    live_reload = self.adapter.live_reload,
  }
end

---@param stream "stdout"|"stderr"|"system"
---@param line string
function Server:append_log(stream, line)
  line = util.strip_ansi(line)
  if vim.trim(line) == "" then
    return
  end
  self.logs:push({ at = util.now(), stream = stream, text = line })
  event.emit("output", { server = self, stream = stream, text = line })
end

---@param limit? integer
---@return { at: integer, stream: string, text: string }[]
function Server:log_lines(limit)
  return self.logs:list(limit)
end

--- The most recent stderr line, used to explain a crash.
---@return string?
function Server:last_error()
  local lines = self.logs:list()
  for i = #lines, 1, -1 do
    if lines[i].stream ~= "stdout" then
      return lines[i].text
    end
  end
  return lines[#lines] and lines[#lines].text or nil
end

---@param status live_server.Status
---@param evt? live_server.EventName
function Server:set_status(status, evt)
  if self.status == status and not evt then
    return
  end
  self.status = status
  event.emit(evt or "changed", { server = self })
end

--- Spawn the process.
---@param callback? fun(ok: boolean, err: string?)
function Server:start(callback)
  callback = callback or function() end

  if self:is_active() then
    return callback(false, "already running")
  end

  local ok, argv = pcall(function()
    return self:build_argv()
  end)
  if not ok or type(argv) ~= "table" or #argv == 0 then
    local err = ("could not build a command for %s: %s"):format(self.adapter.display, tostring(argv))
    log.error(err)
    return callback(false, err)
  end
  self.argv = argv

  self._intentional = false
  self.exit_code = nil
  self.stopped_at = nil
  self.ready_at = nil
  self.started_at = util.now()
  self.status = "starting"

  local env = vim.tbl_extend("force", {
    -- Keep process output parseable, and make sure no adapter decides to open
    -- a browser behind our back before the port is even reachable.
    NO_COLOR = "1",
    FORCE_COLOR = "0",
    BROWSER = "none",
  }, self.env)

  log.info("spawning server", { argv = argv, cwd = self.project.root, port = self.port })

  local spawned, job = pcall(vim.fn.jobstart, argv, {
    cwd = util.is_dir(self.project.root) and self.project.root or nil,
    env = env,
    -- Deliberately *not* detached: Neovim owning the child is what guarantees
    -- no orphaned server survives a crash of the editor.
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        self:append_log("stdout", line)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        self:append_log("stderr", line)
      end
    end,
    on_exit = function(_, code)
      self:_on_exit(code)
    end,
  })

  if not spawned or type(job) ~= "number" or job <= 0 then
    local reason = job == -1 and ("%s is not executable"):format(argv[1])
      or ("failed to spawn %s"):format(argv[1])
    self.status = "crashed"
    self:append_log("system", reason)
    port_mod.release(self.port)
    log.error(reason, { argv = argv })
    event.emit("crashed", { server = self, reason = reason })
    return callback(false, reason)
  end

  self.job = job
  self.pid = vim.fn.jobpid(job)
  self:append_log("system", "$ " .. util.join_argv(argv))
  event.emit("starting", { server = self })

  local cfg = require("live_server.config").get()
  self._cancel_ready = net.wait_until_ready(self.host, self.port, {
    timeout = cfg.ready.timeout,
    interval = cfg.ready.interval,
    cancelled = function()
      return self.status ~= "starting"
    end,
  }, function(ready)
    self._cancel_ready = nil
    port_mod.release(self.port)

    if self.status ~= "starting" then
      return -- exited or was stopped while we waited
    end

    if ready then
      self.ready_at = util.now()
      self.restarts = 0
      self.status = "running"
      log.info("server ready", { url = self:url(), pid = self.pid })
      event.emit("ready", { server = self })
      callback(true, nil)
    else
      self.status = "unhealthy"
      local detail = self:last_error()
      local message = ("%s did not respond on port %d within %ds"):format(
        self.adapter.display,
        self.port,
        math.floor(cfg.ready.timeout / 1000)
      )
      self:append_log("system", message)
      log.warn(message, { detail = detail })
      event.emit("changed", { server = self })
      callback(false, detail and (message .. ": " .. detail) or message)
    end
  end)
end

---@param code integer
function Server:_on_exit(code)
  self.exit_code = code
  self.stopped_at = util.now()
  self.job = nil
  self.pid = nil

  if self._cancel_ready then
    self._cancel_ready()
    self._cancel_ready = nil
  end
  if self._force_timer then
    pcall(function()
      self._force_timer:stop()
      self._force_timer:close()
    end)
    self._force_timer = nil
  end
  port_mod.release(self.port)

  local was_intentional = self._intentional
  self._intentional = false

  if was_intentional or code == 0 then
    self.status = "stopped"
    log.info("server stopped", { id = self.id, code = code })
    event.emit("stopped", { server = self, code = code })
    self:_notify_stop_hook()
    return
  end

  self.status = "crashed"
  local detail = self:last_error()
  log.warn("server exited unexpectedly", { id = self.id, code = code, detail = detail })
  event.emit("crashed", { server = self, code = code, reason = detail })
  self:_notify_stop_hook()

  local cfg = require("live_server.config").get()
  if cfg.restart.on_crash and self.restarts < cfg.restart.max_attempts then
    self.restarts = self.restarts + 1
    local delay = cfg.restart.backoff * (2 ^ (self.restarts - 1))
    log.info("scheduling crash restart", { id = self.id, attempt = self.restarts, delay = delay })
    vim.defer_fn(function()
      if self.status ~= "crashed" then
        return -- the user already intervened
      end
      log.notify(
        ("%s crashed; restarting (attempt %d/%d)"):format(self.adapter.display, self.restarts, cfg.restart.max_attempts),
        "warn"
      )
      self:start()
    end, delay)
  elseif cfg.restart.on_crash and self.restarts >= cfg.restart.max_attempts then
    log.notify(
      ("%s keeps crashing on port %d — giving up. `:LiveServer logs` has the output.%s"):format(
        self.adapter.display,
        self.port,
        detail and ("\n" .. detail) or ""
      ),
      "error"
    )
  end
end

function Server:_notify_stop_hook()
  local cfg = require("live_server.config").get()
  if type(cfg.on_stop) == "function" then
    local ok, err = pcall(cfg.on_stop, self)
    if not ok then
      log.error("on_stop hook failed", { err = tostring(err) })
    end
  end
end

--- Terminate the process. Sends SIGTERM, then escalates to SIGKILL if the
--- process is still alive after `grace` milliseconds.
---@param opts? { grace?: integer }
---@param callback? fun()
function Server:stop(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  if not self.job then
    self.status = "stopped"
    event.emit("stopped", { server = self })
    return callback()
  end

  self._intentional = true
  self.status = "stopping"
  event.emit("stopping", { server = self })

  if self._cancel_ready then
    self._cancel_ready()
    self._cancel_ready = nil
  end

  local job, pid = self.job, self.pid
  pcall(vim.fn.jobstop, job)

  local grace = opts.grace or 2000
  local timer = util.uv.new_timer()
  self._force_timer = timer
  if timer then
    timer:start(grace, 0, function()
      pcall(function()
        timer:stop()
        timer:close()
      end)
      vim.schedule(function()
        if self._force_timer == timer then
          self._force_timer = nil
        end
        if self.job == job and pid then
          log.warn("server ignored SIGTERM, sending SIGKILL", { pid = pid })
          pcall(util.uv.kill, pid, 9)
        end
      end)
    end)
  end

  -- `on_exit` finishes the state transition; give the caller a completion
  -- signal without making it wait on the process.
  local unsubscribe
  unsubscribe = event.on("stopped", function(payload)
    if payload.server == self then
      if unsubscribe then
        unsubscribe()
        unsubscribe = nil
      end
      callback()
    end
  end)
end

--- Stop synchronously. Only used on `VimLeavePre`, where blocking briefly is
--- the correct trade for guaranteeing nothing is left behind.
---@param timeout? integer
function Server:stop_sync(timeout)
  if not self.job then
    return
  end
  self._intentional = true
  self.status = "stopping"
  local job, pid = self.job, self.pid
  pcall(vim.fn.jobstop, job)
  local result = vim.fn.jobwait({ job }, timeout or 1500)
  if result[1] == -1 and pid then
    pcall(util.uv.kill, pid, 9)
    vim.fn.jobwait({ job }, 300)
  end
  self.job = nil
  self.pid = nil
  self.status = "stopped"
end

--- Stop, then start again on the same port.
---@param callback? fun(ok: boolean, err: string?)
function Server:restart(callback)
  callback = callback or function() end
  local function relaunch()
    -- Give the OS a moment to release the socket before rebinding it.
    vim.defer_fn(function()
      self.restarts = 0
      self:start(callback)
    end, 150)
  end

  if self.job then
    self:stop({ grace = 1500 }, relaunch)
  else
    relaunch()
  end
end

M.Server = Server

return M
