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
local process = require("live_server.process")
local util = require("live_server.util")

local M = {}

--- `vim.islist` on 0.10+, `vim.tbl_islist` on 0.9.
local islist = vim.islist or vim.tbl_islist

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

--- Global, monotonic across every server.
---
--- `uv.now()` is the event loop's *cached* time, so several lines produced in
--- one tick — which is exactly what happens when four services start together —
--- carry an identical timestamp. Ordering on time alone then degrades to
--- "grouped by whichever server was iterated first", which is the opposite of
--- what a combined log is for.
---@type integer
local log_sequence = 0

---@class live_server.ServerOpts
---@field adapter live_server.AdapterSpec
---@field project live_server.Project
---@field host string
---@field port integer
---@field serve_dir? string defaults to the project's detected serve directory
---@field open_path? string page to open once ready
---@field entry_file? string SPA fallback document
---@field extra? string[] additional CLI arguments
---@field env? table<string, string> extra environment variables (needs trust)
---@field command? string[] replaces the adapter's argv entirely (needs trust)

--- Create a server object. Nothing is spawned until `start()`.
---@param opts live_server.ServerOpts
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

--- Build the command for this server.
---
--- Adapters may return a bare argv list, or `{ argv = …, env = … }` when the
--- process needs environment variables — the only way to give a port to an
--- Express app or a Create React App build, neither of which takes a flag.
---@return string[] argv
---@return table<string, string> env
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
    return argv, {}
  end

  local built = self.adapter.build(ctx)
  if islist(built) then
    return built, {}
  end
  if type(built) ~= "table" or not islist(built.argv) then
    error(("adapter %s returned neither an argv list nor { argv = ... }"):format(self.adapter.name), 0)
  end
  return built.argv, built.env or {}
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

--- Label for this server. A `node` adapter running a Next.js app should read
--- as "Next.js", because that is what the developer thinks they started.
---@return string
function Server:display_name()
  if self._display_name then
    return self._display_name
  end
  self._display_name = require("live_server.adapters").display_for(self.adapter.name, self.project)
  return self._display_name
end

--- Whether changes reach the browser without a manual refresh. Adapters that
--- wrap a project can only answer this once the project is known: Vite has
--- HMR, a bare Express app does not.
---@return boolean
function Server:has_live_reload()
  if type(self.adapter.live_reload_for) == "function" then
    local ok, value = pcall(self.adapter.live_reload_for, self.project)
    if ok and type(value) == "boolean" then
      return value
    end
  end
  return self.adapter.live_reload == true
end

--- Whether there is a page worth opening. A socket server listens on a port
--- but answers WebSocket handshakes, not requests for `/`.
---@return boolean
function Server:serves_pages()
  if type(self.adapter.serves_pages) == "function" then
    local ok, value = pcall(self.adapter.serves_pages, self.project)
    if ok and type(value) == "boolean" then
      return value
    end
  end
  return true
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
    workdir = self.project.workdir,
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
    live_reload = self:has_live_reload(),
    serves_pages = self:serves_pages(),
    display = self:display_name(),
  }
end

---@param stream "stdout"|"stderr"|"system"
---@param line string
function Server:append_log(stream, line)
  line = util.strip_ansi(line)
  if vim.trim(line) == "" then
    return
  end
  log_sequence = log_sequence + 1
  self.logs:push({ at = util.now(), seq = log_sequence, stream = stream, text = line })
  if stream ~= "system" then
    self:_check_port_drift(line)
  end
  event.emit("output", { server = self, stream = stream, text = line })
end

--- Dev servers print the address they actually bound. Believe them.
---
--- An Express app with a hard-coded `app.listen(4000)` ignores the `PORT` we
--- set; a framework that walks past a busy port lands somewhere else. In both
--- cases the process is healthy and only our bookkeeping is wrong, so adopt
--- the port it reported rather than reporting a working server as dead.
---@param line string
function Server:_check_port_drift(line)
  if self.status ~= "starting" then
    return
  end

  ---@type integer?
  local detected
  ---@type boolean
  local confident = false

  if self.adapter.url_pattern then
    detected = tonumber(line:match(self.adapter.url_pattern))
    confident = detected ~= nil
  end
  if not detected and self.adapter.port_pattern then
    detected = tonumber(line:match(self.adapter.port_pattern))
  end

  if not detected or detected == self.port or not net.valid_port(detected) then
    return
  end

  -- A bare port number is ambiguous: "port 5000 is in use" mentions a port the
  -- process is *not* using. Only follow it once our own port has visibly failed
  -- to come up, where being wrong costs nothing and being right is the
  -- difference between a working server and a false "no answer".
  if not confident and net.is_listening(self.host, self.port, 150) then
    return
  end

  -- Only trust it once something is really listening there: build output can
  -- mention unrelated URLs.
  if not net.is_listening(self.host, detected, 200) then
    return
  end

  local previous = self.port
  port_mod.release(previous)
  self.port = detected
  self:append_log("system", ("bound to port %d instead of %d — following it"):format(detected, previous))
  log.info("adopted the port the process reported", { from = previous, to = detected, id = self.id })
  self:_watch_ready()
  event.emit("changed", { server = self })
