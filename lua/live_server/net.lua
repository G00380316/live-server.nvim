---@mod live_server.net Port availability, readiness probing and address helpers
---
--- Port state is checked against the operating system, never against the
--- plugin's own bookkeeping: a port held by a stray `python -m http.server`, a
--- Docker publish, or another Neovim instance is just as unavailable as one we
--- started ourselves.

local util = require("live_server.util")

local M = {}

local uv = util.uv

--- Lowest port we will pick automatically. Binding below 1024 needs elevated
--- privileges on Unix and is never what a static-site workflow wants.
M.MIN_PORT = 1024
M.MAX_PORT = 65535

---@type table<string, string>
local resolve_cache = { localhost = "127.0.0.1" }

--- Resolve a host to a numeric address suitable for `bind()`.
---@param host string
---@return string
function M.resolve(host)
  if host == nil or host == "" then
    return "127.0.0.1"
  end
  if resolve_cache[host] then
    return resolve_cache[host]
  end
  -- Already numeric (IPv4 dotted quad or anything containing a colon => IPv6).
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
    resolve_cache[host] = host
    return host
  end
  local ok, result = pcall(uv.getaddrinfo, host, nil, { family = "inet", socktype = "stream" })
  if ok and type(result) == "table" and result[1] and result[1].addr then
    resolve_cache[host] = result[1].addr
    return result[1].addr
  end
  resolve_cache[host] = host
  return host
end

--- True when `port` is a syntactically valid, unprivileged TCP port.
---@param port any
---@return boolean ok
---@return string? err
function M.valid_port(port)
  local num = tonumber(port)
  if not num or num ~= math.floor(num) then
    return false, "port must be a whole number"
  end
  if num < 1 or num > M.MAX_PORT then
    return false, "port must be between 1 and " .. M.MAX_PORT
  end
  if num < M.MIN_PORT then
    return false, ("ports below %d are privileged; pick %d-%d"):format(M.MIN_PORT, M.MIN_PORT, M.MAX_PORT)
  end
  return true, nil
end

--- Can we bind this address? Fast (no network round trip) and the single most
--- reliable signal, because it asks the kernel the same question the server
--- process is about to ask.
---@param host string
---@param port integer
---@return boolean
function M.bindable(host, port)
  local sock = uv.new_tcp()
  if not sock then
    return true
  end
  local ok = pcall(function()
    assert(sock:bind(M.resolve(host), port))
    -- Binding alone can succeed while another socket listens with SO_REUSEADDR
    -- on some platforms, so take the extra step of listening.
    assert(sock:listen(1, function() end))
  end)
  pcall(function()
    sock:close()
  end)
  return ok
end

--- Asynchronously check whether something is accepting connections.
---@param host string
---@param port integer
---@param timeout integer milliseconds
---@param callback fun(listening: boolean)
function M.probe(host, port, timeout, callback)
  local sock = uv.new_tcp()
  local timer = uv.new_timer()
  local settled = false

  local function finish(listening)
    if settled then
      return
    end
    settled = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
    if sock and not sock:is_closing() then
      pcall(function()
        sock:close()
      end)
    end
    callback(listening)
  end

  if not sock or not timer then
    return finish(false)
  end

  timer:start(timeout, 0, function()
    finish(false)
  end)

  local ok = pcall(function()
    sock:connect(M.resolve(host), port, function(err)
      finish(err == nil)
    end)
  end)
  if not ok then
    finish(false)
  end
end

--- Blocking variant of `probe`. Safe on the main loop (it pumps via
--- `vim.wait`); must not be called from inside a libuv callback.
---@param host string
---@param port integer
---@param timeout? integer defaults to 150ms — a refused connection on loopback
---       returns immediately, so this only costs time for filtered ports.
---@return boolean
function M.is_listening(host, port, timeout)
  timeout = timeout or 150
  local result = nil
  M.probe(host, port, timeout, function(listening)
    result = listening
  end)
  vim.wait(timeout + 50, function()
    return result ~= nil
  end, 5)
  return result == true
end

--- True when nothing holds `port` on `host`.
---@param host string
---@param port integer
---@param opts? { deep?: boolean } also connect-probe; slower but catches
---       wildcard binds that a loopback bind test can miss on some platforms
---@return boolean
function M.is_free(host, port, opts)
  if not M.bindable(host, port) then
    return false
  end
  if opts and opts.deep then
    return not M.is_listening(host, port, 120)
  end
  return true
end

