---@mod live_server.process Terminating a process and everything it started
---
--- `npm run dev` is rarely one process. It is `npm`, which spawns `nodemon`,
--- which spawns `node` — and only the last one holds the port. Signalling the
--- process we spawned relies on every layer forwarding that signal, which npm
--- generally does and other launchers generally do not.
---
--- When a layer swallows the signal the result is the worst kind of failure:
--- the plugin reports the server as stopped, the port stays held, and the next
--- start lands somewhere else. So termination walks the process tree and kills
--- it from the leaves up.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

--- Never signal these, whatever the process table says.
---@param pid integer
---@return boolean
local function protected(pid)
  return pid == nil or pid <= 1 or pid == util.uv.getpid()
end

--- Parse `ps -eo pid=,ppid=` into a parent -> children map.
---@param output string[]
---@return table<integer, integer[]>
local function parse_tree(output)
  local children = {}
  for _, line in ipairs(output) do
    local pid, ppid = line:match("^%s*(%d+)%s+(%d+)")
    if pid and ppid then
      pid, ppid = tonumber(pid), tonumber(ppid)
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
    end
  end
  return children
end

--- Walk the map depth-first, deepest first, so children are always killed
--- before the parent that would otherwise respawn or reparent them.
---@param children table<integer, integer[]>
---@param root integer
---@return integer[]
local function collect(children, root)
  local out = {}
  ---@param pid integer
  ---@param depth integer
  local function walk(pid, depth)
    -- A pathological or corrupted table must not loop forever.
    if depth > 32 then
      return
    end
    for _, child in ipairs(children[pid] or {}) do
      walk(child, depth + 1)
      if not protected(child) then
        out[#out + 1] = child
      end
    end
  end
  walk(root, 0)
  return out
end

--- Descendants of `pid`, deepest first. Empty on Windows, where the tree is
--- handled by `taskkill /T` instead.
---@param pid integer
---@param callback fun(pids: integer[])
function M.descendants(pid, callback)
  if util.is_windows or protected(pid) then
    return callback({})
  end

  local output = {}
  local ok = pcall(vim.fn.jobstart, { "ps", "-eo", "pid=,ppid=" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_exit = function()
      local found = collect(parse_tree(output), pid)
      vim.schedule(function()
        callback(found)
      end)
    end,
  })
  if not ok then
    callback({})
  end
end

--- Blocking variant, for `VimLeavePre` where there is no next tick to wait for.
---@param pid integer
---@return integer[]
function M.descendants_sync(pid)
  if util.is_windows or protected(pid) then
    return {}
  end
  local ok, raw = pcall(vim.fn.system, { "ps", "-eo", "pid=,ppid=" })
  if not ok or vim.v.shell_error ~= 0 or type(raw) ~= "string" then
    return {}
  end
  return collect(parse_tree(vim.split(raw, "\n", { plain = true })), pid)
end

---@param pid integer
---@param signal integer
local function signal_one(pid, signal)
  if protected(pid) then
    return
  end
  pcall(util.uv.kill, pid, signal)
end

--- Terminate `pid` and everything below it.
---@param pid integer
---@param signal integer 15 to ask, 9 to insist
---@param callback? fun()
function M.kill_tree(pid, signal, callback)
  callback = callback or function() end
  if protected(pid) then
    return callback()
  end

  if util.is_windows then
    -- Windows has no signals and no cheap process table; `taskkill /T` is the
    -- supported way to end a tree.
    local argv = { "taskkill", "/PID", tostring(pid), "/T" }
    if signal == 9 then
      argv[#argv + 1] = "/F"
    end
    local ok = pcall(vim.fn.jobstart, argv, {
      on_exit = function()
        vim.schedule(callback)
      end,
    })
    if not ok then
      callback()
    end
    return
  end

  M.descendants(pid, function(pids)
    if #pids > 0 then
      log.info("terminating process tree", { root = pid, descendants = #pids, signal = signal })
    end
    for _, child in ipairs(pids) do
      signal_one(child, signal)
    end
    signal_one(pid, signal)
    callback()
  end)
end

--- Blocking variant.
---@param pid integer
---@param signal integer
function M.kill_tree_sync(pid, signal)
  if protected(pid) then
    return
  end
  if util.is_windows then
    local argv = { "taskkill", "/PID", tostring(pid), "/T" }
    if signal == 9 then
      argv[#argv + 1] = "/F"
    end
    pcall(vim.fn.system, argv)
    return
  end

  for _, child in ipairs(M.descendants_sync(pid)) do
    signal_one(child, signal)
  end
  signal_one(pid, signal)
end

--- Is this process still alive?
---
--- Signal 0 tests existence without delivering anything. The subtlety is that
--- `uv.kill` *returns* its error instead of raising, so the obvious
--- `pcall(uv.kill, pid, 0)` succeeds for a process that died months ago. The
--- return value is the answer, not whether the call threw.
---@param pid integer
---@return boolean
function M.alive(pid)
  if pid == nil or pid <= 0 then
    return false
  end
  local ok, result = pcall(util.uv.kill, pid, 0)
  return ok and result == 0
end

return M