end

---@param limit? integer
---@return { at: integer, seq: integer, stream: string, text: string }[]
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

--- Deliver the result of a `start()` exactly once.
---
--- A start can finish three ways — the port answers, the readiness probe times
--- out, or the process dies first — and every one of them has to reach the
--- caller. Losing the third case leaves `require("live_server").start(o, cb)`
--- waiting for a callback that will never come.
---@param ok boolean
---@param err string?
function Server:_settle_start(ok, err)
  self:_take_start_callback()(ok, err)
end

--- Detach the pending start callback and return an invoker for it.
---
--- Detaching *before* any event is emitted is the whole point: a `stopped`
--- handler may synchronously begin a new run (that is exactly what
--- `restart` and `change_port` do), and that new run registers its own
--- callback. Reading `self._start_callback` afterwards would settle the new
--- run with the old run's outcome.
---@return fun(ok: boolean, err: string?)
function Server:_take_start_callback()
  local pending = self._start_callback
  self._start_callback = nil
  return function(ok, err)
    if not pending then
      return
    end
    local fn = pending
    pending = nil
    local safe, hook_err = pcall(fn, ok, err)
    if not safe then
      log.error("start callback failed", { err = tostring(hook_err) })
    end
  end
end

--- Spawn the process.
---@param callback? fun(ok: boolean, err: string?)
function Server:start(callback)
  callback = callback or function() end

  if self:is_active() then
    return callback(false, "already running")
  end

  local ok, argv, built_env = pcall(function()
    return self:build_argv()
  end)
  if not ok or type(argv) ~= "table" or #argv == 0 then
    local err = ("could not build a command for %s: %s"):format(self.adapter.display, tostring(argv))
    log.error(err)
    return callback(false, err)
  end
  self.argv = argv
  self.built_env = built_env or {}

  self._intentional = false
  self.exit_code = nil
  self.stopped_at = nil
  self.ready_at = nil
  self.started_at = util.now()
  self.status = "starting"
  -- Registered before the spawn: `on_exit` can fire before `jobstart` returns
  -- for a process that dies instantly.
  self._start_callback = callback

  local env = vim.tbl_extend("force", {
    -- Keep process output parseable, and make sure no adapter decides to open
    -- a browser behind our back before the port is even reachable.
    NO_COLOR = "1",
    FORCE_COLOR = "0",
    BROWSER = "none",
  }, self.built_env or {}, self.env)

  log.info("spawning server", { argv = argv, cwd = self.project.root, port = self.port })

  local spawned, job = pcall(vim.fn.jobstart, argv, {
    cwd = util.is_dir(self.project.workdir) and self.project.workdir or nil,
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
    local reason = job == -1 and ("%s is not executable"):format(argv[1]) or ("failed to spawn %s"):format(argv[1])
    self.status = "crashed"
    self:append_log("system", reason)
    port_mod.release(self.port)
    log.error(reason, { argv = argv })
    event.emit("crashed", { server = self, reason = reason })
    return self:_settle_start(false, reason)
  end

  self.job = job
  self.pid = vim.fn.jobpid(job)
  self:append_log("system", "$ " .. util.join_argv(argv))
  event.emit("starting", { server = self })

  self:_watch_ready()
end

--- How long this server may take to answer. Frameworks compile before they
--- listen, so a fixed budget that suits live-server would report a perfectly
--- healthy Next.js app as broken.
---@return integer
function Server:ready_budget()
  local cfg = require("live_server.config").get()
  if type(self.adapter.ready_timeout) == "function" then
    local ok, override = pcall(self.adapter.ready_timeout, self.project)
    if ok and type(override) == "number" and override > 0 then
      return math.max(override, cfg.ready.timeout)
    end
  end
  return cfg.ready.timeout
end

--- Poll until the port answers. Split out from `start` so it can be re-aimed
--- when the process reports a different port than we asked for.
function Server:_watch_ready()
  local cfg = require("live_server.config").get()
  local budget = self:ready_budget()

  if self._cancel_ready then
    self._cancel_ready()
    self._cancel_ready = nil
  end

  self._cancel_ready = net.wait_until_ready(self.host, self.port, {
    timeout = budget,
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
      -- The tree is fully established by the time the port answers.
      self:_snapshot_tree()
      log.info("server ready", { url = self:url(), pid = self.pid })
      event.emit("ready", { server = self })
      self:_settle_start(true, nil)
    else
      self.status = "unhealthy"
      local detail = self:last_error()
      local message = ("%s did not respond on port %d within %ds"):format(
        self.adapter.display,
        self.port,
        math.floor(budget / 1000)
      )
      self:append_log("system", message)
      log.warn(message, { detail = detail })
      event.emit("changed", { server = self })
      self:_settle_start(false, detail and (message .. ": " .. detail) or message)
    end
  end)
end

---@param code integer
function Server:_on_exit(code)
  self.exit_code = code
  self.stopped_at = util.now()
  local pid_before_exit = self.pid
  self.job = nil
  self.pid = nil

  -- Detach before emitting anything: handlers of the events below may start a
  -- fresh run on this same object.
  local settle_start = self:_take_start_callback()

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
    self:_verify_port_released(pid_before_exit)
    event.emit("stopped", { server = self, code = code })
    -- A stop that lands before the port ever answered still has to answer the
    -- caller waiting on `start()`.
    settle_start(false, ("%s exited before it was ready"):format(self.adapter.display))
    self:_notify_stop_hook()
    return
  end

  self.status = "crashed"
  local detail = self:last_error()
  log.warn("server exited unexpectedly", { id = self.id, code = code, detail = detail })
  event.emit("crashed", { server = self, code = code, reason = detail })

  local summary = ("%s exited with code %d"):format(self.adapter.display, code)
  settle_start(false, detail and (summary .. ": " .. detail) or summary)
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
      local message = ("%s crashed; restarting (attempt %d/%d)"):format(
        self.adapter.display,
        self.restarts,
        cfg.restart.max_attempts
      )
      log.notify(message, "warn")
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

--- Remember the process tree while the parent is still alive.
---
--- This has to happen *before* anything is signalled. Once the launcher dies,
--- its children are reparented to init and the parent/child link that
--- identifies them as ours is gone forever — so a snapshot taken after the
--- fact finds nothing, and anything that escaped the process group is
--- unreachable.
function Server:_snapshot_tree()
  if not self.pid then
    return
  end
  local found = process.descendants_sync(self.pid)
  if #found > 0 then
    self._tree = found
  end
end

--- Signal everything recorded by the last snapshot that is still alive.
---@param signal integer
---@return integer signalled
function Server:_signal_snapshot(signal)
  local count = 0
  for _, child in ipairs(self._tree or {}) do
    if process.alive(child) then
      pcall(util.uv.kill, child, signal)
      count = count + 1
    end
  end
  return count
end

--- Confirm the port is free once the process we spawned has gone.
---
--- The parent exiting proves nothing: `npm` routinely returns while the `node`
--- it started keeps the socket. Silently reporting "stopped" here is how a
--- port ends up held by a process nobody can see.
---@param pid integer? the pid we had before the process exited
function Server:_verify_port_released(pid)
  local port, host = self.port, self.host
  vim.defer_fn(function()
    if net.is_free(host, port) then
      return
    end
    -- Something still holds it. Anything recorded before we signalled is ours
    -- to clean up, however it got away.
    local survivors = self:_signal_snapshot(9)
    if pid and process.alive(pid) then
      log.warn("process survived its own exit notification", { pid = pid, port = port })
      process.kill_tree(pid, 9)
      survivors = survivors + 1
    end
    if survivors > 0 then
      log.info("killed processes that outlived their launcher", { count = survivors, port = port })
      return
    end

    net.port_owner(port, function(owner)
      log.notify(
        ("Port %d is still held%s after stopping %s. `:LiveServer reap` clears leftovers."):format(
          port,
          owner and (" by " .. owner) or "",
          self:display_name()
        ),
        "warn"
      )
    end)
  end, 400)
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
  -- Refresh before signalling: this is the last moment the tree is intact.
  self:_snapshot_tree()
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
        -- Escalate against the recorded tree even if the launcher has already
        -- gone: what holds the port is usually what outlived it.
        local survivors = self:_signal_snapshot(9)
        if self.job == job and pid then
          log.warn("server ignored SIGTERM, killing the process tree", { pid = pid })
          process.kill_tree(pid, 9)
          survivors = survivors + 1
        end
        if survivors > 0 then
          self:append_log("system", "did not exit on request; killed the process tree")
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
  self:_snapshot_tree()
  pcall(vim.fn.jobstop, job)
  local result = vim.fn.jobwait({ job }, timeout or 1500)
  if result[1] == -1 and pid then
    process.kill_tree_sync(pid, 9)
    vim.fn.jobwait({ job }, 300)
  end
  -- Even a clean exit can leave a grandchild behind, and on the way out of the
  -- editor there is no later chance to notice.
  self:_signal_snapshot(9)
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