--- First free port at or after `start`, searched within `range`.
---@param host string
---@param start integer
---@param range integer[] { low, high }
---@param max_attempts integer
---@param exclude? table<integer, boolean> ports to skip (e.g. reserved by a
---       server that is still starting up and has not bound its port yet)
---@return integer? port
function M.find_free(host, start, range, max_attempts, exclude)
  exclude = exclude or {}
  local low = math.max(range[1], M.MIN_PORT)
  local high = math.min(range[2], M.MAX_PORT)
  local span = high - low + 1
  if span < 1 then
    return nil
  end

  local first = util.clamp(start, low, high)
  local attempts = math.min(max_attempts, span)
  for offset = 0, attempts - 1 do
    local port = low + ((first - low + offset) % span)
    if not exclude[port] and M.is_free(host, port) then
      return port
    end
  end
  return nil
end

--- Poll until `port` accepts connections, then invoke `callback(true)`. Gives
--- up after `timeout`, reporting `callback(false)`.
---@param host string
---@param port integer
---@param opts { timeout: integer, interval: integer, cancelled?: fun(): boolean }
---@param callback fun(ready: boolean)
---@return fun() cancel
function M.wait_until_ready(host, port, opts, callback)
  local deadline = util.now() + opts.timeout
  local cancelled = false
  local timer = uv.new_timer()

  local function stop()
    cancelled = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
      timer = nil
    end
  end

  local function attempt()
    if cancelled or (opts.cancelled and opts.cancelled()) then
      stop()
      return
    end
    M.probe(host, port, math.min(opts.interval * 4, 1000), function(listening)
      if cancelled then
        return
      end
      if listening then
        stop()
        vim.schedule(function()
          callback(true)
        end)
      elseif util.now() >= deadline then
        stop()
        vim.schedule(function()
          callback(false)
        end)
      end
    end)
  end

  if not timer then
    callback(false)
    return function() end
  end

  timer:start(opts.interval, opts.interval, attempt)
  return stop
end

--- Non-loopback IPv4 address of this machine, for LAN / device testing.
---@return string?
function M.lan_ip()
  local ok, addresses = pcall(uv.interface_addresses)
  if not ok or type(addresses) ~= "table" then
    return nil
  end
  -- Prefer common physical interface names so a docker0/bridge address does
  -- not win over the Wi-Fi address the user's phone can actually reach.
  local preferred = { "^en", "^wl", "^eth", "^wlan" }
  local fallback = nil
  for _, prefix in ipairs(preferred) do
    for name, entries in pairs(addresses) do
      if name:match(prefix) then
        for _, entry in ipairs(entries) do
          if entry.family == "inet" and not entry.internal then
            return entry.ip
          end
        end
      end
    end
  end
  for _, entries in pairs(addresses) do
    for _, entry in ipairs(entries) do
      if entry.family == "inet" and not entry.internal and not fallback then
        fallback = entry.ip
      end
    end
  end
  return fallback
end

--- Best-effort lookup of which process holds a port, for conflict messages.
--- Purely diagnostic: a failure here never blocks anything.
---@param port integer
---@param callback fun(owner: string?)
function M.port_owner(port, callback)
  local cmd
  if util.is_windows then
    cmd = { "powershell", "-NoProfile", "-Command", ("Get-NetTCPConnection -LocalPort %d -State Listen | Select-Object -First 1 -ExpandProperty OwningProcess | ForEach-Object { (Get-Process -Id $_).ProcessName }"):format(port) }
  elseif util.executable("lsof") then
    cmd = { "lsof", "-nP", "-sTCP:LISTEN", "-i", ("TCP:%d"):format(port), "-F", "cn" }
  elseif util.executable("ss") then
    cmd = { "ss", "-lptnH", ("sport = :%d"):format(port) }
  else
    return callback(nil)
  end

  local output = {}
  local ok = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          output[#output + 1] = line
        end
      end
    end,
    on_exit = function()
      local name
      for _, line in ipairs(output) do
        -- lsof -F prefixes command names with `c`
        local command = line:match("^c(.+)$")
        if command then
          name = command
          break
        end
        local ss_name = line:match('users:%(%("([^"]+)"')
        if ss_name then
          name = ss_name
          break
        end
      end
      if not name and output[1] then
        name = vim.trim(output[1])
      end
      vim.schedule(function()
        callback(name ~= "" and name or nil)
      end)
    end,
  })
  if not ok then
    callback(nil)
  end
end

return M
